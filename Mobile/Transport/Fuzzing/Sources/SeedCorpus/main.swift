import Foundation

// These message shapes are transcribed from Robustness/SessionReplayTests.swift's recorded phases and hostile
// messages, with the canonical decoder seeds from Wire/MutationTests.swift. Keeping generation here makes the
// binary corpus reproducible without putting NUL-containing files or private-key-looking fixtures in the checkout.

enum CorpusError: Error, CustomStringConvertible {
  case process(String, Int32, String)
  case malformedArmor(String)

  var description: String {
    switch self {
    case .process(let tool, let status, let error): "\(tool) failed (\(status)): \(error)"
    case .malformedArmor(let name): "could not decode the generated armor in \(name)"
    }
  }
}

let fileManager = FileManager.default
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Corpora", isDirectory: true)
let targets = ["fuzz-client-initial", "fuzz-client-post-kex", "fuzz-messages", "fuzz-key-blobs",
               "fuzz-signatures", "fuzz-key-files"]
for target in targets {
  try fileManager.createDirectory(at: output.appendingPathComponent(target), withIntermediateDirectories: true)
}

func u32(_ value: UInt32) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
   UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

func string(_ bytes: [UInt8]) -> [UInt8] { u32(UInt32(bytes.count)) + bytes }
func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

func packet(_ payload: [UInt8]) -> [UInt8] {
  var padding = 4
  while (4 + 1 + payload.count + padding) % 8 != 0 { padding += 1 }
  let length = 1 + payload.count + padding
  return u32(UInt32(length)) + [UInt8(padding)] + payload + [UInt8](repeating: 0xA5, count: padding)
}

func write(_ target: String, _ name: String, _ bytes: [UInt8]) throws {
  try Data(bytes).write(to: output.appendingPathComponent(target).appendingPathComponent(name), options: .atomic)
}

let kexInit: [UInt8] = [20] + [UInt8](repeating: 0x42, count: 16)
  + string("curve25519-sha256,kex-strict-s-v00@openssh.com")
  + string("ssh-ed25519") + string("aes128-gcm@openssh.com") + string("aes128-gcm@openssh.com")
  + string("") + string("") + string("none") + string("none") + string("") + string("") + [0] + u32(0)
try write("fuzz-client-initial", "version", Array("SSH-2.0-FuzzSeed_1.0\r\n".utf8))
try write("fuzz-client-initial", "version-kexinit",
          Array("notice before identification\r\nSSH-2.0-FuzzSeed_1.0\r\n".utf8) + packet(kexInit))

let extInfo: [UInt8] = [7] + u32(2) + string("server-sig-algs") + string("ssh-ed25519,rsa-sha2-256")
  + string("ping@openssh.com") + string("0")
let authFailure: [UInt8] = [51] + string("publickey,password,keyboard-interactive") + [0]
let challenge: [UInt8] = [60] + string("Login") + string("Two factors") + string("") + u32(2)
  + string([0x4B, 0x65, 0x6E, 0x6E, 0x77, 0x6F, 0x72, 0x74, 0x20, 0x66, 0xFC, 0x72, 0x3A]) + [0]
  + string("Code: ") + [1]
let disconnect: [UInt8] = [1] + u32(11) + string("fictional goodbye") + string("")
let globalRequest: [UInt8] = [80] + string("fictional@example.invalid") + [1]
let openConfirmation: [UInt8] = [91] + u32(0) + u32(41) + u32(2 * 1024 * 1024) + u32(32 * 1024)
let channelSuccess: [UInt8] = [99] + u32(0)
let channelData: [UInt8] = [94] + u32(0) + string("fictional output")

let postKex: [[UInt8]] = [
  [0] + [6] + string("ssh-userauth"),
  [1] + authFailure,
  [2] + globalRequest,
  [3] + openConfirmation,
  [4] + channelSuccess,
  [5] + channelData,
  [6] + challenge,
]
for (index, seed) in postKex.enumerated() { try write("fuzz-client-post-kex", "phase-\(index)", seed) }

let messages = [kexInit, extInfo, authFailure, challenge, disconnect, globalRequest, openConfirmation, channelSuccess,
                channelData, [90] + string("forwarded-tcpip") + u32(7) + u32(1024) + u32(1024)]
for (index, seed) in messages.enumerated() { try write("fuzz-messages", "message-\(index)", seed) }

