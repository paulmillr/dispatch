import Foundation

/// The places on a Mac whose first read raises a macOS consent prompt for the app (System Settings › Privacy &
/// Security › Files and Folders, and App Data): Dispatch reads them only when the user asked for that folder (opened,
/// expanded, a size counted on request), never because a row was selected. Places guarded by Full Disk Access alone
/// (Mail, Messages, Safari, Contacts, Calendars, the TCC databases) never prompt: a read there just fails, so they are
/// not listed. Checked on macOS 27.2.1 with a foreground app that had no answers yet (tmp/tcc-probe.sh): reading inside
/// Desktop, Documents, Downloads and the Photos library asks, the read waiting for the answer (local Files calls have no
/// time bound, so an opened folder lists once allowed); a folder's own details (`stat`) and listing `~/Library`,
/// its Containers, Group Containers and CloudStorage do not; Mail and a group container are refused without asking.
/// Containers stay guarded child by child, the cautious reading. Over SSH nothing can prompt (a remote Mac refuses the read unless Remote Login allows full disk access
/// for remote users), so this applies to this Mac only.
enum ProtectedFolders {
    /// Folders of the home guarded as a whole: one answer covers everything inside. `Library/Mobile Documents` is
    /// iCloud Drive (and Desktop and Documents when iCloud keeps them); the Photos library's package asks for Photos.
    static let homeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Pictures/Photos Library.photoslibrary"]
    /// Folders of the home whose every child is guarded on its own: each file provider's folder (Dropbox, Google
    /// Drive), and each other app's container ("…would like to access data from other apps").
    static let homeParents = ["Library/CloudStorage", "Library/Containers", "Library/Group Containers"]
    /// Every mounted volume but the startup disk (removable and network volumes) is guarded on its own.
    static let volumes = "/Volumes"

    /// A guarded place: one folder, or each child of a folder.
    enum Place: Hashable {
        case folder(String)
        case eachChild(String)
    }

    /// Whether `path` is one of the home's guarded places or inside one (drops stage such files: `FilesDragController`).
    static func isProtected(_ path: String, home: String) -> Bool {
        let path = normalized(path)
        return (homeFolders + homeParents).contains { inside(path, (home as NSString).appendingPathComponent($0)) }
    }

    /// The guarded places a walk of `path` would read: the one it lies in, else every one below it (counting `~`
    /// would read Documents, Desktop, each container…). Empty for a folder that touches none.
    static func places(walking path: String, home: String) -> [Place] {
        let path = normalized(path)
        let folders = homeFolders.map { (home as NSString).appendingPathComponent($0) }
        let parents = homeParents.map { (home as NSString).appendingPathComponent($0) } + [volumes]
        if let folder = folders.first(where: { inside(path, $0) }) { return [.folder(folder)] }
        for parent in parents where path.hasPrefix(parent + "/") {
            let child = path.dropFirst(parent.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return [.folder(parent + "/" + child)]
        }
        return folders.filter { inside($0, path) }.map(Place.folder) + parents.filter { inside($0, path) }.map(Place.eachChild)
    }

    /// `path` is `folder` or inside it.
    private static func inside(_ path: String, _ folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// The data volume's own path for a home folder is the same folder (`/System/Volumes/Data/Users/…`); the data
    /// volume and the folders holding it hold everything `/` does.
    static func normalized(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if [data, "/System", "/System/Volumes"].contains(path) { return "/" }
        guard path.hasPrefix(data + "/") else { return path }
        return String(path.dropFirst(data.count))
    }
}
