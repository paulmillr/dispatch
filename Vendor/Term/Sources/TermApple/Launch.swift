// What a surface's process runs, like Ghostty's embedded surface: the surface options
// (apprt/embedded.zig Surface.init), the config defaults (Config.finalize: shell, working
// directory), the environment (Surface.init, embedded defaultTermioEnv), Exec.zig's
// Subprocess.init + execCommand and shell_integration.zig, for shell commands (the only kind a
// surface gets) with Dispatch's config: shell integration detected, cursor blink unset.
// Foundation only: the non-macOS branches are Ghostty's other POSIX paths, so the same diff test
// runs on Linux.
import Foundation
import Term
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct Launch {
    public var argv: [String], env: [String: String]
    /// nil: the caller's working directory.
    public var directory: String?

    public struct Failure: Error {}

    /// `command`, `directory`, `overrides`: the surface's options (nil or empty: the config's);
    /// `environment`: the process's; `resources`: Ghostty's resources directory
    /// (GHOSTTY_RESOURCES_DIR); `id`: GHOSTTY_SURFACE_ID.
    /// Throws where Ghostty fails the surface (bash's injected flags past their 32 bytes).
    public init(command: String?, directory: String?, overrides: [(String, String)], config: Config, environment: [String: String],
                resources: String?, id: UInt64) throws {
        let pw = Self.user(), desktop = Self.desktop(environment)
        // Config.finalize: SHELL only when started from a terminal, else the passwd shell; the
        // working directory: inherited from a terminal, else home.
        let cli = !desktop && (environment["TERM_PROGRAM"].map { !$0.isEmpty } == true || CommandLine.arguments.count > 1)
        var shell = (cli ? environment["SHELL"] : nil) ?? pw.shell
        var cwd = cli ? nil : pw.home
        // The surface's options: a directory only if it opens as one.
        if let d = directory, !d.isEmpty, Self.opens(d, directory: true) { cwd = d }
        if let c = command, !c.isEmpty { shell = c }

        var env = environment
        #if os(macOS)
        if env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
            for k in ["__XCODE_BUILT_PRODUCTS_DIR_PATHS", "__XPC_DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES",
                      "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SECURITYSESSIONID", "XPC_SERVICE_NAME"] { env[k] = nil }
        }
        env["GHOSTTY_MAC_LAUNCH_SOURCE"] = nil
        if desktop { env["LANGUAGE"] = nil }
        #endif
        env["GHOSTTY_LOG"] = nil
        env["GHOSTTY_SURFACE_ID"] = String(format: "0x%016llx", id)

        // Subprocess.init
        if let r = resources {
            env["GHOSTTY_RESOURCES_DIR"] = r
            (env["TERM"], env["COLORTERM"]) = (config.term, "truecolor")
            // Ghostty's terminfo sits beside its resources and holds only its own entry. Any other
            // TERM resolves from the system database, never from a directory beside the resources.
            env["TERMINFO"] = config.term == "xterm-ghostty" ? Self.dirname(r)! + "/terminfo" : nil
        } else {
            (env["TERM"], env["COLORTERM"]) = ("xterm-256color", "truecolor")
        }
        if let exe = Self.executable(), let bin = Self.dirname(exe) {
            env["GHOSTTY_BIN_DIR"] = bin
            if let path = env["PATH"] {
                if !path.split(separator: ":").contains(where: { $0 == bin }) { env["PATH"] = path.isEmpty ? bin : path + ":" + bin }
            } else {
                env["PATH"] = bin
            }
        }
        #if os(macOS)
        if let r = resources {
            let data = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = data.isEmpty ? r + "/.." : data + ":" + r + "/.."
            env["MANPATH"] = (env["MANPATH"] ?? "") + ":" + r + "/../man"
        }
        #endif
        (env["TERM_PROGRAM"], env["TERM_PROGRAM_VERSION"], env["VTE_VERSION"]) = ("ghostty", ghosttyVersion, nil)

        let s = config.shellIntegration
        let named: [(String, Bool)] = [("cursor:blink", s.cursor), ("path", s.path), ("ssh-env", s.sshEnv), ("ssh-terminfo", s.sshTerminfo), ("sudo", s.sudo), ("title", s.title)]
        let features = named.filter(\.1).map(\.0).joined(separator: ",")
        if !features.isEmpty { env["GHOSTTY_SHELL_FEATURES"] = features }
        let run = try resources.flatMap { try Self.integrate(shell ?? "sh", $0, &env) } ?? shell ?? "sh"

        for (k, v) in overrides { env[k] = v }
        argv = Self.exec(run, pw, home: overrides.last { $0.0 == "HOME" }?.1)
        self.directory = cwd
        if let cwd { env["PWD"] = cwd }
        self.env = env
    }

    // MARK: os/locale.zig

    /// Ghostty's process start (ensureLocale), once per process before any Launch: on macOS a
    /// missing LANG comes from the system locale and LANGUAGE from the preferred languages
    /// (gettext's names); a locale the C library rejects falls back to the system's, then en_US.UTF-8.
    public static func ensureLocale() {
        #if os(macOS)
        if (getenv("LANG").map { $0.pointee == 0 } ?? true) {
            let locale = NSLocale.current as NSLocale
            if let lang = locale.languageCode as String?, let country = locale.countryCode {
                setenv("LANG", "\(lang)_\(country).UTF-8", 1)
                let preferred = NSLocale.preferredLanguages.map { gettextName($0) + ".UTF-8" }.joined(separator: ":")
                // Ghostty's 1024-byte buffer (with its NUL): longer lists leave LANGUAGE as it is.
                if !preferred.isEmpty, preferred.utf8.count < 1024 { setenv("LANGUAGE", preferred, 1) }
            }
        }
        #endif
        if setlocale(LC_ALL, "") != nil { return }
        if let lang = getenv("LANG"), lang.pointee != 0 {
            unsetenv("LANG")
            if let v = setlocale(LC_ALL, ""), strcmp(v, "C") != 0 { return }
        }
        if setlocale(LC_ALL, "en_US.UTF-8") != nil { setenv("LANG", "en_US.UTF-8", 1) }
    }

    /// A macOS language name as gettext's (os/i18n.zig canonicalizeLocale: fixZhLocale, then
    /// gnulib's gl_locale_name_canonicalize for macOS: legacy English names, 7-character tags with
    /// a script, dashes to underscores).
    static func gettextName(_ name: String) -> String {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "zh" {
            if parts[1] == "Hans" { return parts[2] == "SG" ? "zh_SG" : "zh_CN" }
            if parts[1] == "Hant" { return parts[2] == "MO" ? "zh_MO" : parts[2] == "HK" ? "zh_HK" : "zh_TW" }
        }
        if let legacy = legacyNames[name] { return legacy }
        if name.utf8.count == 7, parts.count >= 2, parts[0].utf8.count == 2 {
            if let tag = languageTags[name] { return tag }
            if let script = scripts[String(name.dropFirst(3))] { return parts[0] + "@" + script }
        }
        return name.replacingOccurrences(of: "-", with: "_")
    }

    static let languageTags = ["az-Latn": "az", "bs-Latn": "bs", "ga-dots": "ga", "kk-Cyrl": "kk", "mn-Cyrl": "mn", "ms-Latn": "ms", "pa-Arab": "pa_PK",
                               "pa-Guru": "pa_IN", "sr-Cyrl": "sr", "tg-Cyrl": "tg", "tk-Cyrl": "tk", "tt-Cyrl": "tt", "uz-Latn": "uz", "yue-Hans": "yue",
                               "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"]
    static let scripts = ["Arab": "arabic", "Cyrl": "cyrillic", "Latn": "latin", "Mong": "mongolian"]
    /// NeXTstep's English language names (gnulib's legacy_table).
    static let legacyNames = [
        "Afrikaans": "af", "Albanian": "sq", "Amharic": "am", "Arabic": "ar", "Armenian": "hy", "Assamese": "as", "Aymara": "ay", "Azerbaijani": "az",
        "Basque": "eu", "Belarusian": "be", "Belorussian": "be", "Bengali": "bn", "Brazilian Portugese": "pt_BR", "Brazilian Portuguese": "pt_BR",
        "Breton": "br", "Bulgarian": "bg", "Burmese": "my", "Byelorussian": "be", "Catalan": "ca", "Chewa": "ny", "Chichewa": "ny", "Chinese": "zh",
        "Chinese, Simplified": "zh_CN", "Chinese, Traditional": "zh_TW", "Chinese, Tradtional": "zh_TW", "Croatian": "hr", "Czech": "cs", "Danish": "da",
        "Dutch": "nl", "Dzongkha": "dz", "English": "en", "Esperanto": "eo", "Estonian": "et", "Faroese": "fo", "Farsi": "fa", "Finnish": "fi",
        "Flemish": "nl_BE", "French": "fr", "Galician": "gl", "Gallegan": "gl", "Georgian": "ka", "German": "de", "Greek": "el", "Greenlandic": "kl",
        "Guarani": "gn", "Gujarati": "gu", "Hawaiian": "haw", "Hebrew": "he", "Hindi": "hi", "Hungarian": "hu", "Icelandic": "is", "Indonesian": "id",
        "Inuktitut": "iu", "Irish": "ga", "Italian": "it", "Japanese": "ja", "Javanese": "jv", "Kalaallisut": "kl", "Kannada": "kn", "Kashmiri": "ks",
        "Kazakh": "kk", "Khmer": "km", "Kinyarwanda": "rw", "Kirghiz": "ky", "Korean": "ko", "Kurdish": "ku", "Latin": "la", "Latvian": "lv",
        "Lithuanian": "lt", "Macedonian": "mk", "Malagasy": "mg", "Malay": "ms", "Malayalam": "ml", "Maltese": "mt", "Manx": "gv", "Marathi": "mr",
        "Moldavian": "mo", "Mongolian": "mn", "Nepali": "ne", "Norwegian": "nb", "Nyanja": "ny", "Nynorsk": "nn", "Oriya": "or", "Oromo": "om",
        "Panjabi": "pa", "Pashto": "ps", "Persian": "fa", "Polish": "pl", "Portuguese": "pt", "Portuguese, Brazilian": "pt_BR", "Punjabi": "pa",
        "Pushto": "ps", "Quechua": "qu", "Romanian": "ro", "Ruanda": "rw", "Rundi": "rn", "Russian": "ru", "Sami": "se_NO", "Sanskrit": "sa",
        "Scottish": "gd", "Serbian": "sr", "Simplified Chinese": "zh_CN", "Sindhi": "sd", "Sinhalese": "si", "Slovak": "sk", "Slovenian": "sl",
        "Somali": "so", "Spanish": "es", "Sundanese": "su", "Swahili": "sw", "Swedish": "sv", "Tagalog": "tl", "Tajik": "tg", "Tajiki": "tg",
        "Tamil": "ta", "Tatar": "tt", "Telugu": "te", "Thai": "th", "Tibetan": "bo", "Tigrinya": "ti", "Tongan": "to", "Traditional Chinese": "zh_TW",
        "Turkish": "tr", "Turkmen": "tk", "Uighur": "ug", "Ukrainian": "uk", "Urdu": "ur", "Uzbek": "uz", "Vietnamese": "vi", "Welsh": "cy", "Yiddish": "yi",
    ]

    // MARK: shell_integration.zig

    /// The command with the detected shell's integration set up in `env`; nil: no integration.
    static func integrate(_ command: String, _ resources: String, _ env: inout [String: String]) throws -> String? {
        let args = words(command)
        guard let arg0 = args.first else { return nil }
        let integration = resources + "/shell-integration"
        let xdg = { (env: inout [String: String]) -> Bool in
            guard opens(integration, directory: true) else { return false }
            env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            let data = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = data.isEmpty ? integration : integration + ":" + data
            return true
        }
        switch arg0.split(separator: "/").last ?? "" {
        case "bash":
            #if os(macOS)
            if arg0 == "/bin/bash" { return nil }   // Apple's bash 3.2 ignores ENV in POSIX mode
            #endif
            var out = [arg0, "--posix"], inject = "1", rcfile: String?, rest = args.dropFirst()
            while let arg = rest.popFirst() {
                if arg == "--posix" { return nil }
                if arg == "--norc" || arg == "--noprofile" {
                    inject += " " + arg
                    guard inject.utf8.count <= 32 else { throw Failure() }
                    continue
                }
                if arg == "--rcfile" || arg == "--init-file" { rcfile = rest.popFirst(); continue }
                if short(arg), arg.utf8.contains(0x63) { return nil }   // -c: not interactive
                out.append(arg)
                if arg == "-" || arg == "--" { out += rest; break }
            }
            if let old = env["ENV"] { env["GHOSTTY_BASH_ENV"] = old }
            let script = integration + "/bash/ghostty.bash"
            guard opens(script, directory: false) else { env["GHOSTTY_BASH_ENV"] = nil; return nil }
            (env["ENV"], env["GHOSTTY_BASH_INJECT"]) = (script, inject)
            if let rcfile { env["GHOSTTY_BASH_RCFILE"] = rcfile }
            if env["HISTFILE"] == nil, let home = Config.home(ProcessInfo.processInfo.environment) {
                (env["HISTFILE"], env["GHOSTTY_BASH_UNEXPORT_HISTFILE"]) = (home + "/.bash_history", "1")
            }
            return join(out)
        case "zsh":
            if let old = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
            guard opens(integration + "/zsh", directory: true) else { return nil }
            env["ZDOTDIR"] = integration + "/zsh"
            return command
        case "nu":
            guard xdg(&env) else { return nil }
            var out = [arg0, "--execute 'use ghostty *'"], rest = args.dropFirst()
            while let arg = rest.popFirst() {
                if arg == "--command" || arg == "--lsp" { return nil }
                if short(arg), arg.utf8.contains(0x63) { return nil }
                out.append(arg)
                if arg == "-" || arg == "--" { out += rest; break }
            }
            return join(out)
        case "elvish", "fish": return xdg(&env) ? command : nil
        default: return nil
        }
    }

    /// A short option (or a bundle of them): `-x`, not `-` or `--x`.
    static func short(_ arg: String) -> Bool { arg.utf8.count > 1 && arg.hasPrefix("-") && !arg.hasPrefix("--") }

    /// ShellCommandBuilder: non-empty arguments joined by spaces, unquoted.
    static func join(_ args: [String]) -> String { args.filter { !$0.isEmpty }.joined(separator: " ") }

    /// Command.argIterator for a shell command: zig's IteratorGeneral(.{}): blanks split, double
    /// quotes group, backslashes are literal except before a quote (2n: n and the quote toggles;
    /// 2n+1: n and a literal quote); a NUL ends the line.
    static func words(_ line: String) -> [String] {
        let b = Array(line.utf8.prefix { $0 != 0 })
        let blank = { (c: UInt8) in c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }
        var out: [String] = [], i = 0
        while true {
            while i < b.count, blank(b[i]) { i += 1 }
            guard i < b.count else { return out }
            var word: [UInt8] = [], slashes = 0, quoted = false
            while i < b.count, quoted || !blank(b[i]) {
                let c = b[i]
                i += 1
                if c == 0x5C { slashes += 1; continue }
                word += repeatElement(0x5C, count: c == 0x22 ? slashes / 2 : slashes)
                if c != 0x22 || slashes % 2 == 1 { word.append(c) } else { quoted.toggle() }
                slashes = 0
            }
            word += repeatElement(0x5C, count: slashes)
            out.append(String(decoding: word, as: UTF8.self))
        }
    }

    // MARK: Exec.zig execCommand

    /// macOS: login(1) runs the command in a login shell (quietly with ~/.hushlogin); else /bin/sh -c.
    static func exec(_ command: String, _ pw: (name: String?, home: String?, shell: String?), home: String?) -> [String] {
        #if os(macOS)
        if let name = pw.name {
            let hush = pw.home.map { opens($0, directory: true) && access($0 + "/.hushlogin", F_OK) == 0 } ?? false
            // login resets HOME even with -p; restore explicit overrides before the shell starts.
            return ["/usr/bin/login"] + (hush ? ["-q"] : []) + ["-flp", name]
                + (home.map { ["/usr/bin/env", "HOME=" + $0] } ?? [])
                + ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l " + command]
        }
        #endif
        return ["/bin/sh", "-c", command]
    }

    // MARK: the system

    /// The passwd entry (os/passwd.zig).
    static func user() -> (name: String?, home: String?, shell: String?) {
        var pw = passwd(), result: UnsafeMutablePointer<passwd>?
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { buf in
            guard getpwuid_r(getuid(), &pw, buf.baseAddress!, buf.count, &result) == 0, result != nil else { return (nil, nil, nil) }
            let s = { (p: UnsafeMutablePointer<CChar>?) in p.map { String(cString: $0) } }
            return (s(pw.pw_name), s(pw.pw_dir), s(pw.pw_shell))
        }
    }

    /// Started from the Dock/Finder (os/desktop.zig): launchd is the parent, or the embedder says so.
    static func desktop(_ environment: [String: String]) -> Bool {
        #if os(macOS)
        return environment["GHOSTTY_MAC_LAUNCH_SOURCE"] == "app" || getppid() == 1
        #else
        return false
        #endif
    }

    /// std.process.executablePath: this process's executable, symlinks resolved.
    static func executable() -> String? {
        #if os(macOS)
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0, let real = realpath(buf, nil) else { return nil }
        #else
        guard let real = realpath("/proc/self/exe", nil) else { return nil }
        #endif
        defer { free(real) }
        return String(cString: real)
    }

    /// Opens like Ghostty's openFileAbsolute / openDirAbsolute.
    static func opens(_ path: String, directory: Bool) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    /// std.fs.path.dirname for absolute paths: nil for the root.
    static func dirname(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 || (parts.count == 1 && path.hasPrefix("/")) else { return nil }
        return parts.count == 1 ? "/" : (path.hasPrefix("/") ? "/" : "") + parts.dropLast().joined(separator: "/")
    }
}