let ed25519Blob = string("ssh-ed25519") + string([UInt8](repeating: 0x42, count: 32))
let rsaBlob = string("ssh-rsa") + string([1, 0, 1]) + string([0x00, 0x80] + [UInt8](repeating: 0x55, count: 255))
try write("fuzz-key-blobs", "ed25519", ed25519Blob)
try write("fuzz-key-blobs", "rsa", rsaBlob)

let ed25519Signature = string("ssh-ed25519") + string([UInt8](repeating: 0x33, count: 64))
let ecdsaInner = string([0x00, 0x80] + [UInt8](repeating: 1, count: 31))
  + string([UInt8](repeating: 2, count: 32))
let ecdsaSignature = string("ecdsa-sha2-nistp256") + string(ecdsaInner)
try write("fuzz-signatures", "ed25519", ed25519Signature)
try write("fuzz-signatures", "ecdsa", ecdsaSignature)

// Exercise every selector even on hosts without the key-generation tools.
try write("fuzz-key-files", "armor-shape", [0] + Array("-----BEGIN OPENSSH PRIVATE KEY-----\nAA==\n-----END OPENSSH PRIVATE KEY-----\n".utf8))
try write("fuzz-key-files", "pkcs8-shape", [1, 0x30, 0x00])
try write("fuzz-key-files", "pkcs1-shape", [2, 0x30, 0x00])
try write("fuzz-key-files", "sec1-shape", [3, 0x30, 0x00])
try write("fuzz-key-files", "openssh-shape", [4] + Array("openssh-key-v1\0".utf8))

func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
  guard FileManager.default.isExecutableFile(atPath: executable) else { return }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = directory
  process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
  let errors = Pipe()
  process.standardOutput = FileHandle.nullDevice
  process.standardError = errors
  try process.run()
  let error = errors.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw CorpusError.process((executable as NSString).lastPathComponent, process.terminationStatus,
                              String(decoding: error, as: UTF8.self))
  }
}

func armorBody(_ url: URL) throws -> [UInt8] {
  let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
  let base64 = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
  guard let data = Data(base64Encoded: String(base64)) else { throw CorpusError.malformedArmor(url.lastPathComponent) }
  return Array(data)
}

let temporary = fileManager.temporaryDirectory.appendingPathComponent("sshengine-fuzz-seeds-\(UUID().uuidString)")
try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
defer { try? fileManager.removeItem(at: temporary) }

let passphrase = "fictional passphrase for a throwaway key"
let openSSH = temporary.appendingPathComponent("id_ed25519")
try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-a", "4", "-N", passphrase, "-C",
                                  "fuzz-corpus@example.invalid", "-f", openSSH.path], in: temporary)
if fileManager.fileExists(atPath: openSSH.path) {
  let armored = Array(try Data(contentsOf: openSSH))
  try write("fuzz-key-files", "openssh-armored", [0] + armored)
  try write("fuzz-key-files", "openssh-binary", [4] + armorBody(openSSH))
}

let rsa = temporary.appendingPathComponent("id_rsa")
try run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-m", "PEM", "-C",
                                  "fuzz-corpus@example.invalid", "-f", rsa.path], in: temporary)
if fileManager.fileExists(atPath: rsa.path) {
  let armored = Array(try Data(contentsOf: rsa))
  try write("fuzz-key-files", "rsa-pem-armored", [0] + armored)
  try write("fuzz-key-files", "rsa-pkcs1", [2] + armorBody(rsa))

  let pkcs8 = temporary.appendingPathComponent("id_rsa.pkcs8")
  try run("/usr/bin/openssl", ["pkcs8", "-topk8", "-nocrypt", "-in", rsa.path, "-out", pkcs8.path], in: temporary)
  if fileManager.fileExists(atPath: pkcs8.path) {
    try write("fuzz-key-files", "rsa-pkcs8", [1] + armorBody(pkcs8))
  }
}

let ec = temporary.appendingPathComponent("id_ecdsa")
try run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", "256", "-N", "", "-m", "PEM", "-C",
                                  "fuzz-corpus@example.invalid", "-f", ec.path], in: temporary)
if fileManager.fileExists(atPath: ec.path) {
  try write("fuzz-key-files", "ec-sec1", [3] + armorBody(ec))
}

print("Seeded \(targets.count) corpora at \(output.path)")
