// Ghostty's theme lookup (config/theme.zig open) for Config.finalize: an absolute path, or a name
// in the user's themes (os/xdg.zig config dir + ghostty/themes) and then the resources' themes,
// with Ghostty's diagnostics. Foundation only (its diff test runs on Linux too).
import Foundation
import Term
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension Config {
    /// The theme file's text for a `theme` value; nil: not loaded, `diagnostics` got why.
    /// `resources`: Ghostty's resources directory; `environment`: the process's (XDG_CONFIG_HOME, HOME).
    public static func theme(_ name: String, resources: String?, environment: [String: String], diagnostics: inout [String]) -> [UInt8]? {
        // A file that opens: its text, or nil with a diagnostic when it is no regular file.
        let read = { (path: String, diagnostics: inout [String]) -> [UInt8]? in
            var st = stat()
            guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
                diagnostics.append("not reading theme from \"\(name)\": it is a \(kind(st.st_mode))")
                return nil
            }
            return FileManager.default.contents(atPath: path).map { [UInt8]($0) }
        }
        if name.hasPrefix("/") {
            guard access(name, F_OK) == 0 else { diagnostics.append("failed to load theme from the path \"\(name)\""); return nil }
            return read(name, &diagnostics)
        }
        guard !name.contains("/") else {
            diagnostics.append("theme \"\(name)\" cannot include path separators unless it is an absolute path")
            return nil
        }
        // LocationIterator: the user's directory (none without a home), then the resources'.
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let user = xdg.map { join([$0, "ghostty/themes"]) } ?? home(environment).map { join([$0, ".config", "ghostty/themes"]) }
        let dirs = [user, resources.map { join([$0, "themes"]) }].compactMap { $0 }
        for dir in dirs where access(join([dir, name]), F_OK) == 0 {
            return read(join([dir, name]), &diagnostics)
        }
        diagnostics += dirs.map { "theme \"\(name)\" not found, tried path \"\(join([$0, name]))\"" }
        return nil
    }

    /// std.fs.path.join: empty parts dropped, one separator between parts.
    static func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.reduce("") { a, b in
            a.isEmpty ? b : a.hasSuffix("/") && b.hasPrefix("/") ? a + b.dropFirst() : a.hasSuffix("/") || b.hasPrefix("/") ? a + b : a + "/" + b
        }
    }

    /// os/homedir.zig: HOME, else the user's home directory.
    static func home(_ environment: [String: String]) -> String? {
        if let h = environment["HOME"] { return h }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.path
        #else
        return getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
        #endif
    }

    /// std.Io.File.Kind's name for a mode.
    static func kind(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: "directory"
        case S_IFCHR: "character_device"
        case S_IFBLK: "block_device"
        case S_IFIFO: "named_pipe"
        case S_IFSOCK: "unix_domain_socket"
        default: "unknown"
        }
    }
}
