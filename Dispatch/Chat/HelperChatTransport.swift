import Foundation

extension HelperChat {
    /// Notifications carry an address; each client keeps its own subscription and binding policy.
    enum Notification {
        case history(History)
        case archive(Page)
        case records(Records)
        case queue(Items)
        case state(Status)
        case interaction(Opened)
        case exit(UInt64)

        var address: Route? {
            switch self {
            case .history(let value): .init(terminal: value.terminal, session: value.session)
            case .records(let value): .init(terminal: value.terminal, session: value.session)
            case .queue(let value): .init(terminal: value.terminal, session: value.session)
            case .state(let value): .init(terminal: value.terminal, session: value.session)
            case .interaction(let value): .init(terminal: value.terminal, session: value.session)
            case .exit(let terminal): .init(terminal: terminal, session: nil)
            case .archive: nil
            }
        }

        /// A terminal exit has no conversation. Mobile also accepts the helper's unnamed session while binding.
        func matches(_ route: Route, allowingUnnamedSession: Bool = false) -> Bool {
            guard let address else { return true }
            guard address.terminal == route.terminal else { return false }
            return address.session == nil || route.session == nil || address.session == route.session
                || (allowingUnnamedSession && address.session == "")
        }

        /// Unknown methods are ignored; malformed known methods fail without manufacturing an event.
        static func decode(_ method: String, from value: HelperBinary.Value) throws -> Self? {
            switch method {
            case "chat.history": .history(try HelperBinary.decode(History.self, from: value))
            case "chat.archive": .archive(try HelperBinary.decode(Page.self, from: value))
            case "chat.records": .records(try HelperBinary.decode(Records.self, from: value))
            case "chat.queue": .queue(try HelperBinary.decode(Items.self, from: value))
            case "chat.state": .state(try HelperBinary.decode(Status.self, from: value))
            case "interaction.opened": .interaction(try HelperBinary.decode(Opened.self, from: value))
            case "terminal.exit": .exit(try HelperBinary.decode(HelperClient.Exit.self, from: value).terminal)
            default: nil
            }
        }
    }

    struct ObservedState: Decodable {
        let state: State
    }

    /// The helper menu's transport is shared; callers retain their connection and generation fences.
    @MainActor enum ModelTransport {
        enum Detail { case description, label }

        static func choices(_ menu: Menu, detail: Detail) -> [AgentModelMenu.Choice] {
            menu.choices.enumerated().map { index, choice in
                .init(number: index + 1, name: choice.id,
                      detail: detail == .label ? choice.label : choice.detail ?? "",
                      current: choice.id == menu.current, isDefault: choice.id == menu.default,
                      effortValue: detail == .description ? choice.id : nil)
            }
        }

        /// No model means the catalog; a model requests that row's effort menu.
        static func menu(route: Route, model: String? = nil,
                         request: (String, Input) async throws -> Menu) async throws -> Menu {
            var input = Input(route)
            input.model = model
            return try await request(model == nil ? "chat.models" : "chat.settings", input)
        }

        /// A delivered selection may have been declined. Only the agent's subsequent state confirms a choice.
        static func select(route: Route, model: String, effort: String?,
                           set: (Input) async throws -> Sent,
                           read: (Input) async throws -> ObservedState) async throws -> (model: String, effort: String?) {
            try Task.checkCancellation()
            var input = Input(route)
            input.model = model
            input.effort = effort
            try await set(input).confirmed()
            try Task.checkCancellation()
            let observed = try await read(Input(route))
            try Task.checkCancellation()
            guard let model = observed.state.model else {
                throw HelperFailure(code: "unconfirmed", message: "The agent did not report its model after the change. Check Terminal before trying again.")
            }
            return (model, observed.state.effort)
        }
    }
}

extension HelperChat.Interaction {
    enum Presentation {
        case closed
        case permission(ChatSidePermission)
        case toolQuestions
        case standalone
    }

    /// Tool forms stay inline; standalone multi-question forms keep their ordered answers.
    var presentation: Presentation {
        if questions.isEmpty { return .closed }
        if let permission { return .permission(permission) }
        if blocking, !approval, questions.allSatisfy({ $0.options.count >= 2 && !$0.secret }),
           questions.count == 1 || record != nil { return .toolQuestions }
        return .standalone
    }

    enum Response {
        case labels([String: String])
        /// A native form captured its answers in question order, preserving options versus custom text.
        case ordered([HelperChat.Answer])
        case option(Int)
        case skip
    }

    /// Answer keys are the helper's question ids, never display labels or array positions.
    func answerInput(route: HelperChat.Route, response: Response) -> HelperChat.Input? {
        var input = HelperChat.Input(route)
        input.interaction = id
        switch response {
        case .labels(let chosen): input.answers = answers(chosen)
        case .ordered(let responses):
            guard responses.count == questions.count else { return nil }
            for (question, response) in zip(questions, responses) {
                if case .options(let indices) = response {
                    guard !indices.isEmpty, question.multiple || indices.count == 1,
                          indices.allSatisfy({ question.options.indices.contains($0) }) else { return nil }
                }
            }
            input.answers = Dictionary(zip(questions.map(\.id), responses), uniquingKeysWith: { _, last in last })
        case .skip: input.answers = Dictionary(questions.map { ($0.id, .skip) }, uniquingKeysWith: { _, last in last })
        case .option(let index):
            guard let question = questions.first, question.options.indices.contains(index) else { return nil }
            input.answers = [question.id: .options([index])]
        }
        return input
    }
}


extension ClaudeQuestionDraft {
    struct ReplySnapshot {
        let displayAnswers: [String: String]
        let responses: [HelperChat.Answer]
    }

    /// Captured before delivery: display labels never have to be parsed back into option indices.
    var replySnapshot: ReplySnapshot? {
        let display = answers
        guard questionnaire.accepts(display) else { return nil }
        let responses: [HelperChat.Answer] = questionnaire.questions.map { question in
            if usingCustom.contains(question.id) { return .text(display[question.text] ?? "") }
            let indices = question.options.indices.filter {
                selected[question.id, default: []].contains(question.options[$0].label)
            }
            return .options(indices)
        }
        return .init(displayAnswers: display, responses: responses)
    }
}
