import Foundation

/// Display-only adaptation of agent payloads. Never executes or rewrites a tool call.
struct ToolPresentation: Sendable {
    let title: String
    let symbol: String
    let summary: String
    let input: String
    let language: String
    let directory: String?
    let output: String
    let outputBlocks: [ToolOutput.Block]
    private let outputFailed: Bool
    let exitCode: Int?
    let completed: Bool
    let documents: [ToolDocument]
    let readCommand: ToolReadCommand?
    let commandPresentation: ToolCommandPresentation?
    /// The shell command without a leading `cd` into its own directory, for labels only.
    private let labelCommand: String?
    let confirmedResult: String?
    private let summaryDocuments: [ToolDocument]
    private let summaryReadCommand: ToolReadCommand?
    private let native: NativeToolPresentation?
    let requests: [ChatItem]
    let isOrchestration: Bool
    let isPatch: Bool
    var failed: Bool { outputFailed || (exitCode.map { $0 != 0 } ?? false) }
    let additions: Int
    let deletions: Int

    init(_ item: ChatItem) {
        if let record = item.source {
            let tool = record.tool
            let title = tool?.title ?? item.title, symbol = tool?.symbol ?? "wrench.and.screwdriver"
            let summary = tool?.summary ?? ""
            self.title = title; self.symbol = symbol; self.summary = summary
            input = tool?.input ?? item.text
            language = tool?.language ?? "text"
            directory = tool?.directory
            // `output` is the native result as recorded; the blocks are what it says (program output).
            outputBlocks = record.blocks.isEmpty
                ? [.init(kind: .code("text"), text: item.output)] : record.blocks.map(\.display)
            output = ToolOutput(blocks: outputBlocks).text
            outputFailed = tool?.failed ?? false
            exitCode = item.exitCode
            completed = item.completed
            documents = record.documents.map {
                ToolDocument(path: $0.path, diff: $0.diff, workingDirectory: $0.workdir)
            }
            if let read = tool?.read {
                let selection: ToolReadCommand.Selection?
                switch read.selection.kind {
                case "all": selection = .all
                case "lines": selection = read.selection.start.flatMap { start in
                    read.selection.end.map { .lines(start, $0) }
                }
                case "first": selection = read.selection.count.map(ToolReadCommand.Selection.first)
                case "last": selection = read.selection.count.map(ToolReadCommand.Selection.last)
                default: selection = nil
                }
                readCommand = selection.map { ToolReadCommand(path: read.path, selection: $0) }
            } else { readCommand = nil }
            commandPresentation = tool?.shell.map {
                ToolCommandPresentation(title: title, summary: summary, symbol: symbol,
                                        runningTitle: title, swiftTests: $0.swift_tests)
            }
            labelCommand = nil
            confirmedResult = tool?.confirmed_result
            summaryDocuments = documents
            summaryReadCommand = readCommand
            native = nil
            requests = tool?.children.compactMap { record in
                guard case .item(let item) = record.display?.action else { return nil }
                return item
            } ?? []
            isOrchestration = tool?.orchestration ?? false
            isPatch = tool?.patch ?? false
            additions = tool?.additions ?? 0
            deletions = tool?.deletions ?? 0
            return
        }
        let value = Self.json(item.text)
        let object = value as? [String: Any]
        native = NativeToolPresentation(item, object: object)
        let workingDirectory = object?["workdir"] as? String ?? object?["cwd"] as? String ?? item.directory
        directory = workingDirectory
        let name = item.title.components(separatedBy: ".").last?.lowercased() ?? ""
        isOrchestration = ["exec", "js", "javascript"].contains(name)
        requests = isOrchestration ? ToolOrchestration.requests(in: object?["code"] as? String ?? item.text).filter { !item.hiddenPatchRequests.contains($0.id) } : []
        let command = Self.command(object?["cmd"] ?? object?["command"] ?? (value is [String] ? value : nil))
        // Details keep the original command; titles and summaries skip a
        // leading `cd` into the directory the command already runs in.
        labelCommand = (command ?? (value == nil ? item.text : nil)).map {
            ToolCommandWords.droppingRedundantCd($0, directory: workingDirectory) ?? $0
        }
        readCommand = item.patch == nil && ["shell", "exec_command", "shell_command", "bash"].contains(name)
            ? labelCommand.flatMap(ToolReadCommand.init) : nil
        if name == "write_stdin", let object, object["session_id"] is Int,
           object["chars"] == nil || object["chars"] as? String == "" {
            commandPresentation = .waiting
        } else {
            commandPresentation = item.patch == nil && ["shell", "exec_command", "shell_command", "bash"].contains(name)
                ? labelCommand.flatMap { ToolCommandPresentation.parse($0, directory: workingDirectory ?? "") } : nil
        }
        documents = item.patch?.documents ?? native?.documents ?? (isOrchestration || readCommand != nil ? [] : ToolDocument.parse(item))
        let requestedTool = isOrchestration && requests.count == 1 ? ToolPresentation(requests[0]) : nil
        summaryDocuments = requestedTool?.summaryDocuments ?? documents
        summaryReadCommand = requestedTool?.summaryReadCommand ?? readCommand
        // Diff content can come from a read-only command. Only the operation
        // itself establishes that this step applies a patch.
        isPatch = ChatPatch.isPatchOperation(item)
        additions = documents.reduce(0) { $0 + $1.diff.components(separatedBy: "\n").filter { $0.hasPrefix("+") }.count }
        deletions = documents.reduce(0) { $0 + $1.diff.components(separatedBy: "\n").filter { $0.hasPrefix("-") }.count }
        var result = ToolOutput.decode(item.output)
        let questionRows = name == "request_user_input" ? object?["questions"] as? [[String: Any]] : nil
        let questionAnswers = questionRows == nil ? nil : (Self.json(result.text) as? [String: Any])?["answers"] as? [String: [String: Any]]
        if let questionRows, let questionAnswers {
            let text = questionRows.compactMap { question -> String? in
                guard let id = question["id"] as? String, let title = question["question"] as? String else { return nil }
                let answers = questionAnswers[id]?["answers"] as? [String] ?? []
                let answer = answers.isEmpty ? "Skipped" : question["isSecret"] as? Bool == true ? "Private answer sent" : answers.joined(separator: ", ")
                return title + "\n" + answer
            }.joined(separator: "\n\n")
            result.blocks = [.init(kind: .code("text"), text: text)]
        }
        output = result.text
        outputBlocks = result.blocks; outputFailed = result.failed
        exitCode = result.code ?? item.exitCode
        completed = !result.running && (item.completed || exitCode != nil || (item.processID == nil && !item.output.isEmpty))
        confirmedResult = completed && !result.failed && exitCode == 0
            ? commandPresentation?.confirmedTestResult(output) : nil
        if let questionRows {
            title = questionAnswers == nil ? "Questions" : "Questions answered"
            symbol = "questionmark.bubble"
            summary = questionRows.compactMap { $0["header"] as? String }.joined(separator: ", ")
            input = questionAnswers == nil ? questionRows.compactMap { $0["question"] as? String }.joined(separator: "\n\n") : ""
            language = "text"
        } else if let native {
            title = native.title; symbol = native.symbol; summary = native.summary(in: workingDirectory ?? "")
            input = native.input; language = native.language
        } else if isOrchestration {
            title = "Tools"; symbol = "wrench.and.screwdriver"
            summary = requestedTool?.summary ?? (requests.isEmpty ? (output.isEmpty ? "Agent activity" : "Tool output") : "\(requests.count) operations")
            input = ""; language = "text"
        } else if WebToolPresentation.matches(item.title) {
            let web = WebToolPresentation(object)
            title = web.title; symbol = web.symbol; summary = web.summary
            input = value.map(TranscriptParser.printable) ?? item.text
            language = value == nil ? "text" : "json"
        } else if let readCommand {
            title = "Read"; symbol = "doc.text"
            summary = readCommand.summary(in: directory ?? "")
            input = command ?? item.text; language = "shell"
        } else if let commandPresentation {
            title = commandPresentation.title; symbol = commandPresentation.symbol
            summary = commandPresentation.summary
            input = command ?? item.text; language = command == nil && value != nil ? "json" : "shell"
        } else if !documents.isEmpty {
            let patch = documents.contains { !$0.diff.isEmpty }
            title = isPatch ? "Patch" : (patch ? "Review changes" : "Read")
            symbol = isPatch ? "pencil.line" : (patch ? "doc.text.magnifyingglass" : "doc.text")
            summary = documents.map(\.path).joined(separator: ", ")
            input = command ?? ""; language = "shell"
        } else if let command, let label = labelCommand {
            input = command; language = "shell"
            let executable = label.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let base = (executable as NSString).lastPathComponent
            if ["cat", "head", "tail", "sed"].contains(base) { title = "Read"; symbol = "doc.text" }
            else if ["rg", "grep", "find"].contains(base) { title = "Search"; symbol = "magnifyingglass" }
            else { title = "Shell"; symbol = "terminal" }
            summary = label.components(separatedBy: "\n").first ?? label
        } else if ["shell", "exec_command", "shell_command", "bash"].contains(name), value == nil {
            title = "Shell"; symbol = "terminal"; input = item.text; language = "shell"
            summary = (labelCommand ?? item.text).components(separatedBy: "\n").first ?? ""
        } else {
            title = name == "write_stdin" ? "Terminal input" : (item.title.isEmpty ? "Tool" : item.title)
            symbol = "wrench.and.screwdriver"
            input = value.map(TranscriptParser.printable) ?? item.text
            language = value == nil ? "text" : "json"
            summary = object?["description"] as? String ?? object?["query"] as? String ?? ""
        }
    }

