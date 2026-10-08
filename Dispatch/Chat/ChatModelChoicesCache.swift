import Foundation

/// Choice metadata only. Applying a cached choice still uses the verified live
/// menu transport; a cache entry never grants authority to send input.
@MainActor
final class ChatModelChoicesCache {
    nonisolated static let ttl: TimeInterval = 24 * 60 * 60
    struct Catalog {
        let models: [AgentModelMenu.Choice]
        let quickModels: Set<String>
    }
    private struct Entry<Value> {
        var value: Value
        let date: Date
        func fresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < ChatModelChoicesCache.ttl
        }
    }
    private struct Scope: Equatable {
        let agent: String
        let conversation: String?
        let process: AgentProcess?
        let version: String?
    }
    private var scope: Scope?
    private var catalogEntry: Entry<Catalog>?
    private var effortEntries: [String: Entry<[AgentModelMenu.Choice]>] = [:]
    private var aliases: [String: String] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    func prepare(for session: ChatSession) {
        let next = Scope(agent: session.agentID, conversation: session.sessionID, process: session.process,
                         version: session.version)
        if scope != next { invalidate(); scope = next }
    }

    var catalog: Catalog? {
        guard let entry = catalogEntry, entry.fresh(at: now()) else { invalidate(); return nil }
        return entry.value
    }

    func efforts(for model: String) -> [AgentModelMenu.Choice]? {
        guard catalog != nil, let entry = effortEntries[model], entry.fresh(at: now()) else {
            effortEntries[model] = nil; return nil
        }
        return entry.value
    }

    func store(models: [AgentModelMenu.Choice], quickModels: Set<String>) {
        catalogEntry = Entry(value: Catalog(models: models, quickModels: quickModels), date: now())
        effortEntries = effortEntries.filter { name, _ in models.contains { $0.name == name } }
    }

    func store(efforts: [AgentModelMenu.Choice], for model: String) {
        guard catalog?.models.contains(where: { $0.name == model }) == true, !efforts.isEmpty else { return }
        effortEntries[model] = Entry(value: efforts, date: now())
    }

    func rememberAlias(_ reported: String, menuName: String) { aliases[reported] = menuName }
    func menuName(for reported: String) -> String? {
        guard let catalog else { return nil }
        let name = aliases[reported] ?? reported
        return catalog.models.contains { $0.name == name } ? name : nil
    }
    func invalidate() { catalogEntry = nil; effortEntries = [:]; aliases = [:] }
}
