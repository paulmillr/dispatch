import SwiftUI

extension MockFiles {
    static let src: [MockFile] = [
        .init(name: "components", dir: true, size: "3 items", age: "4m"),
        .init(name: "hooks", dir: true, size: "2 items", age: "25m"),
        .init(name: "routes", dir: true, size: "6 items", age: "2d"),
        .init(name: "styles", dir: true, size: "2 items", age: "25m"),
        .init(name: "app.tsx", dir: false, size: "2.4 KB", age: "2d"),
        .init(name: "main.tsx", dir: false, size: "912 B", age: "2d"),
        .init(name: "theme.ts", dir: false, size: "1.8 KB", age: "25m"),
        .init(name: "types.d.ts", dir: false, size: "3.1 KB", age: "6d"),
        .init(name: "vite-env.d.ts", dir: false, size: "38 B", age: "3w"),
    ]
}

struct Breadcrumb: View {
    let crumbs: [String]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                    Text(crumb)
                        .font(.subheadline.weight(index == crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct FileRow: View {
    let file: MockFile
    var last = false
    var symbol: String {
        if file.dir { return "folder.fill" }
        switch (file.name as NSString).pathExtension {
        case "md": return "doc.richtext"
        case "json", "yaml": return "curlybraces"
        case "png", "svg": return "photo"
        default: return "doc.text"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(file.dir ? hostTint : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.body).lineLimit(1)
                    Text(file.dir ? "\(file.size) · \(file.age)" : "\(file.size) · \(file.age)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            if !last { Hairline(inset: 56) }
        }
    }
}

/// F2: a file, pushed from the listing.
struct FilePreviewScreen: View {
    var body: some View {
        PushedShell(back: "Files", title: "theme.ts") {
            Text("src · 1.8 KB · 25m ago · TypeScript")
        } trailing: {
            Menu {
                Button("Wrap lines", systemImage: "text.alignleft") {}
                Button("Copy path", systemImage: "doc.on.doc") {}
                Button("Copy contents", systemImage: "doc.on.clipboard") {}
                Button("Share", systemImage: "square.and.arrow.up") {}
                Divider()
                Button("Attach to chat", systemImage: "paperclip") {}
                Button("Open in Terminal", systemImage: "apple.terminal") {}
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        } content: {
            ScrollView([.vertical, .horizontal]) {
                CodeBlock(lines: MockFiles.themeSource.components(separatedBy: "\n"), language: "ts")
                    .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Label("Ask claude", systemImage: "paperclip")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 44)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
    }
}

/// Crude syntax colouring for the mockup.
struct CodeBlock: View {
    let lines: [String]
    let language: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
                    Text(Syntax.color(line)).lineLimit(1)
                }
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 19)
                .padding(.horizontal, 12)
            }
        }
    }
}

enum Syntax {
    static let keywords: Set<String> = ["import", "export", "from", "const", "let", "return", "function", "type", "if", "else", "as", "new", "true", "false"]
    static func color(_ line: String) -> AttributedString {
        var out = AttributedString()
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("//") { var a = AttributedString(line); a.foregroundColor = .codeComment; return a }
        var current = ""
        var inString: Character? = nil
        func flush() {
            guard !current.isEmpty else { return }
            var a = AttributedString(current)
            if keywords.contains(current) { a.foregroundColor = .codeKeyword }
            else if current.first?.isNumber == true { a.foregroundColor = .codeNumber }
            else if current.first?.isUppercase == true { a.foregroundColor = .codeType }
            else { a.foregroundColor = .codeInk }
            out += a; current = ""
        }
        for ch in line {
            if let q = inString {
                current.append(ch)
                if ch == q { var a = AttributedString(current); a.foregroundColor = .codeString; out += a; current = ""; inString = nil }
                continue
            }
            if ch == "\"" || ch == "'" || ch == "`" { flush(); inString = ch; current = String(ch); continue }
            if ch.isLetter || ch.isNumber || ch == "_" { current.append(ch) }
            else { flush(); var a = AttributedString(String(ch)); a.foregroundColor = .codeInk; out += a }
        }
        flush()
        return out
    }
}
