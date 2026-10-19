import Foundation

/// The files view's words for sizes, ages and counts: sizes as Finder counts them
/// (1,000 bytes to the KB), ages short enough for a 64 pt column, so the list, the preview and the footer agree.
enum FilesFormatting {
    /// What the size and modified columns show for an unknown value or a folder.
    private static let none = "—"

    /// "612 B", "4.1 KB", "188 KB", "9.6 MB": one decimal below 10 of a unit, none above, so the column stays narrow.
    static func size(_ bytes: UInt64) -> String {
        guard bytes >= 1_000 else { return "\(bytes) B" }
        let (value, unit) = scaled(bytes, tenths: false)
        // Round first: 9.96 KB reads "10 KB", not "10.0 KB".
        let tenths = (value * 10).rounded() / 10
        return tenths < 10 ? String(format: "%.1f %@", tenths, unit) : "\(Int(value.rounded())) \(unit)"
    }

    /// "48.2 MB": always one decimal, for the folder summary's size row.
    static func preciseSize(_ bytes: UInt64) -> String {
        guard bytes >= 1_000 else { return "\(bytes) B" }
        let (value, unit) = scaled(bytes, tenths: true)
        return String(format: "%.1f %@", value, unit)
    }

    /// `bytes` in the largest decimal unit that keeps it under 1,000 as shown (rounded to whole units, or to tenths):
    /// 999,600 bytes is "1.0 MB", never "1000 KB".
    private static func scaled(_ bytes: UInt64, tenths: Bool) -> (value: Double, unit: String) {
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        let step: Double = tenths ? 10 : 1
        var value = Double(bytes) / 1_000
        var index = 0
        while (value * step).rounded() / step >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        return (value, units[index])
    }

    /// The size column of an entry: folders have none of their own.
    static func size(of entry: FileEntry) -> String {
        entry.isDirectory ? none : size(entry.size)
    }

    /// "5,120": grouped the same way whatever the locale, in the footer, the preview header and the folder summary.
    static func count<Value: BinaryInteger>(_ value: Value) -> String {
        let digits = Array(String(value.magnitude))
        var out = value < 0 ? "-" : ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    /// "now", "35m", "2h", "6d", "13d", "2y": the age of `date` at `reference`. A date in the future (clock skew
    /// between hosts) reads "now". The list's column and the preview header's "modified 6m ago" both use it.
    static func age(_ date: Date?, at reference: Date) -> String {
        guard let date else { return none }
        let seconds = reference.timeIntervalSince(date)
        guard seconds >= 60 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 365 { return "\(days)d" }
        return "\(days / 365)y"
    }

    /// The preview header's "modified 6m ago", "modified just now".
    static func modified(_ date: Date, at reference: Date) -> String {
        let age = age(date, at: reference)
        return age == "now" ? "modified just now" : "modified \(age) ago"
    }

    /// The offline bar's "list is 2 min old".
    static func staleness(since: Date, at reference: Date) -> String {
        let minutes = Int(max(0, reference.timeIntervalSince(since)) / 60)
        if minutes < 1 { return "list is less than a minute old" }
        if minutes < 60 { return "list is \(minutes) min old" }
        let hours = minutes / 60
        if hours < 24 { return "list is \(hours) \(hours == 1 ? "hour" : "hours") old" }
        let days = hours / 24
        return "list is \(days) \(days == 1 ? "day" : "days") old"
    }

    /// The folder summary's "today 14:02", "yesterday 09:10", "3 Oct 14:02", or "3 Oct 2024" in another year.
    static func timestamp(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(time: .shortened).locale(Locale(identifier: "en_GB")))
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        let style = Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "en_GB"))
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(date.formatted(style)) \(time)"
        }
        return date.formatted(style.year())
    }

    /// The header's name for a file's language or format, from its name; nil when it has none worth naming.
    static func kindName(_ name: String) -> String? {
        let lower = name.lowercased()
        switch lower {
        case "makefile", "gnumakefile": return "Makefile"
        case "dockerfile", "containerfile": return "Dockerfile"
        default: break
        }
        switch (lower as NSString).pathExtension {
        case "ts", "tsx", "mts", "cts": return "TypeScript"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "py": return "Python"
        case "swift": return "Swift"
        case "rs": return "Rust"
        case "go": return "Go"
        case "c": return "C"
        case "h": return "C header"
        case "cc", "cpp", "cxx", "hpp", "hh": return "C++"
        case "m": return "Objective-C"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "cs": return "C#"
        case "rb": return "Ruby"
        case "php": return "PHP"
        case "lua": return "Lua"
        case "json", "jsonl": return "JSON"
        case "yml", "yaml": return "YAML"
        case "toml": return "TOML"
        case "ini", "cfg", "conf": return "Config"
        case "md", "markdown": return "Markdown"
        case "sh", "bash", "zsh": return "Shell"
        case "fish": return "Fish"
        case "css": return "CSS"
        case "scss": return "SCSS"
        case "html", "htm": return "HTML"
        case "xml", "plist": return "XML"
        case "svg": return "SVG"
        case "sql": return "SQL"
        case "diff", "patch": return "Diff"
        case "txt", "text", "log": return "Plain text"
        case "csv": return "CSV"
        case "png": return "PNG"
        case "jpg", "jpeg": return "JPEG"
        case "gif": return "GIF"
        case "heic": return "HEIC"
        case "webp": return "WebP"
        case "tif", "tiff": return "TIFF"
        case "bmp": return "BMP"
        case "pdf": return "PDF"
        case "zip": return "Zip archive"
        case "gz", "tgz": return "Gzip archive"
        case "zst": return "Zstandard archive"
        default: return nil
        }
    }

    /// Where an entry sits, as the preview header's first word: its folder relative to the root shown ("src/routes"),
    /// the root's own name for a top-level entry ("api"), else the folder with `~` for home.
    static func location(of path: String, root: String?, home: String?) -> String {
        let folder = FilesPath.parent(path) ?? "/"
        if let root = root.map(FilesPath.normalized), !root.isEmpty {
            if folder == root { return FilesPath.name(root) }
            let prefix = root == "/" ? "/" : root + "/"
            if folder.hasPrefix(prefix) { return String(folder.dropFirst(prefix.count)) }
        }
        if let home = home.map(FilesPath.normalized), !home.isEmpty, home != "/" {
            if folder == home { return "~" }
            if folder.hasPrefix(home + "/") { return "~/" + folder.dropFirst(home.count + 1) }
        }
        return folder
    }
}

