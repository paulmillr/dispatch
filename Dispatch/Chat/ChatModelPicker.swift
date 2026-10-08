import Foundation
import Observation

@MainActor @Observable
final class ChatModelPicker: Identifiable {
    let id: UUID
    enum Column { case model, effort }
    var column: Column
    var models: [AgentModelMenu.Choice] = []
    var efforts: [AgentModelMenu.Choice] = []
    var selectedModel: String
    var highlightedModel: String
    var highlightedEffort = ""
    var loading = false
    var error: String?
    var presented = true
    var scope: [AgentModelMenu.Choice] = []
    var highlightedScope = ""
    var scopeTitle = "Apply reasoning change"
    var scopeDetail: String?
    private var currentModel: String
    private var currentEffort: String?
    @ObservationIgnored private let screen: () -> String
    @ObservationIgnored private let send: (AgentMenuKey?) async throws -> Void
    @ObservationIgnored private let confirmed: (String, String?) -> Void
    @ObservationIgnored private let finished: (Bool) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var advanced: Set<String> = []
    @ObservationIgnored private var pendingEffort: String?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var quickModels: Set<String> = []
    @ObservationIgnored private var appliedScope = false
    @ObservationIgnored private let cache: ChatModelChoicesCache
    @ObservationIgnored private var touchedMenu = false
    @ObservationIgnored private var liveEffortModel: String?
    /// Claude's effort ring in its →-key order; the displayed list is sorted.
    @ObservationIgnored private var claudeEffortRing: [String] = []
    @ObservationIgnored private var previousSelection: AgentModelMenu.Selection?
    @ObservationIgnored private let currentModelID: String
    @ObservationIgnored private let claude: Bool
    /// Agents with a structured settings API (Pi's extension, Nanocodex's
    /// control socket) supply their catalog directly instead of a TUI menu.
    struct StructuredModel: Equatable, Sendable {
        let key: String
        let name: String
        let efforts: [String]
    }
    struct StructuredSelection: Equatable, Sendable {
        let model: String?
        let effort: String?
    }
    struct StructuredOperations {
        let agent: String
        let choices: () async throws -> (StructuredSelection, [StructuredModel])
        let configure: (StructuredModel, String) async throws -> StructuredSelection
    }
    @ObservationIgnored private let structured: StructuredOperations?
    @ObservationIgnored private var structuredModels: [StructuredModel] = []
    @ObservationIgnored private var helper: HelperChat?
    @ObservationIgnored private var interaction: HelperChat.Interaction?
    @ObservationIgnored private var answerTask: Task<Void, Never>?

    init(id: UUID = UUID(), agentID: String = "codex", model: String, effort: String?, column: Column, cache: ChatModelChoicesCache = ChatModelChoicesCache(), screen: @escaping () -> String,
         send: @escaping (AgentMenuKey?) async throws -> Void,
         confirmed: @escaping (String, String?) -> Void, finished: @escaping (Bool) -> Void, structured: StructuredOperations? = nil) {
        self.id = id
        currentModelID = model
        claude = agentID == "claude"
        self.structured = structured
        self.cache = cache
        currentModel = model; currentEffort = effort; selectedModel = model; highlightedModel = model
        self.column = column; self.screen = screen; self.send = send; self.confirmed = confirmed; self.finished = finished
    }

    func start(cycle: Bool = false) {
        if structured != nil { loadStructuredChoices(cycle: cycle); return }
        guard let name = cache.menuName(for: currentModel) else {
            if helper != nil { loadHelper(cycle: cycle) } else { loadLiveChoices(cycle: cycle) }
            return
        }
        currentModel = name; selectedModel = name; highlightedModel = name
        if !cycle, let catalog = cache.catalog {
            models = marked(catalog.models) { $0.name == currentModel }
            quickModels = catalog.quickModels
            highlightedModel = models.first(where: { $0.name == currentModel })?.name ?? models.first?.name ?? ""
            if let choices = cache.efforts(for: currentModel) { showEfforts(choices, for: currentModel) }
            else if column == .effort { showColumn(.effort) }
            return
        }
        if helper != nil { loadHelper(cycle: cycle) } else { loadLiveChoices(cycle: cycle) }
    }

    convenience init(model: String, effort: String?, column: Column, cache: ChatModelChoicesCache, helper: HelperChat,
                     confirmed: @escaping (String, String?) -> Void, finished: @escaping (Bool) -> Void) {
        self.init(agentID: "", model: model, effort: effort, column: column, cache: cache,
                  screen: { "" }, send: { _ in }, confirmed: confirmed, finished: finished)
        self.helper = helper
    }

