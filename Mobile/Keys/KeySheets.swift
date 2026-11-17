import SwiftUI
import UniformTypeIdentifiers

/// Import key (M8a): an OpenSSH private key from Files or pasted, with a passphrase prompt for encrypted files. The
/// file is parsed off the main actor (`KeyStore.importKeyOffMain`: an encrypted file's derivation takes from tens of
/// milliseconds to seconds), with Import shown as progress and the form disabled meanwhile. Cancel (or the sheet going
/// away otherwise) abandons it: the parse runs to its end and nothing is stored.
struct ImportKeySheet: View {
    let imported: (KeyRecord) -> Void
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var text = ""
    @State private var file: Data?
    @State private var fileName: String?
    @State private var choosing = false
    @State private var askingPassphrase = false
    @State private var passphrase = ""
    @State private var failure: String?
    /// The import in progress, if any.
    @State private var importing: Task<Void, Never>?

    private var contents: Data? { file ?? (text.isEmpty ? nil : Data(text.utf8)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("id_ed25519", text: $label).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button(fileName.map { "File: \($0)" } ?? "Choose File…", systemImage: "folder") { choosing = true }
                    if file == nil {
                        TextEditor(text: $text)
                            .font(.caption.monospaced())
                            .frame(minHeight: 140)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text("Or paste the private key here")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    } else {
                        Button("Paste Instead", role: .destructive) { file = nil; fileName = nil }
                    }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("An OpenSSH key file such as ~/.ssh/id_ed25519. It is stored in the Keychain on this \(MobileDevice.name) and unlocks with Face ID.")
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .disabled(importing != nil)
            .navigationTitle("Import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importing?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if importing != nil {
                        ProgressView().accessibilityLabel("Importing")
                    } else {
                        Button("Import") { run(passphrase: nil) }.disabled(contents == nil)
                    }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .text, .item]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // Key files are a few kilobytes; anything large is not one.
                    if let data = try? Data(contentsOf: url), data.count <= 64 * 1024 {
                        file = data
                        fileName = url.lastPathComponent
                        failure = nil
                    } else {
                        failure = "This file can't be read as a key."
                    }
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
            .alert("Passphrase", isPresented: $askingPassphrase) {
                SecureField("Passphrase", text: $passphrase)
                Button("Cancel", role: .cancel) { passphrase = "" }
                Button("Import") { run(passphrase: passphrase) }
            } message: {
                Text("This key is protected by a passphrase. It is kept in the Keychain with the key.")
            }
        }
        .interactiveDismissDisabled(importing != nil)
        .onDisappear { importing?.cancel() }
    }

    private func run(passphrase: String?) {
        guard let contents, importing == nil else { return }
        failure = nil
        let keys = sessions.keys, label = label
        importing = Task {
            defer { importing = nil }
            do {
                let key = try await keys.importKeyOffMain(contents, label: label, passphrase: passphrase)
                self.passphrase = ""
                imported(key)
                dismiss()
            } catch is CancellationError {
                // Abandoned (Cancel, or the sheet went away): nothing was stored, nothing to show.
            } catch OpenSSHKeyError.passphraseRequired {
                askingPassphrase = true
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Create key (M8a): ED25519 in the Keychain by default, or P-256 in the Secure Enclave.
struct CreateKeySheet: View {
    let created: (KeyRecord) -> Void
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var label = "iphone"
    @State private var enclave = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("iphone", text: $label).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Type", selection: $enclave) {
                        Text("ED25519").tag(false)
                        Text("Secure Enclave P-256").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Type")
                } footer: {
                    Text(sessions.keys.secureEnclaveAvailable
                         ? "ED25519 works with every OpenSSH server. A Secure Enclave key never leaves this \(MobileDevice.name) and is offered as ecdsa-sha2-nistp256."
                         : "This \(MobileDevice.name) has no Secure Enclave available, so the key is ED25519.")
                }
                .disabled(!sessions.keys.secureEnclaveAvailable)
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let label = label.trimmingCharacters(in: .whitespaces)
        do {
            let key = enclave ? try sessions.keys.generateSecureEnclaveP256(label: label)
                              : try sessions.keys.generateED25519(label: label)
            created(key)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