/// One link of the header's path (F2a): `~` for the home folder, then a folder name per level.
struct FilesCrumb: Hashable, Sendable {
    let title: String
    /// The folder a click pins as the root.
    let path: String
}

/// Absolute paths on the source host, which is not necessarily this Mac: plain string work, never `FileManager`.
enum FilesPath {
    /// `path` without a trailing slash; "/" stays "/".
    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func join(_ directory: String, _ name: String) -> String {
        let directory = normalized(directory)
        return directory == "/" ? "/" + name : directory + "/" + name
    }

    /// The last component: "billing.ts"; "/" for the file system root.
    static func name(_ path: String) -> String {
        let path = normalized(path)
        guard path != "/" else { return "/" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The enclosing folder; nil for "/" (and for a relative path, which the sources never return).
    static func parent(_ path: String) -> String? {
        let path = normalized(path)
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// `path`, then each folder enclosing it down to "/", as Finder's title menu lists them.
    static func ancestors(_ path: String) -> [String] {
        Array(sequence(first: normalized(path), next: parent))
    }

    /// Whether `path` is `ancestor` or lies below it.
    static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        let path = normalized(path), ancestor = normalized(ancestor)
        return path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    /// The crumbs as one line, "homelab: ~ / src / api": what the header reads to VoiceOver.
    static func crumbLine(root: String, home: String?, host: String?) -> String {
        let crumbs = crumbs(root: root, home: home)
        var line = ""
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 { line += crumbs[index - 1].title == "/" ? " " : " / " }
            line += crumb.title
        }
        return host.map { "\($0): \(line)" } ?? line
    }

    /// `~ / src / api` below `home`, else `/ / usr / lib`-style from the file system root.
    static func crumbs(root: String, home: String?) -> [FilesCrumb] {
        let root = normalized(root)
        if let home = home.map(normalized), home != "/", isWithin(root, home) {
            var crumbs = [FilesCrumb(title: "~", path: home)]
            var path = home
            for part in root.dropFirst(home.count).split(separator: "/") {
                path = join(path, String(part))
                crumbs.append(FilesCrumb(title: String(part), path: path))
            }
            return crumbs
        }
        var crumbs = [FilesCrumb(title: "/", path: "/")]
        var path = "/"
        for part in root.split(separator: "/") {
            path = join(path, String(part))
            crumbs.append(FilesCrumb(title: String(part), path: path))
        }
        return crumbs
    }
}
