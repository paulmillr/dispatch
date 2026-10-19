import Foundation
import Observation

/// Reads a whole file on the conversation's host (`files.text`, absolute path).
typealias CodeFileLoader = @MainActor (String) async throws -> String

/// The diff's text size (M5d): pinch zoom between 8 and 24 points in half-point steps, kept across launches as the
/// terminal keeps its own (`terminal.fontSize`).
enum CodeFontSize {
    static let key = "code.fontSize"
    static let standard = 12.0
    static let range = 8.0...24.0

    @MainActor static func stored(_ store: CodeFontStore) -> Double {
        let value = store.load() ?? 0
        return range.contains(value) ? value : standard
    }

    /// `base` scaled by a pinch, within `range`, in half-point steps.
    static func pinched(base: Double, scale: Double) -> Double {
        let size = min(max(base * scale, range.lowerBound), range.upperBound)
        return (size * 2).rounded() / 2
    }
}

/// Where the diff's text size is kept: the app's defaults, or memory (tests, previews).
struct CodeFontStore: Sendable {
    let load: @MainActor @Sendable () -> Double?
    let save: @MainActor @Sendable (Double) -> Void

    static let standard = CodeFontStore(load: { UserDefaults.standard.object(forKey: CodeFontSize.key) as? Double },
                                        save: { UserDefaults.standard.set($0, forKey: CodeFontSize.key) })

    @MainActor static func memory(_ initial: Double? = nil) -> CodeFontStore {
        @MainActor final class Box { var value: Double? }
        let box = Box()
        box.value = initial
        return CodeFontStore(load: { box.value }, save: { box.value = $0 })
    }
}

/// What the whole-file mode shows for one file.
enum WholeFileState: Equatable, Sendable {
    case loading
    case loaded(WholeFile)
    case failed(String)
}

/// M5d's state: the turn's changes, which files are open, diff or whole file, the files read so far and the text size.
@MainActor @Observable final class DiffViewModel {
    private(set) var changes: DiffChanges
    private(set) var open: Set<String>
    private(set) var whole = false
    private(set) var states: [String: WholeFileState] = [:]
    var fontSize: Double
    /// Patch steps whose diff is being fetched in full (`chat.tools`).
    private(set) var completing = false

    @ObservationIgnored private var items: [ChatItem]
    @ObservationIgnored private let directory: String?
    @ObservationIgnored let host: String
    @ObservationIgnored private let load: CodeFileLoader
    @ObservationIgnored private let fonts: CodeFontStore
    @ObservationIgnored private var highlights: [String: [AttributedString]] = [:]

    /// `items` are the turn's patch steps; the files `opening` touched start open.
    init(items: [ChatItem], opening: ChatItem?, directory: String?, host: String, fonts: CodeFontStore = .standard,
         load: @escaping CodeFileLoader) {
        self.items = items
        self.directory = directory
        self.host = host
        self.load = load
        self.fonts = fonts
        let changes = DiffChanges(items: items, directory: directory)
        self.changes = changes
        let first = opening.map { DiffChanges(items: [$0], directory: directory).files.map(\.id) } ?? []
        open = Set(first.isEmpty ? changes.files.prefix(1).map(\.id) : first)
        fontSize = CodeFontSize.stored(fonts)
    }

    /// The file's lines in the palette (computed once per file).
    func highlighted(_ file: DiffFile) -> [AttributedString] {
        if let cached = highlights[file.id], cached.count == file.lines.count { return cached }
        let lines = file.highlighted()
        highlights[file.id] = lines
        return lines
    }

    func toggle(_ file: DiffFile) {
        if open.contains(file.id) { open.remove(file.id) } else {
            open.insert(file.id)
            if whole { read(file) }
        }
    }

    /// The trailing pill: the whole file of every open section, or back to the hunks.
    func toggleWhole() {
        whole.toggle()
        guard whole else { return }
        for file in changes.files where open.contains(file.id) { read(file) }
    }

    /// Ends a pinch: the size is kept for the next diff.
    func commitFontSize() { fonts.save(fontSize) }

    /// Reads `file` unless it is read or being read; a failure is asked again.
    func read(_ file: DiffFile) {
        switch states[file.id] {
        case .loading?, .loaded?: return
        case .failed?, nil: break
        }
        guard let path = file.absolutePath else {
            states[file.id] = .failed("The patch does not say which folder \(file.title) is in.")
            return
        }
        states[file.id] = .loading
        let load = load, host = host
        Task {
            let state: WholeFileState
            do {
                let text = try await load(path)
                state = .loaded(await Task.detached(priority: .userInitiated) { WholeFile(file: file, text: text) }.value)
            } catch {
                state = .failed(Self.explain(error, file: file, host: host))
            }
            self.states[file.id] = state
        }
    }

    /// Patch steps a page delivered without their diff are read in full (`chat.tools`) once.
    func complete(_ fetch: @escaping @MainActor (ChatItem) async throws -> ChatItem?) async {
        let empty = items.indices.filter { index in
            ToolPresentation(items[index]).documents.allSatisfy { $0.diff.isEmpty }
        }
        guard !empty.isEmpty else { return }
        completing = true
        defer { completing = false }
        var changed = false
        for index in empty {
            guard let item = try? await fetch(items[index]) else { continue }
            items[index] = item
            changed = true
        }
        if changed {
            changes = DiffChanges(items: items, directory: directory)
            highlights = [:]
            states = [:]
            if whole { for file in changes.files where open.contains(file.id) { read(file) } }
        }
    }

    static func explain(_ error: any Error, file: DiffFile, host: String) -> String {
        guard let failure = error as? HelperFailure else { return error.localizedDescription }
        switch failure.code {
        case "not_found": return "\(file.title) is no longer on \(host)."
        case "unsupported": return "Only UTF-8 text files up to 2 MB can be shown."
        case "permission_denied": return "\(host) does not allow reading \(file.title)."
        case "connection_closed", "closed", "offline": return "\(host) is not connected."
        default: return failure.message.isEmpty ? "\(file.title) could not be read (\(failure.code))." : failure.message
        }
    }
}

extension MobileChatSession {
    /// A whole file on this conversation's host (`files.text`), through the conversation's helper.
    func fileText(_ path: String) async throws -> String {
        guard let client else {
            throw HelperFailure(code: "offline", message: "\(hostName) is not connected.")
        }
        let text: String = try await client.connection.request("files.text", params: ["plugin": "files", "path": path])
        return text
    }

    /// A patch step's record in full (`chat.tools`), as a transcript item.
    func fullItem(_ item: ChatItem) async throws -> ChatItem? {
        let record = try await fullOutput(of: item)
        guard case .item(let full)? = record.display?.action else { return nil }
        return full
    }
}
