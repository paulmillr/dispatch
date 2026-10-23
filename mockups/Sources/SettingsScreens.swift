import SwiftUI

// Settings: the existing Form with the new rows (terminal font, chat font, app theme, notifications).

struct SettingsScreen: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: .constant(0)) {
                        Text("System").tag(0); Text("Dark").tag(1); Text("Light").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    NavigationLink { AppThemeScreen() } label: {
                        LabeledContent("Theme") { Text("Automatic") }
                    }
                }
                Section {
                    NavigationLink { TerminalFontScreen() } label: {
                        LabeledContent("Font") { Text("JetBrains Mono") }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Font size") { Text("13 pt").monospacedDigit() }
                        Slider(value: .constant(13), in: 9...24, step: 1) { Text("Font size") } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    NavigationLink { Text("Color schemes") } label: {
                        LabeledContent("Color scheme") { Text("Dispatch Black") }
                    }
                    Toggle("Improve text contrast", isOn: .constant(true))
                } header: { Text("Terminal") } footer: {
                    Text("Terminals open at this size. Pinch a terminal to zoom it; the last size becomes the default.")
                }
                Section {
                    NavigationLink { ChatFontScreen() } label: {
                        LabeledContent("Font") { Text("San Francisco") }
                    }
                    NavigationLink { Text("Dictation") } label: {
                        LabeledContent("Dictation") { Text("Whisper small") }
                    }
                } header: { Text("Chat") }
                Section {
                    NavigationLink { NotificationsScreen() } label: {
                        LabeledContent("Notifications") { Text("Sound, text") }
                    }
                    Toggle("Background refresh", isOn: .constant(true))
                } footer: {
                    Text("About every 15 minutes, as iOS allows, Dispatch connects to the hosts with Chat on and notifies you when an agent needs you.")
                }
                Section {
                    LabeledContent("mba2") { Text("Chat on") }
                    LabeledContent("studio") { Text("Chat on") }
                    LabeledContent("ai") { Text("Plain SSH") }
                } header: { Text("Hosts") }
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

/// App theme: Automatic, Dark, Light, plus the Mac's Graphite, Lavender and Nautical as swatch tiles.
struct AppThemeScreen: View {
    let themes: [(String, Color, Color, String)] = [
        ("Automatic", Color.canvas, Color.dispatchPink, "Follows Appearance"),
        ("Graphite", Color(white: 0.12), Color(white: 0.6), "Neutral greys"),
        ("Lavender", Color(red: 0.12, green: 0.10, blue: 0.18), Color(red: 0.66, green: 0.54, blue: 0.88), "Purple accent"),
        ("Nautical", Color(red: 0.05, green: 0.12, blue: 0.14), Color(red: 0.3, green: 0.8, blue: 0.5), "Radar green, engine room"),
    ]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(themes.enumerated()), id: \.offset) { i, t in
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 12).fill(t.1)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(t.2).frame(width: 60, height: 10)
                                Capsule().fill(Color.white.opacity(0.18)).frame(width: 90, height: 8)
                                Capsule().fill(Color.white.opacity(0.18)).frame(width: 70, height: 8)
                            }
                            .padding(12)
                        }
                        .frame(height: 96)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(i == 0 ? Color.dispatchPink : Color.clear, lineWidth: 2))
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.0).font(.subheadline.weight(.semibold))
                                Text(t.3).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if i == 0 { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dispatchPink) }
                        }
                    }
                    .padding(10)
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
            Text("Themes color the app's chrome and chat. The terminal keeps its own color scheme.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32)
        }
        .background(Color.canvas)
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Notifications: what to notify on, sound, text in the banner, the badge.
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
                Toggle("Badge app icon", isOn: .constant(true))
            } footer: {
                Text("Off, banners say only which conversation needs you. The badge counts conversations waiting for you across hosts.")
            }
            Section {
                Toggle("Apple Watch", isOn: .constant(true))
            } footer: { Text("Mirror the same notifications on your watch, with Allow and Deny in the banner.") }
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
