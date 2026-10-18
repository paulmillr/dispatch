import Foundation
import Observation

/// What New chat (M9a) defaults to: the last agent used, and per agent the last model and effort with the menus seen
/// for it (choice metadata only; applying a choice still goes through the live conversation's `chat.settings.set`).
/// A new chat has no terminal yet, so no `chat.models` can be asked before it starts.
@MainActor @Observable final class ChatModelMemory {
    struct Choice: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String

        init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            label = values.lenient(String.self, forKey: .label, default: id)
        }
    }
    struct Agent: Codable, Equatable, Sendable {
        var model: String?
        var effort: String?
        var models: [Choice] = []
        var efforts: [String: [Choice]] = [:]

        init(model: String? = nil, effort: String? = nil, models: [Choice] = [], efforts: [String: [Choice]] = [:]) {
            self.model = model
            self.effort = effort
            self.models = models
            self.efforts = efforts
        }

        /// A missing or unreadable key takes its default; the rest of the file stays.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            model = values.lenient(String.self, forKey: .model)
            effort = values.lenient(String.self, forKey: .effort)
            models = values.lenientArray(Choice.self, forKey: .models)
            efforts = values.lenientDictionary([Lenient<Choice>].self, forKey: .efforts).mapValues { $0.compactMap(\.value) }
        }
    }
    struct Document: Codable, Equatable, Sendable {
        var version = 1
        var agent: String?
        var agents: [String: Agent] = [:]

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = values.lenient(Int.self, forKey: .version, default: 1)
            agent = values.lenient(String.self, forKey: .agent)
            agents = values.lenientDictionary(Agent.self, forKey: .agents)
        }
    }

    static let shared = ChatModelMemory(url: Home.support.appendingPathComponent("chat-models.json"))
    private(set) var document = Document()
    @ObservationIgnored private let url: URL?

    /// `url` nil keeps everything in memory (tests, previews).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data) {
            self.document = document
        }
    }

    var lastAgent: String? { document.agent }
    func agent(_ key: String) -> Agent { document.agents[key] ?? Agent() }

    /// A chat started or a model chosen.
    func remember(agent key: String, model: String?, effort: String?) {
        document.agent = key
        var agent = agent(key)
        if let model { agent.model = model; agent.effort = effort }
        document.agents[key] = agent
        save()
    }

    /// Menus a live conversation of this agent showed.
    func remember(agent key: String, models: [AgentModelMenu.Choice]? = nil, efforts: [AgentModelMenu.Choice]? = nil, for model: String? = nil) {
        var agent = agent(key)
        if let models { agent.models = models.map { Choice(id: $0.name, label: $0.detail.isEmpty ? $0.name : $0.detail) } }
        if let efforts, let model { agent.efforts[model] = efforts.map { Choice(id: $0.name, label: $0.detail.isEmpty ? $0.name : $0.detail) } }
        document.agents[key] = agent
        save()
    }

    /// Settings' Remove all data: forgets every choice and deletes the file.
    func removeAll() {
        document = Document()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(document) else { return }
        try? PrivateFile.write(data, to: url, excludedFromBackup: true)
    }
}