    private func helperChoices(_ menu: HelperChat.Menu) -> [AgentModelMenu.Choice] {
        menu.choices.enumerated().map { index, choice in
            .init(number: index + 1, name: choice.id, detail: choice.detail ?? "",
                         current: choice.id == menu.current, isDefault: choice.id == menu.default, effortValue: choice.id)
        }
    }

    private func loadHelper(cycle: Bool) {
        run {
            guard let helper = self.helper else { return }
            let menu: HelperChat.Menu = try await helper.call("chat.models", input: .init(helper.route))
            self.models = self.helperChoices(menu)
            self.cache.store(models: self.models, quickModels: [])
            if let current = menu.current { self.cache.rememberAlias(self.currentModel, menuName: current) }
            self.currentModel = menu.current ?? self.currentModel
            self.selectedModel = self.currentModel
            self.highlightedModel = self.models.first(where: \.current)?.name ?? self.models.first?.name ?? ""
            if self.column == .effort || cycle {
                try await self.loadHelperEfforts(self.currentModel)
                if cycle, !self.efforts.isEmpty {
                    let index = self.efforts.firstIndex(where: \.current) ?? -1
                    let next = self.efforts[(index + 1) % self.efforts.count]
                    try await self.selectHelper(self.currentModel, effort: next.name)
                }
            }
        }
    }

    private func loadHelperEfforts(_ model: String) async throws {
        guard let helper else { return }
        var input = HelperChat.Input(helper.route)
        input.model = model
        let menu: HelperChat.Menu = try await helper.call("chat.settings", input: input)
        selectedModel = model
        highlightedModel = model
        efforts = helperChoices(menu)
        cache.store(efforts: efforts, for: model)
        highlightedEffort = efforts.first(where: \.current)?.name ?? efforts.first?.name ?? ""
        if efforts.isEmpty { try await selectHelper(model, effort: nil) }
    }

    private func selectHelper(_ model: String, effort: String?) async throws {
        guard let helper else { return }
        var input = HelperChat.Input(helper.route)
        input.model = model
        input.effort = effort
        let sent: HelperChat.Sent = try await helper.call("chat.settings.set", input: input)
        try sent.confirmed()
        try Task.checkCancellation()
        // Completing the native dialog can also mean declining the requested change.
        struct Observed: Decodable, Sendable { let state: HelperChat.State }
        let observed: Observed = try await helper.call("chat.state", input: .init(helper.route))
        try Task.checkCancellation()
        if let reported = observed.state.model {
            if reported != currentModelID || model == currentModel {
                cache.rememberAlias(reported, menuName: model)
            }
            currentModel = reported
            currentEffort = observed.state.effort
            confirmed(reported, currentEffort)
        }
        presented = false
        finished(false)
    }

    func ask(_ value: HelperChat.Interaction) -> Bool {
        guard helper != nil, presented, task != nil, value.questions.count == 1,
              let question = value.questions.first, !question.multiple, !question.custom else { return false }
        interaction = value
        scopeTitle = question.header
        scopeDetail = question.text
        scope = helperChoices(.init(choices: question.options, current: nil))
        highlightedScope = scope.first?.name ?? ""
        loading = false
        return true
    }

    func clearAsk(_ id: String) {
        guard interaction?.id == id else { return }
        interaction = nil
        scope = []
    }