    func displaySummary(in directory: String) -> String {
        if isOrchestration, requests.count == 1 { return ToolPresentation(requests[0]).displaySummary(in: directory) }
        let directory = self.directory ?? directory
        if let native { return native.summary(in: directory) }
        if let summaryReadCommand { return summaryReadCommand.summary(in: directory) }
        if commandPresentation != nil { return ToolCommandPresentation.parse(labelCommand ?? input, directory: directory)?.summary ?? summary }
        if !summaryDocuments.isEmpty {
            return summaryDocuments.map { title == "Read" || isPatch ? $0.stepLabel(in: directory) : $0.displayPath(in: directory) }.joined(separator: ", ")
        }
        return summary
    }

    var usesRawDetails: Bool { readCommand != nil || commandPresentation != nil }
    var displayTitle: String {
        !completed && !failed ? commandPresentation?.runningTitle ?? title : title
    }

    var sourceReadPreview: ToolReadCommand? {
        // Diagnostics, mixed content and transport truncation are not reliable
        // numbered source. Keep their normal output presentation and raw details.
        guard let readCommand, !failed, outputBlocks.count == 1,
              case .code = outputBlocks[0].kind,
              !output.hasPrefix("Warning: truncated output"),
              !output.contains(" tokens truncated") else { return nil }
        return readCommand
    }

    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
    static func command(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let args = value as? [String], !args.isEmpty else { return nil }
        // Only unwrap the exact shell -c / -lc form. Preserve argv otherwise,
        // including empty arguments, embedded quotes, and shell metacharacters.
        if args.count == 3, ["sh", "bash", "zsh", "dash", "fish"].contains((args[0] as NSString).lastPathComponent),
           ["-c", "-lc"].contains(args[1]) { return args[2] }
        return args.map { argument in
            if !argument.isEmpty && argument.range(of: #"^[a-zA-Z0-9_./:@%+=,-]+$"#, options: .regularExpression) != nil { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    static func result(_ raw: String, depth: Int = 0) -> (text: String, code: Int?) {
        let result = ToolOutput.decode(raw, depth: depth)
        return (result.text, result.code)
    }
}

/// Built-in structured tools use the same cards as shell/Codex operations.
/// Only known fields become previews; the original payload stays in Tool details.
private struct NativeToolPresentation: Sendable {
    let title: String
    let symbol: String
    var input = ""
    var language = "text"
    var documents: [ToolDocument] = []
    private var detail = ""
    private var path: String?
    private var scope = false
    private var suffix = ""

    init?(_ item: ChatItem, object: [String: Any]?) {
        guard let object else { return nil }
        func text(_ key: String) -> String { object[key] as? String ?? "" }
        switch item.title {
        case "Edit", "MultiEdit", "Write":
            documents = ToolDocument.parse(item)
            guard !documents.isEmpty else { return nil }
            title = "Patch"; symbol = "pencil.line"; path = documents[0].path
            if object["replace_all"] as? Bool == true { suffix = "replace all" }
        case "Read":
            guard !text("file_path").isEmpty else { return nil }
            title = "Read"; symbol = "doc.text"; path = text("file_path")
            let start = object["offset"] as? Int ?? 1
            if let count = object["limit"] as? Int, start > 0, count > 0, count <= Int.max - start {
                suffix = count == 1 ? "line \(start)" : "lines \(start)–\(start + count - 1)"
            } else if object["offset"] != nil { suffix = "from line \(start)" }
            if !text("pages").isEmpty { suffix = "pages " + text("pages") }
        case "Grep", "Glob":
            guard let pattern = object["pattern"] as? String else { return nil }
            title = item.title == "Grep" ? "Search" : "Find files"; symbol = "magnifyingglass"
            detail = pattern; input = pattern; path = object["path"] as? String; scope = true
            suffix = [text("glob"), text("type")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "WebSearch":
            guard let query = object["query"] as? String else { return nil }
            title = "Search web"; symbol = "magnifyingglass"; detail = query; input = query
        case "WebFetch":
            guard let url = object["url"] as? String else { return nil }
            title = "Open page"; symbol = "globe"; detail = url; input = text("prompt")
        case "Agent", "Task":
            guard let prompt = object["prompt"] as? String else { return nil }
            title = "Agent"; symbol = "person.2"; detail = text("description"); input = prompt
        case "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop":
            let titles = ["TaskCreate": "Create task", "TaskUpdate": "Update task", "TaskGet": "Read task",
                          "TaskList": "List tasks", "TaskOutput": "Task output", "TaskStop": "Stop task"]
            title = titles[item.title]!; symbol = item.title == "TaskStop" ? "stop.circle" : "checklist"
            detail = [text("subject"), text("taskId"), text("task_id"), text("status")].filter { !$0.isEmpty }.joined(separator: " · ")
            input = text("description")
        case "TodoWrite":
            guard let todos = object["todos"] as? [[String: Any]],
                  todos.allSatisfy({ $0["content"] is String && $0["status"] is String }) else { return nil }
            title = "Tasks"; symbol = "checklist"; detail = "\(todos.count) \(todos.count == 1 ? "task" : "tasks")"
            input = todos.map { "[\($0["status"] as! String)] \($0["content"] as! String)" }.joined(separator: "\n")
        case "Skill":
            guard let skill = object["skill"] as? String else { return nil }
            title = "Skill"; symbol = "book"; detail = skill; input = text("args")
        case "EnterPlanMode", "ExitPlanMode":
            title = item.title == "EnterPlanMode" ? "Enter plan mode" : "Review plan"; symbol = "list.bullet"
            input = text("plan"); language = item.title == "ExitPlanMode" ? "markdown" : "text"
        case "AskUserQuestion":
            guard let questions = object["questions"] as? [[String: Any]],
                  questions.allSatisfy({ $0["question"] is String }) else { return nil }
            title = "Questions"; symbol = "questionmark.bubble"
            detail = questions.compactMap { $0["header"] as? String }.joined(separator: ", ")
            input = questions.map { question in
                ([question["question"] as! String] + (question["options"] as? [[String: Any]] ?? []).compactMap { option in
                    guard let label = option["label"] as? String else { return nil }
                    return "• " + label + ((option["description"] as? String).map { " — " + $0 } ?? "")
                }).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case "NotebookEdit":
            guard let notebook = object["notebook_path"] as? String, let source = object["new_source"] as? String else { return nil }
            title = "Edit notebook"; symbol = "pencil.line"; path = notebook; input = source
            suffix = [text("cell_id").isEmpty ? "" : "cell " + text("cell_id"), text("edit_mode")].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return nil
        }
    }

    func summary(in directory: String) -> String {
        let file = path.map { path in
            let document = ToolDocument(path: path, diff: "")
            return scope ? "in " + document.displayPath(in: directory) : document.stepLabel(in: directory)
        } ?? ""
        return [detail, file, suffix].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Web calls can batch several actions. Summaries use their arguments only;
/// source identifiers remain in the full input instead of masquerading as URLs.
struct WebToolPresentation {
    let title: String
    let symbol: String
    let summary: String
    let isSearchOnly: Bool

    static func matches(_ name: String) -> Bool {
        if ["WebSearch", "WebFetch"].contains(name) { return true }
        let name = name.lowercased()
        return name == "web.run" || name == "web__run" || name.hasSuffix(".web__run")
    }

    init(_ object: [String: Any]?) {
        var actions: [(title: String, detail: String, search: Bool)] = []
        func value(_ row: [String: Any], _ key: String) -> String {
            if let string = row[key] as? String { return string }
            if let number = row[key] as? NSNumber { return number.stringValue }
            return ""
        }
        func page(_ row: [String: Any]) -> String {
            let reference = value(row, "ref_id")
            guard let url = URL(string: reference), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return "Search result" }
            return reference
        }
        let kinds = ["search_query", "image_query", "open", "find", "click", "screenshot", "weather", "finance", "sports", "time"]
        for kind in kinds {
            for row in object?[kind] as? [[String: Any]] ?? [] {
                let title: String, detail: String
                switch kind {
                case "search_query", "image_query":
                    title = kind == "search_query" ? "Search web" : "Search images"
                    detail = value(row, "q")
                case "open":
                    title = "Open page"
                    detail = page(row) + (row["lineno"] != nil ? " · line " + value(row, "lineno") : "")
                case "find":
                    title = "Find on page"
                    detail = "“" + value(row, "pattern") + "” · " + page(row)
                case "click":
                    title = "Follow link"
                    detail = page(row) + (row["id"] != nil ? " · link " + value(row, "id") : "")
                case "screenshot":
                    title = "View screenshot"
                    detail = page(row) + ((row["pageno"] as? Int).map { " · page \($0 + 1)" } ?? "")
                case "weather": title = "Check weather"; detail = value(row, "location")
                case "finance": title = "Look up prices"; detail = value(row, "ticker")
                case "sports":
                    title = "Look up sports"
                    detail = [value(row, "league").uppercased(), value(row, "team"), value(row, "fn")].filter { !$0.isEmpty }.joined(separator: " · ")
                default: title = "Check time"; detail = "UTC" + value(row, "utc_offset")
                }
                actions.append((title, detail, kind == "search_query" || kind == "image_query"))
            }
        }
        isSearchOnly = !actions.isEmpty && actions.allSatisfy(\.search)
        let sameKind = Set(actions.map(\.title)).count == 1
        title = sameKind ? actions[0].title : "Web"
        symbol = isSearchOnly ? "magnifyingglass" : "globe"
        let descriptions = actions.prefix(3).map { action in
            let detail = action.detail.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return sameKind ? detail : action.title + (detail.isEmpty ? "" : ": " + detail)
        }
        summary = actions.isEmpty ? "Web request" : descriptions.joined(separator: " · ") + (actions.count > 3 ? " · +\(actions.count - 3) more" : "")
    }
}
