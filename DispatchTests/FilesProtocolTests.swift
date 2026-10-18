import Foundation
import XCTest
@testable import DispatchApp

final class FilesProtocolTests: XCTestCase {
    /// Hello advertises the files vocabulary, the local helper's grant admits it (no permission_denied), and files.list
    /// answers a listing.
    func testLocalHelperAdvertisesFilesOperationsAndAdmitsThem() async throws {
        struct List: Encodable { let path: String }
        struct Entry: Decodable { let name: String; let kind: String }
        struct Listing: Decodable { let path: String; let entries: [Entry]; let truncated: Bool }
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        let session = try await HelperSession(process: process)
        defer { session.close() }
        for operation in ["files.list", "files.summary", "files.write", "files.pack", "files.pack.drop",
                          "files.unpack.open", "files.unpack.write", "files.unpack.close", "files.git"] {
            XCTAssertTrue(session.info.ops.contains(operation), operation)
        }
        let listing: Listing = try await session.connection.request("files.list", params: List(path: "/"))
        XCTAssertEqual(listing.path, "/")
        XCTAssertFalse(listing.truncated)
        // hidden defaults to false: no dot-names; / always holds folders.
        XCTAssertFalse(listing.entries.contains { $0.name.hasPrefix(".") })
        XCTAssertTrue(listing.entries.contains { $0.kind == "directory" })
        XCTAssertEqual(listing.entries.map(\.name), listing.entries.map(\.name).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }

    /// files.git on the local helper, as the git tabs call it: in a repository made here, porcelain status
    /// (NUL-separated, an untracked file and a staged one) and `rev-parse --show-toplevel`; git's own failure outside
    /// a repository, and a command off the allow-list refused before git runs.
    func testLocalHelperRunsReadOnlyGitAndRefusesTheRest() async throws {
        struct Run: Encodable { let path: String; let args: [String]; let limit: UInt64 }
        struct Git: Decodable { let status: Int64; let output: String; let truncated: Bool }
        func git(_ args: [String], in folder: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", folder.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                                 "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            process.standardError = FileHandle.nullDevice
            XCTAssertEqual(try TestSupport.live(process).status, 0, "git \(args)")
        }
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        let session = try await HelperSession(process: process)
        defer { session.close() }
        let connection = session.connection

        let root = System.temporary.appendingPathComponent("dispatch-git-" + System.uuid().uuidString)
        let repo = root.appendingPathComponent("repo"), outside = root.appendingPathComponent("plain")
        // Made live, cleanup included: git runs live in replay too (TestSupport.live), in these folders and on these
        // files, while the helper's answers come from the recording.
        func write(_ text: String, _ name: String) throws { try Data(text.utf8).write(to: repo.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: repo)
        try write("one\n", "tracked.txt")
        try git(["add", "tracked.txt"], in: repo)
        try git(["commit", "-q", "-m", "one"], in: repo)
        try write("one\ntwo\n", "tracked.txt")
        try git(["add", "tracked.txt"], in: repo)
        try write("new\n", "untracked.txt")

        // From the repository and from a folder inside it, the same top level: the repository's real path (git names
        // it; System.temporary may sit behind a link). Its own repository, not the checkout, which a VM's synchronized
        // copy is not.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var tops: [String] = []
        for folder in [repo, repo.appendingPathComponent("sub")] {
            let top: Git = try await connection.request(
                "files.git", params: Run(path: folder.path, args: ["rev-parse", "--show-toplevel"], limit: 0))
            XCTAssertEqual(top.status, 0, top.output)
            XCTAssertTrue(top.output.hasPrefix("/") && top.output.hasSuffix("/repo\n"), top.output)
            tops.append(top.output)
        }
        XCTAssertEqual(tops[0], tops[1])
        let status: Git = try await connection.request(
            "files.git", params: Run(path: repo.path, args: ["status", "--porcelain=v2", "-z"], limit: 0))
        XCTAssertEqual(status.status, 0, status.output)
        XCTAssertFalse(status.truncated)
        let records = status.output.split(separator: "\0", omittingEmptySubsequences: true)
        XCTAssertEqual(records.count, 2, status.output)
        XCTAssertTrue(records.contains { $0.hasPrefix("1 M. ") && $0.hasSuffix(" tracked.txt") }, status.output)
        XCTAssertTrue(records.contains("? untracked.txt"), status.output)
        XCTAssertFalse(System.exists(repo.appendingPathComponent(".git/index.lock")))

        // System.temporary is outside any repository.
        let none: Git = try await connection.request(
            "files.git", params: Run(path: outside.path, args: ["rev-parse", "--show-toplevel"], limit: 0))
        XCTAssertEqual(none.status, 128)
        XCTAssertTrue(none.output.contains("not a git repository"), none.output)

        for args in [["push"], ["commit", "-m", "x"], ["diff", "--output=x"], ["log", "-c", "x=y"]] {
            do {
                let _: Git = try await connection.request("files.git", params: Run(path: repo.path, args: args, limit: 0))
                XCTFail("files.git ran \(args)")
            } catch let failure as HelperFailure {
                XCTAssertEqual(failure.code, "invalid_request", "\(args)")
            }
        }
    }

    /// Copying out and in on the local helper, as the files tab does: files.write, files.pack and a files.read of
    /// its archive, then files.unpack.* into a folder that holds a conflicting name. A transfer still open when its
    /// client disconnects is removed, staging folder and all, before that helper exits.
    func testLocalHelperCopiesFilesOutAndInAndEndsTransfersItsClientLeftOpen() async throws {
        struct Write: Encodable { let path: String; let bytes: Data; let mode: UInt64?; let replace: Bool }
        struct Written: Decodable { let size: UInt64 }
        struct Pack: Encodable { let transfer: String; let base: String; let paths: [String]; let limit: UInt64 }
        struct Packed: Decodable {
            let archive: String, entries: UInt64, files: UInt64, folders: UInt64, bytes: UInt64, size: UInt64, skipped: UInt64
        }
        struct Named: Encodable { let transfer: String }
        struct Read: Encodable { let path: String; let offset: UInt64; let length: UInt64 }
        struct Open: Encodable { let transfer: String; let target: String; let policy: String; let names: [String] }
        struct Transfer: Decodable { let transfer: String; let staging: String }
        struct Append: Encodable { let transfer: String; let bytes: Data }
        struct Progress: Decodable { let bytes: UInt64 }
        struct Close: Encodable { let transfer: String; let commit: Bool }
        struct Unpacked: Decodable { let entries: UInt64; let bytes: UInt64; let replaced: UInt64; let kept: UInt64; let skipped: UInt64 }
        func helper() async throws -> HelperSession {
            let process = Process()
            process.executableURL = try XCTUnwrap(HelperApp.executable)
            process.arguments = ["--stdio"]
            process.standardError = FileHandle.nullDevice
            return try await HelperSession(process: process)
        }
        let root = System.temporary.appendingPathComponent("dispatch-files-" + System.uuid().uuidString)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try System.directory(source.appendingPathComponent("folder"))
        try System.directory(target)
        defer { try? System.remove(root) }
        let session = try await helper()
        defer { session.close() }
        let connection = session.connection

        let file = source.appendingPathComponent("folder/alpha.txt"), notes = source.appendingPathComponent("notes.txt")
        let written: Written = try await connection.request(
            "files.write", params: Write(path: file.path, bytes: Data("alpha".utf8), mode: nil, replace: false))
        XCTAssertEqual(written.size, 5)
        do {
            let _: Written = try await connection.request(
                "files.write", params: Write(path: file.path, bytes: Data("again".utf8), mode: nil, replace: false))
            XCTFail("files.write replaced a file without replace")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, "exists")
        }
        let _: Written = try await connection.request(
            "files.write", params: Write(path: notes.path, bytes: Data("new notes".utf8), mode: 0o600, replace: false))

        let out = System.uuid().uuidString
        let packed: Packed = try await connection.request(
            "files.pack", params: Pack(transfer: out, base: source.path, paths: [source.appendingPathComponent("folder").path, notes.path], limit: 0))
        XCTAssertEqual([packed.entries, packed.files, packed.folders, packed.bytes, packed.skipped], [3, 2, 1, 14, 0])
        let archive: (result: Written, bytes: Data) = try await connection.requestBinary(
            "files.read", params: Read(path: packed.archive, offset: 0, length: packed.size))
        XCTAssertEqual(UInt64(archive.bytes.count), packed.size)
        let _: HelperClient.Ignored = try await connection.request("files.pack.drop", params: Named(transfer: out))

        try System.write(Data("old notes".utf8), to: target.appendingPathComponent("notes.txt"))
        let copy = System.uuid().uuidString
        let opened: Transfer = try await connection.request(
            "files.unpack.open", params: Open(transfer: copy, target: target.path, policy: "keep", names: ["folder", "notes.txt"]))
        XCTAssertEqual(opened.transfer, copy)
        let progress: Progress = try await connection.request(
            "files.unpack.write", params: Append(transfer: copy, bytes: archive.bytes))
        XCTAssertEqual(progress.bytes, packed.size)
        let unpacked: Unpacked = try await connection.request("files.unpack.close", params: Close(transfer: copy, commit: true))
        XCTAssertEqual([unpacked.entries, unpacked.bytes, unpacked.replaced, unpacked.kept, unpacked.skipped], [3, 14, 0, 1, 0])
        XCTAssertEqual(try System.list(target).sorted(), ["folder", "notes 2.txt", "notes.txt"])
        XCTAssertEqual(try System.read(target.appendingPathComponent("notes 2.txt")), Data("new notes".utf8))

        let leaving = try await helper()
        let left = System.uuid().uuidString
        let staged: Transfer = try await leaving.connection.request(
            "files.unpack.open", params: Open(transfer: left, target: target.path, policy: "replace", names: ["folder", "notes.txt"]))
        let _: Progress = try await leaving.connection.request(
            "files.unpack.write", params: Append(transfer: left, bytes: archive.bytes.prefix(100)))
        XCTAssertTrue(System.exists(URL(fileURLWithPath: staged.staging)))
        leaving.close()
        for await _ in leaving.exited { break }
        XCTAssertFalse(System.exists(URL(fileURLWithPath: staged.staging)), "the disconnected client's staging folder")
        XCTAssertEqual(try System.list(target).sorted(), ["folder", "notes 2.txt", "notes.txt"])
    }
}