    private func answerHelper(_ choice: AgentModelMenu.Choice) {
        guard let helper, let interaction, let question = interaction.questions.first,
              let index = question.options.firstIndex(where: { $0.id == choice.name }), answerTask == nil else { return }
        answerTask = Task {
            defer { answerTask = nil }
            do {
                var input = HelperChat.Input(helper.route)
                input.interaction = interaction.id
                input.answers = [question.id: .options([index])]
                let sent: HelperChat.Sent = try await helper.call("interactions.answer", input: input)
                try sent.confirmed()
                try Task.checkCancellation()
                clearAsk(interaction.id)
                loading = true
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func loadLiveChoices(cycle: Bool) {
        run {
            if self.claude { try await self.loadClaudeChoices(cycle: cycle); return }
            // A cycle is a mutation: read the actual current setting even if
            // the transcript/footer still carries an older configuration.
            if self.touchedMenu { try await self.dismissMenus() }
            self.previousSelection = AgentModelMenu.selection(self.screen())
            self.touchedMenu = true
            try await self.send(nil) // /model through the verified text transport.
            self.quickModels = []
            var menu = try await self.waitMenu("opening the model list") { $0.kind.isModelList }
            var quick: [AgentModelMenu.Choice] = []
            if let all = menu.choices.first(where: { $0.name == "All models" }) {
                quick = try await self.collect(menu).filter { $0.name != "All models" }
                self.quickModels = Set(quick.map(\.name))
                try await self.activate(all, in: menu.kind)
                menu = try await self.waitMenu("opening all models") { $0.kind == .models && !$0.choices.contains(where: { $0.name == "All models" }) }
            } else if menu.kind == .quickModels {
                self.quickModels = Set(menu.choices.map(\.name))
            }
            let expanded = try await self.collect(menu)
            self.models = quick + expanded.filter { !self.quickModels.contains($0.name) || quick.isEmpty }
            self.cache.store(models: self.models, quickModels: self.quickModels)
            if let current = self.models.first(where: \.current) {
                self.cache.rememberAlias(self.currentModel, menuName: current.name)
                self.currentModel = current.name
                self.selectedModel = current.name
            }
            self.highlightedModel = self.models.first(where: { $0.name == self.currentModel })?.name ?? self.models[0].name
            if self.models.contains(where: { $0.name == self.currentModel }),
               self.column == .effort || cycle {
                try await self.loadEfforts(self.currentModel, allowImmediateSelection: !cycle)
                if cycle { try await self.cycleLoadedEffort() }
            } else if cycle || self.column == .effort {
                self.error = "The current model is not in the agent’s picker. Choose a listed model first."
            }
        }
    }

    /// Rows name the model as the footer does (opus-5.5, sol-6.1): Claude's rows name aliases ("Opus"), so theirs
    /// comes from the detail ("Opus 5.5 · …"); other rows name the model ID.
    func displayName(_ choice: AgentModelMenu.Choice) -> String {
        ChatModelControls.label(for: ClaudeModelMenu.modelID(detail: choice.detail) ?? choice.name)
    }

    func selectModel(_ name: String) {
        guard !loading, presented, models.contains(where: { $0.name == name }) else { return }
        if let choices = cache.efforts(for: name) {
            showEfforts(choices, for: name); column = .effort
            return
        }
        if helper != nil {
            run { try await self.loadHelperEfforts(name); self.column = .effort }
            return
        }
        if structured != nil {
            showStructuredEfforts(name); column = .effort
            return
        }
        run { try await self.loadEfforts(name); self.column = .effort }
    }

    func showColumn(_ column: Column) {
        self.column = column
        if column == .effort, efforts.isEmpty, models.contains(where: { $0.name == selectedModel }) {
            selectModel(selectedModel)
        }
    }

    func selectEffort(_ choice: AgentModelMenu.Choice) {
        run {
            if self.helper != nil { try await self.selectHelper(self.selectedModel, effort: choice.name) }
            else if self.structured != nil { try await self.applyStructuredEffort(choice) }
            else { try await self.applyEffort(choice) }
        }
    }

    func selectScope(_ choice: AgentModelMenu.Choice) {
        if helper != nil { answerHelper(choice); return }
        run {
            if self.claude { try await self.confirmClaudeSwitch(choice); return }
            try await self.activate(choice, in: .scope)
            _ = try await self.waitScreen { AgentModelMenu($0)?.kind != .scope }
            self.appliedScope = true
            try await self.confirmSelection()
        }
    }

    func move(_ delta: Int) {
        let rows = !scope.isEmpty ? scope : column == .model ? models : efforts
        guard !loading, !rows.isEmpty else { return }
        let name = !scope.isEmpty ? highlightedScope : column == .model ? highlightedModel : highlightedEffort
        let index = rows.firstIndex(where: { $0.name == name }) ?? 0
        let next = rows[(index + delta + rows.count) % rows.count].name
        if !scope.isEmpty { highlightedScope = next }
        else if column == .model { highlightedModel = next } else { highlightedEffort = next }
    }

    func chooseHighlighted() {
        if !scope.isEmpty, let choice = scope.first(where: { $0.name == highlightedScope }) { selectScope(choice) }
        else if column == .model { selectModel(highlightedModel) }
        else if let choice = efforts.first(where: { $0.name == highlightedEffort }) { selectEffort(choice) }
    }

    func cycleEffort() {
        if helper != nil { loadHelper(cycle: true) }
        else if structured != nil { loadStructuredChoices(cycle: true) }
        else { loadLiveChoices(cycle: true) }
    }

    private func loadStructuredChoices(cycle: Bool) {
        guard let structured else { return }
        run {
            let (selection, catalog) = try await structured.choices()
            guard let current = selection.model, !catalog.isEmpty else { throw HerdrFailure("\(structured.agent) has no available model choices.") }
            self.currentModel = current; self.currentEffort = selection.effort
            self.structuredModels = catalog
            self.models = catalog.enumerated().map { index, model in
                .init(number: index + 1, name: model.key, detail: model.name, current: model.key == self.currentModel, isDefault: false)
            }
            self.showStructuredEfforts(self.currentModel)
            if cycle {
                guard !self.efforts.isEmpty else { return }
                let index = self.efforts.firstIndex(where: \.current) ?? -1
                try await self.applyStructuredEffort(self.efforts[(index + 1) % self.efforts.count])
            }
        }
    }

    private func showStructuredEfforts(_ name: String) {
        guard let model = structuredModels.first(where: { $0.key == name }) else { return }
        let choices = model.efforts.enumerated().map { index, level in
            AgentModelMenu.Choice(number: index + 1, name: level.capitalized, detail: "", current: false, isDefault: false, effortValue: level)
        }
        showEfforts(choices, for: name)
    }

    private func applyStructuredEffort(_ choice: AgentModelMenu.Choice) async throws {
        guard let structured, let effort = choice.effort,
              let model = structuredModels.first(where: { $0.key == selectedModel }),
              model.efforts.contains(effort) else { throw HerdrFailure("\(structured?.agent ?? "The agent") no longer offers this thinking level.") }
        let selection = try await structured.configure(model, effort)
        guard selection.model == model.key, selection.effort == effort else {
            throw HerdrFailure("\(structured.agent) did not confirm the selected model and thinking level. Check Terminal before trying again.")
        }
        currentModel = selectedModel; currentEffort = effort
        confirmed(selectedModel, effort); presented = false; finished(false)
    }

    func abandon() {
        task?.cancel()
        task = nil
        answerTask?.cancel()
        answerTask = nil
        presented = false
    }

    func close() {
        guard !closing, presented else { return }
        if helper != nil {
            let interrupted = loading || interaction != nil
            closing = true
            abandon()
            finished(interrupted)
            return
        }
        closing = true
        presented = false
        let interruptedNavigation = loading
        task?.cancel()
        // Opening and dismissing cached choices must not touch the terminal,
        // even if another native menu happens to be showing there.
        guard touchedMenu else { finished(interruptedNavigation); return }
        let previous = task
        task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Escape only recognized menus; never type into an ordinary prompt.
            try? await dismissMenus()
            // A cancelled transport can still be delivering its last key.
            // Expose the terminal until that uncertain transition is resolved.
            finished(interruptedNavigation || error != nil || AgentModelMenu(screen()) != nil || (claude && (ClaudeModelMenu(screen()) != nil || ClaudeModelConfirmation(screen()) != nil)))
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !loading, presented else { return }
        loading = true; error = nil
        task = Task { [weak self] in
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { }
            catch { self?.cache.invalidate(); self?.error = error.localizedDescription }
            self?.loading = false
            if self?.closing != true { self?.task = nil }
        }
    }

    private func dismissMenus() async throws {
        if claude {
            for _ in 0..<3 {
                let confirmation = ClaudeModelConfirmation(screen())
                guard ClaudeModelMenu(screen()) != nil || confirmation != nil else { return }
                try await send(.escape)
                _ = try await waitScreen { confirmation == nil ? ClaudeModelMenu($0) == nil : ClaudeModelConfirmation($0) == nil }
            }
            throw HerdrFailure("Claude's menu did not close. Open the terminal to continue.")
        }
        for _ in 0..<4 {
            guard let menu = AgentModelMenu(screen()) else { return }
            try await send(.escape)
            _ = try await waitScreen("closing the current menu") { AgentModelMenu($0)?.kind != menu.kind }
        }
        throw HerdrFailure("The agent menu did not close. Open the terminal to continue.")
    }

    private func marked(_ choices: [AgentModelMenu.Choice], current: (AgentModelMenu.Choice) -> Bool) -> [AgentModelMenu.Choice] {
        choices.map { .init(number: $0.number, name: $0.name, detail: $0.detail, current: current($0), isDefault: $0.isDefault, effortValue: $0.effortValue) }
    }

    private func showEfforts(_ choices: [AgentModelMenu.Choice], for model: String) {
        selectedModel = model; highlightedModel = model; scope = []; pendingEffort = nil; appliedScope = false
        efforts = marked(choices) { model == currentModel && $0.effort == currentEffort }
        highlightedEffort = efforts.first(where: \.current)?.name
            ?? efforts.first(where: \.isDefault)?.name ?? efforts.first?.name ?? ""
    }

    /// Agents redraw a menu within a few milliseconds of a key, and reading the
    /// screen is a local copy, so polling must not dominate each step's latency.
    private static let poll = Duration.milliseconds(8)

    private func waitScreen(_ change: String = "menu change", _ accepts: (String) -> Bool) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let text = screen()
            if accepts(text) { return text }
            try await Task.sleep(for: Self.poll)
        }
        throw HerdrFailure("The agent has not confirmed the \(change). Open the terminal to continue.")
    }

    private func waitMenu(_ change: String = "menu change", _ accepts: (AgentModelMenu) -> Bool) async throws -> AgentModelMenu {
        var previous: AgentModelMenu?
        let text = try await waitScreen(change) {
            let menu = AgentModelMenu($0)
            defer { previous = menu }
            // A tmux capture/resize can briefly expose a partially updated menu.
            // Wait for two matching reads before choosing the next key.
            return menu != nil && menu == previous && menu.map(accepts) == true
        }
        guard let menu = AgentModelMenu(text) else { throw HerdrFailure("The agent menu changed.") }
        return menu
    }

    private func collect(_ initial: AgentModelMenu) async throws -> [AgentModelMenu.Choice] {
        var rows = initial.choices, menu = initial
        // A catalog with one model cannot move its highlight. Waiting for
        // movement would incorrectly time out a valid custom-provider menu.
        if rows.count == 1 { return rows }
        // A wrap reveals the last row number. Stop once all numbered rows are
        // known, including choices that were initially offscreen.
        var count: Int?
        for _ in 0..<100 {
            let previous = menu.choices.first { $0.name == menu.selected }?.number
            try await send(.down)
            menu = try await waitMenu { $0.kind == initial.kind && $0.selected != menu.selected }
            for row in menu.choices where !rows.contains(where: { $0.name == row.name }) { rows.append(row) }
            if let previous, let selected = menu.choices.first(where: { $0.name == menu.selected })?.number, selected < previous {
                count = rows.map(\.number).max()
            }
            if let count, Set(rows.map(\.number)) == Set(1...count) { return rows.sorted { $0.number < $1.number } }
            if menu.selected == initial.selected { return rows.sorted { $0.number < $1.number } }
        }
        throw HerdrFailure("The agent model list is too large to navigate here. Open it in terminal.")
    }

    private func activate(_ choice: AgentModelMenu.Choice, in kind: AgentModelMenu.Kind) async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard let menu = AgentModelMenu(screen()), menu.kind == kind else { throw HerdrFailure("The agent menu changed. Open the terminal to continue.") }
            if menu.selected == choice.name {
                try await send(.enter)
                return
            }
            let number = menu.choices.first(where: { $0.name == menu.selected })?.number ?? 0
            let target = menu.choices.first(where: { $0.name == choice.name })?.number ?? choice.number
            try await send(number < target ? .down : .up)
            _ = try await waitMenu("move from \(menu.selected) toward \(choice.name)") { $0.kind == kind && $0.selected != menu.selected }
        }
        throw HerdrFailure("The selected agent option is no longer available.")
    }

    private func loadEfforts(_ model: String, allowImmediateSelection: Bool = true) async throws {
        if claude { try await loadClaudeEfforts(model); return }
        guard let choice = models.first(where: { $0.name == model }) else { throw HerdrFailure("Choose a model from the agent’s list.") }
        if !touchedMenu {
            previousSelection = AgentModelMenu.selection(screen())
            touchedMenu = true
            try await send(nil)
            _ = try await waitMenu("opening the model list") { $0.kind.isModelList }
        }
        liveEffortModel = nil
        for _ in 0..<3 {
            guard let menu = AgentModelMenu(screen()) else { throw HerdrFailure("The agent menu closed. Open the picker again.") }
            if menu.kind.isModelList { break }
            try await send(.escape)
            _ = try await waitScreen("closing the current menu") { AgentModelMenu($0)?.kind != menu.kind }
        }
        var kind: AgentModelMenu.Kind = quickModels.contains(model) ? .quickModels : .models
        if let menu = AgentModelMenu(screen()), menu.kind != kind {
            if kind == .quickModels {
                try await send(.escape)
                _ = try await waitScreen("closing the model list") { AgentModelMenu($0) == nil }
                // Returning from Codex's full list dismisses its root menu.
                // Reopen only after that dismissal, for this explicit selection.
                try await send(nil)
                _ = try await waitMenu("reopening quick models") { $0.kind == .quickModels }
            } else if let all = menu.choices.first(where: { $0.name == "All models" }) {
                try await activate(all, in: menu.kind)
                _ = try await waitMenu("opening all models") { $0.kind == .models }
            } else { kind = menu.kind }
        }
        selectedModel = model; highlightedModel = model; scope = []; pendingEffort = nil; appliedScope = false
        try await activate(choice, in: kind)
        // A resize can briefly hide the menu while an earlier confirmation
        // remains on screen. Cached effort selection must await its live menu.
        let text = try await waitScreen("opening reasoning choices") {
            AgentModelMenu($0)?.kind == .effort(model)
                || AgentModelMenu($0)?.kind == .scope
                || (allowImmediateSelection && AgentModelMenu($0) == nil && self.reportedSelection(in: $0) != nil)
        }
        guard let menu = AgentModelMenu(text), menu.kind == .effort(model) else {
            // Models with one fixed effort confirm immediately in Codex.
            guard allowImmediateSelection else { throw HerdrFailure("The agent’s effort choices changed. Open the terminal to check its selection.") }
            try await confirmSelection(); return
        }
        efforts = menu.choices.filter { $0.effort != nil }; advanced = []
        if let more = menu.choices.first(where: { $0.name.hasPrefix("More reasoning") }) {
            try await activate(more, in: menu.kind)
            let extra = try await waitMenu("opening advanced reasoning choices") { $0.kind == .advanced }
            efforts += extra.choices.filter { $0.effort != nil }
            advanced = Set(extra.choices.map(\.name))
            try await send(.escape)
            _ = try await waitMenu("returning to reasoning choices") { $0.kind == menu.kind }
        }
        if model == currentModel, let current = efforts.first(where: \.current)?.effort { currentEffort = current }
        cache.store(efforts: efforts, for: model)
        liveEffortModel = model
        highlightedEffort = efforts.first(where: { model == currentModel && $0.effort == currentEffort })?.name
            ?? efforts.first(where: \.current)?.name ?? efforts.first(where: \.isDefault)?.name ?? efforts.first?.name ?? ""
    }

    private func cycleLoadedEffort() async throws {
        guard !efforts.isEmpty else { throw HerdrFailure("Choose a model first.") }
        let count = efforts.count
        let index: Int? = efforts.firstIndex(where: { $0.effort == currentEffort })
        // Claude's list is sorted strongest first; cycling still steps up.
        let next: Int = claude ? ((index ?? 0) + count - 1) % count : ((index ?? -1) + 1) % count
        try await applyEffort(efforts[next])
    }

    private func applyEffort(_ choice: AgentModelMenu.Choice) async throws {
        if claude { try await applyClaudeEffort(choice); return }
        guard efforts.contains(where: { $0.name == choice.name && $0.effort == choice.effort }) else { throw HerdrFailure("This effort is no longer available.") }
        if liveEffortModel != selectedModel || AgentModelMenu(screen())?.kind != .effort(selectedModel) {
            try await loadEfforts(selectedModel, allowImmediateSelection: false)
        }
        guard let choice = efforts.first(where: { $0.name == choice.name && $0.effort == choice.effort }) else {
            throw HerdrFailure("This effort is no longer available. Reopen the picker to refresh its choices.")
        }
        var kind = AgentModelMenu.Kind.effort(selectedModel)
        if advanced.contains(choice.name) {
            guard let menu = AgentModelMenu(screen()), menu.kind == kind,
                  let more = menu.choices.first(where: { $0.name.hasPrefix("More reasoning") }) else { throw HerdrFailure("The agent menu changed.") }
            try await activate(more, in: kind)
            _ = try await waitMenu("opening advanced reasoning choices") { $0.kind == .advanced }; kind = .advanced
        }
        pendingEffort = choice.effort
        try await activate(choice, in: kind)
        try await confirmSelection()
    }

    private func confirmSelection() async throws {
        let text = try await waitScreen("applying the selection") { text in
            AgentModelMenu(text)?.kind == .scope || (AgentModelMenu(text) == nil && self.reportedSelection(in: text).map {
                self.pendingEffort == nil || $0.effort == self.pendingEffort
            } == true)
        }
        if let menu = AgentModelMenu(text), menu.kind == .scope { scope = menu.choices; highlightedScope = menu.selected; return }
        guard let reported = reportedSelection(in: text) else { throw HerdrFailure("The agent did not confirm the selection.") }
        cache.rememberAlias(reported.model, menuName: selectedModel)
        confirmed(reported.model, reported.effort)
        presented = false; finished(false)
    }

    private func reportedSelection(in text: String) -> AgentModelMenu.Selection? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let selection = AgentModelMenu.selection(text),
           pendingEffort == nil || selection.effort == pendingEffort,
           selection.model == selectedModel || cache.menuName(for: selection.model) == selectedModel ||
            (selection != previousSelection && lines.contains(where: {
                $0.hasPrefix("\(selectedModel) \(selection.effort ?? "default") ·")
            })) { return selection }
        // A Plan-only change updates the footer without a new history notice.
        // Keep the verified current model ID even when the footer uses its label.
        if appliedScope, selectedModel == currentModel, let pendingEffort, lines.contains(where: {
            $0.hasPrefix("\(selectedModel) \(pendingEffort) ·")
        }) { return .init(model: currentModelID, effort: pendingEffort) }
        return nil
    }

    private func claudeMenu(_ accepts: (ClaudeModelMenu) -> Bool = { _ in true }) async throws -> ClaudeModelMenu {
        var previous: ClaudeModelMenu?
        let text = try await waitScreen {
            let menu = ClaudeModelMenu($0)
            defer { previous = menu }
            return menu != nil && menu == previous && menu.map(accepts) == true
        }
        guard let menu = ClaudeModelMenu(text) else { throw HerdrFailure("Claude's menu changed. Open the terminal to continue.") }
        return menu
    }

    /// Arrow keys only change pending selection. At the end of a clamped list,
    /// wait for the unchanged menu instead of assuming it wraps around.
    private func claudeStep(_ key: AgentMenuKey, from before: ClaudeModelMenu) async throws -> ClaudeModelMenu {
        try await send(key)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var previous: ClaudeModelMenu?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let next = ClaudeModelMenu(screen())
            if let next, next != before, next == previous { return next }
            previous = next
            try await Task.sleep(for: Self.poll)
        }
        guard let previous, previous == before else { throw HerdrFailure("Claude has not confirmed its pending selection.") }
        return previous
    }

    private func openClaudeMenu() async throws -> ClaudeModelMenu {
        if !touchedMenu {
            touchedMenu = true
            try await send(nil)
        }
        return try await claudeMenu()
    }

    private func highlightClaudeModel(_ name: String) async throws -> ClaudeModelMenu {
        var menu = try await openClaudeMenu()
        guard let target = models.first(where: { $0.name == name }) else { throw HerdrFailure("Choose a model from Claude's list.") }
        for _ in 0..<100 {
            if menu.selected == name { return menu }
            guard let selected = menu.choices.first(where: { $0.name == menu.selected }) else { break }
            let targetNumber = menu.choices.first(where: { $0.name == name })?.number ?? target.number
            let down = selected.number < targetNumber
            let next = try await claudeStep(down ? .down : .up, from: menu)
            guard next.selected != menu.selected else { break }
            if next.selected != name, let number = next.choices.first(where: { $0.name == next.selected })?.number,
               down ? number <= selected.number : number >= selected.number { break }
            menu = next
        }
        throw HerdrFailure("This Claude model is no longer available. Reopen the picker.")
    }

    private func loadClaudeChoices(cycle: Bool) async throws {
        if touchedMenu { try await dismissMenus(); touchedMenu = false }
        scope = []; scopeDetail = nil; pendingEffort = nil
        var menu = try await openClaudeMenu()
        let original = menu
        var rows = menu.choices
        // Collect offscreen rows, supporting both wrapping and clamped lists.
        directions: for direction in [AgentMenuKey.down, .up] {
            var visited: Set<String> = [menu.selected]
            for _ in 0..<100 {
                if let count = menu.count, rows.count == count, Set(rows.map(\.number)) == Set(1...count) { break directions }
                let next = try await claudeStep(direction, from: menu)
                for row in next.choices where !rows.contains(where: { $0.name == row.name }) { rows.append(row) }
                let moved = next.selected != menu.selected
                menu = next
                if !visited.insert(menu.selected).inserted {
                    // A complete wrap already visited the entire list. Only a
                    // clamped endpoint needs a walk in the opposite direction.
                    if moved { break directions }
                    break
                }
                guard rows.count <= 100 else { throw HerdrFailure("Claude's model list is too large. Open it in terminal.") }
            }
        }
        models = rows.sorted { $0.number < $1.number }
        guard let current = models.first(where: \.current) else { throw HerdrFailure("Claude did not identify its current model.") }
        cache.store(models: models, quickModels: [])
        cache.rememberAlias(currentModel, menuName: current.name)
        currentModel = current.name; currentEffort = original.effort
        selectedModel = current.name; highlightedModel = current.name
        if column == .effort || cycle { try await loadClaudeEfforts(current.name) }
        if cycle { try await cycleLoadedEffort() }
    }

    private func loadClaudeEfforts(_ model: String) async throws {
        var menu = try await highlightClaudeModel(model)
        let original = menu.effort
        var values: [String] = menu.effort.map { [$0] } ?? []
        if menu.effort != nil {
            directions: for direction in [AgentMenuKey.left, .right] {
                var visited: Set<String> = menu.effort.map { [$0] } ?? []
                for _ in 0..<16 {
                    let next = try await claudeStep(direction, from: menu)
                    guard next.selected == model, let value = next.effort else { throw HerdrFailure("Claude's effort menu changed.") }
                    if !values.contains(value) {
                        if direction == .left { values.insert(value, at: 0) } else { values.append(value) }
                    }
                    let moved = next.effort != menu.effort
                    menu = next
                    if !visited.insert(value).inserted {
                        // A wrap has visited every level and is back at the
                        // original one; only a clamped end needs the other way.
                        if moved { break directions }
                        break
                    }
                }
            }
        }
        claudeEffortRing = values
        efforts = ClaudeModelMenu.sortedEfforts(values).enumerated().map { .init(number: $0.offset, name: $0.element.capitalized, detail: "", current: model == currentModel && $0.element == currentEffort, isDefault: false, effortValue: $0.element) }
        if efforts.isEmpty { efforts = [.init(number: 0, name: "Default", detail: "This model has no adjustable effort", current: true, isDefault: true)] }
        cache.store(efforts: efforts, for: model)
        selectedModel = model; highlightedModel = model; liveEffortModel = model
        if let original { _ = try await highlightClaudeEffort(original, from: menu) }
        highlightedEffort = efforts.first(where: \.current)?.name ?? efforts.first?.name ?? ""
    }

    private func highlightClaudeEffort(_ value: String, from initial: ClaudeModelMenu) async throws -> ClaudeModelMenu {
        var menu = initial
        guard let target = claudeEffortRing.firstIndex(of: value) else { throw HerdrFailure("This Claude effort is no longer available.") }
        for _ in 0..<16 {
            if menu.effort == value { return menu }
            guard let current = menu.effort.flatMap(claudeEffortRing.firstIndex(of:)) else { break }
            let next = try await claudeStep(current < target ? .right : .left, from: menu)
            guard next.selected == selectedModel, next.effort != menu.effort else { break }
            menu = next
        }
        throw HerdrFailure("Claude has not confirmed the selected effort.")
    }

    private func applyClaudeEffort(_ choice: AgentModelMenu.Choice) async throws {
        let model = selectedModel
        guard efforts.contains(where: { $0 == choice }) else { throw HerdrFailure("This effort is no longer available.") }
        if liveEffortModel != model { try await loadClaudeEfforts(model) }
        var menu = try await highlightClaudeModel(model)
        if let value = choice.effort { menu = try await highlightClaudeEffort(value, from: menu) }
        guard menu.selected == model, menu.effort == choice.effort else { throw HerdrFailure("Claude's pending selection changed.") }
        // 's' is explicitly the current-session action. Never change defaults.
        try await send(.thisSession)
        pendingEffort = choice.effort
        let response = try await waitScreen { ClaudeModelConfirmation($0) != nil || ClaudeModelMenu.isEmptyComposer($0) }
        if let confirmation = ClaudeModelConfirmation(response) {
            scope = confirmation.choices; highlightedScope = confirmation.selected
            scopeTitle = confirmation.title; scopeDetail = confirmation.detail
            return
        }
        try await verifyClaudeSelection()
    }

    private func confirmClaudeSwitch(_ choice: AgentModelMenu.Choice) async throws {
        guard scope.contains(choice), var confirmation = ClaudeModelConfirmation(screen()), confirmation.choices.contains(choice) else {
            throw HerdrFailure("Claude's confirmation changed. Open the terminal to continue.")
        }
        if confirmation.selected != choice.name {
            try await send(choice.number == 1 ? .up : .down)
            let text = try await waitScreen { ClaudeModelConfirmation($0)?.selected == choice.name }
            guard let current = ClaudeModelConfirmation(text) else { throw HerdrFailure("Claude's confirmation changed.") }
            confirmation = current
        }
        guard confirmation.selected == choice.name else { throw HerdrFailure("Claude did not select that answer.") }
        try await send(.enter)
        _ = try await waitScreen { ClaudeModelConfirmation($0) == nil && (ClaudeModelMenu($0) != nil || ClaudeModelMenu.isEmptyComposer($0)) }
        scope = []; scopeDetail = nil
        if choice.number == 2 {
            try await dismissMenus(); presented = false; finished(false)
        } else { try await verifyClaudeSelection() }
    }

    private func verifyClaudeSelection() async throws {
        touchedMenu = false
        let verified = try await openClaudeMenu()
        guard verified.choices.first(where: \.current)?.name == selectedModel, verified.effort == pendingEffort else {
            throw HerdrFailure("Claude did not confirm the change. Check the terminal before retrying.")
        }
        try await dismissMenus(); touchedMenu = false
        // Report the concrete model (claude-opus-5-5), not the menu alias ("Opus").
        let model = verified.choices.first(where: \.current).flatMap { ClaudeModelMenu.modelID(detail: $0.detail) } ?? selectedModel
        cache.rememberAlias(model, menuName: selectedModel)
        confirmed(model, pendingEffort)
        presented = false; finished(false)
    }
}
