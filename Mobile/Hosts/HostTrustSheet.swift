import SwiftUI

/// Trust on first use (plan 3.6; not in the mockup): the host's algorithm and SHA256 fingerprint, Trust or Cancel.
/// A key that differs from the trusted one is a hard stop: Remove and retry, or Cancel.
struct HostTrustSheet: View {
    let request: HostTrustRequest
    @Environment(HostSessions.self) private var sessions

    private var address: String {
        request.offer.port == 22 ? request.offer.host : "\(request.offer.host):\(request.offer.port)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: mismatch ? "exclamationmark.shield" : "checkmark.shield")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundStyle(mismatch ? Color.red : Color.dispatchPink)
                        Text(mismatch ? "Host key changed" : "Trust this host?")
                            .font(.title2.bold())
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    LabeledContent("Host") { Text(address).monospaced() }
                    LabeledContent("Algorithm") { Text(request.offer.algorithm).monospaced() }
                    fingerprint(mismatch ? "Offered" : "Fingerprint", request.offer.fingerprint)
                    if case .mismatch(let trusted) = request.kind {
                        fingerprint("Trusted on \(trusted.firstSeen.formatted(date: .abbreviated, time: .omitted))", trusted.fingerprint)
                    }
                } footer: {
                    if !mismatch {
                        Text("On the host, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints its fingerprint.")
                    }
                }
            }
            .navigationTitle(request.hostName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { actions }
        }
        .interactiveDismissDisabled()
    }

    private var mismatch: Bool { request.kind != .unknown }

    private var message: String {
        mismatch
            ? "The key \(request.hostName) offered isn’t the one you trusted. Someone may be intercepting the connection, or the host was reinstalled. Dispatch won’t connect until you remove the old key."
            : "This is the first connection to \(request.hostName) from this iPhone. Check that the fingerprint matches the host’s before you trust it."
    }

    private func fingerprint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if mismatch {
                Button(role: .destructive) { sessions.removeAndRetry(request) } label: {
                    Text("Remove and retry").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(.red)
            } else {
                Button { sessions.resolve(request, trust: true) } label: {
                    Text("Trust").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            Button(role: .cancel) { sessions.resolve(request, trust: false) } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

extension View {
    /// Presents the host key and login questions from here while this is the topmost presenter (the root, or a sheet over it
    /// that registered later), so a question is never lost behind a sheet.
    func hostTrustPrompt() -> some View { modifier(HostTrustPrompt()) }
}

private struct HostTrustPrompt: ViewModifier {
    @Environment(HostSessions.self) private var sessions
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { sessions.trustPresenter == token ? sessions.question : nil },
                                 set: { _ in })) { question in
                switch question {
                case .trust(let request): HostTrustSheet(request: request).tint(.dispatchPink)
                case .login(let prompt): HostLoginPromptSheet(prompt: prompt).tint(.dispatchPink)
                }
            }
            .onAppear { sessions.registerTrustPresenter(token) }
            .onDisappear { sessions.unregisterTrustPresenter(token) }
    }
}
