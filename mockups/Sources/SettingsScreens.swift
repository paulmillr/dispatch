import SwiftUI

// Settings, as the app's (G1 to G3, G5): no app theme, only the terminal's color scheme.

/// G1, as the app's Settings: Appearance with the terminal's color scheme (no app theme), Terminal, Chat, Notifications
/// with Background refresh, Hosts, and Remove all data.
struct SettingsScreen: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: .constant(1)) {
                        Text("System").tag(0); Text("Dark").tag(1); Text("Light").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    NavigationLink { Text("Color schemes") } label: {
                        LabeledContent("Color scheme") { Text("Dispatch") }
                    }
                    Toggle("Colorblind-friendly", isOn: .constant(false))
                } header: { Text("Appearance") }
                Section {
                    NavigationLink { TerminalFontScreen() } label: {
                        LabeledContent("Font") { Text("Source Code Pro") }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Font size") { Text("12 pt").monospacedDigit() }
                        Slider(value: .constant(12), in: 8...24, step: 1) { Text("Font size") } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    Picker("Line spacing", selection: .constant(1)) { Text("Tight").tag(0); Text("Normal").tag(1); Text("Relaxed").tag(2) }
                    Picker("Improve text contrast", selection: .constant(1)) { Text("Never").tag(0); Text("Light themes").tag(1); Text("Always").tag(2) }
                } header: { Text("Terminal") } footer: {
                    Text("Terminals open at this size, larger or smaller with the system text size. Pinch a terminal to zoom it; the last size becomes the default.")
                }
                Section {
                    NavigationLink { ChatFontScreen() } label: {
                        LabeledContent("Font") { Text("San Francisco") }
                    }
                    Picker("While the agent works", selection: .constant(0)) { Text("Queue").tag(0); Text("Steer").tag(1) }
                    Picker("Open agents in", selection: .constant(0)) { Text("Chat").tag(0); Text("Terminal").tag(1) }
                    NavigationLink { Text("Dictation") } label: {
                        LabeledContent("Dictation") { Text("Apple") }
                    }
                    NavigationLink { Text("Voice") } label: {
                        LabeledContent("Voice") { Text("Spoken Content") }
                    }
                } header: { Text("Chat") }
                Section {
                    NavigationLink { NotificationsScreen() } label: {
                        LabeledContent("Notifications") { Text("Sound, text") }
                    }
                    Toggle("Background refresh", isOn: .constant(true))
                } footer: {
                    Text("About every 15 minutes, as iOS allows, Dispatch connects to the hosts with Chat on and notifies you as Notifications says.")
                }
                Section {
                    Toggle("Color-code hosts", isOn: .constant(true))
                    Toggle("Automatically approve unsafe pastes", isOn: .constant(true))
                } header: { Text("Hosts") } footer: {
                    Text("With Color-code hosts off, every host is gray.")
                }
                Section {
                    Button("Remove all data", role: .destructive) {}
                    Button("Remove all data except SSH keys", role: .destructive) {}
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") {} } }
        }
    }
}

/// Terminal font: the bundled monospaced fonts with a live sample line each, like the Mac's font list.
struct TerminalFontScreen: View {
    let fonts: [(String, String?, String)] = [
        ("JetBrains Mono", nil, "Menlo"), ("SF Mono", nil, "Menlo"), ("Source Code Pro", nil, "Menlo"),
        ("Fira Code", "ligatures", "Menlo"), ("IBM Plex Mono", nil, "Menlo"), ("Menlo", "system", "Menlo"),
    ]
    var body: some View {
        List {
            Section {
                ForEach(Array(fonts.enumerated()), id: \.offset) { i, f in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(f.0).font(.body)
                                if let note = f.1 { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("$ cargo test --workspace 0O1lI {} <=>")
                                .font(.custom(f.2, size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if i == 0 { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink) }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Fonts bundled with Dispatch. Ligatures follow the font.")
            }
            Section {
                Toggle("Bold text as bright colors", isOn: .constant(false))
                Picker("Cursor", selection: .constant(0)) { Text("Block").tag(0); Text("Bar").tag(1); Text("Underline").tag(2) }
                Toggle("Blinking cursor", isOn: .constant(true))
            }
        }
        .navigationTitle("Terminal font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Chat font: the Mac's three choices with a sample bubble.
struct ChatFontScreen: View {
    var body: some View {
        List {
            Section {
                row("San Francisco", sample: "The system font, as Messages.", font: .body, on: true)
                row("Same as code", sample: "JetBrains Mono 15, as the terminal.", font: .system(.body, design: .monospaced), on: false)
                row("Comic Sans", sample: "For the brave.", font: .custom("Chalkboard SE", size: 17), on: false)
            } footer: {
                Text("Code blocks and paths always use the terminal font.")
            }
            Section {
                Picker("Text size", selection: .constant(1)) { Text("Smaller").tag(0); Text("Default").tag(1); Text("Larger").tag(2) }
                    .pickerStyle(.segmented)
            } footer: { Text("Relative to Dynamic Type.") }
        }
        .navigationTitle("Chat font")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func row(_ name: String, sample: String, font: Font, on: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.body)
                Text(sample).font(font).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer()
            if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink) }
        }
        .padding(.vertical, 2)
    }
}

/// Notifications: what to notify on, the sound and text in the banner (the badge always counts), the watch.
struct NotificationsScreen: View {
    var body: some View {
        List {
            Section {
                Toggle("Needs you", isOn: .constant(true))
                Toggle("Finished", isOn: .constant(true))
                Toggle("Failed or disconnected", isOn: .constant(true))
            } header: { Text("Notify when an agent") } footer: {
                Text("Approvals and questions always notify.")
            }
            Section {
                Picker("Sound", selection: .constant(0)) { Text("Default").tag(0); Text("Ship's bell").tag(1); Text("None").tag(2) }
                Toggle("Show message text", isOn: .constant(true))
            } footer: {
                Text("Off, banners say only which conversation needs you. The badge counts conversations waiting for you across hosts.")
            }
            Section {
                LabeledContent("Apple Watch") { Text("Paired") }
            } footer: { Text("iOS shows the same notifications on your watch while this iPhone is locked and the watch is on your wrist.") }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsPush<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            content
                .toolbar { ToolbarItem(placement: .topBarLeading) { BackPill(count: nil, title: "Settings") }.sharedBackgroundVisibility(.hidden) }
                .navigationBarBackButtonHidden(true)
        }
    }
}
