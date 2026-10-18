import Foundation

/// The one "~" rule for paths on a host (Spaces rows, a tab's subtitle, Terminal's subtitle, host detail, Chat's intro):
/// a path inside the account's home shows from "~". The homes are what the helper reports: the login environment's
/// `HOME` when it exposes it (`hello.account.login_home`, which differs from the password database's home when a host
/// or a fixture sets HOME), and the account's home (`hello.account.home`). Of the two, the longer match wins, so a
/// HOME inside the account's home still shortens to "~". Never guessed from `/Users/<name>` or `/home/<name>`.
struct HomePath: Equatable, Sendable {
    /// `hello.account.home`.
    var account: String?
    /// The login environment's HOME, when the helper reports it.
    var login: String?

    init(account: String?, login: String? = nil) {
        self.account = account
        self.login = login
    }

    /// The hello's homes.
    init(_ hello: HelperSession.Info?) {
        self.init(account: hello?.account?.home, login: hello?.account?.login_home)
    }

    /// The home a typed "~" means: the login environment's, as the shell expands it, else the account's.
    var primary: String? { [login, account].compactMap(Self.usable).first }

    /// `/Users/me/src/app` as `~/src/app`; `/Users/me` as `~`; anything else unchanged. On macOS `/tmp`, `/var` and
    /// `/etc` are `/private/…`: a home given one way matches a path reported the other way.
    func abbreviate(_ path: String) -> String {
        let homes = [login, account].compactMap(Self.usable).map(Self.canonical).sorted { $0.count > $1.count }
        let canonical = Self.canonical(path)
        for home in homes {
            if canonical == home || canonical == home + "/" { return "~" }
            if canonical.hasPrefix(home + "/") { return "~" + canonical.dropFirst(home.count) }
        }
        return path
    }

    /// `/private/tmp/x` as `/tmp/x` (macOS's symbolic links at the root), anything else unchanged.
    private static func canonical(_ path: String) -> String {
        for root in ["/tmp", "/var", "/etc"] where path == "/private" + root || path.hasPrefix("/private" + root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    func abbreviate(_ path: String?) -> String? { path.map { abbreviate($0) } }

    /// A typed `~` or `~/x` as the host's absolute path (the helper's `cwd` takes absolute paths).
    func expand(_ path: String) -> String {
        guard let home = primary, path == "~" || path.hasPrefix("~/") else { return path }
        return path == "~" ? home : home + "/" + path.dropFirst(2)
    }

    /// A home without its trailing slash; nil when empty or the root (nothing would read better as "~").
    private static func usable(_ home: String?) -> String? {
        guard var home, !home.isEmpty else { return nil }
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return home == "/" ? nil : home
    }
}
