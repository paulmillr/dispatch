import Foundation

/// Keeps cancelled work observable until its callback has actually returned.
/// Clearing a submission's UI state is not a completion barrier for actor calls.
@MainActor
final class ChatOperations {
    private struct Operation {
        let session: UUID?
        let task: Task<Void, Never>
    }
    private var operations: [UUID: Operation] = [:]

    @discardableResult
    func run(for session: UUID? = nil, _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            await body()
            self?.operations.removeValue(forKey: id)
        }
        operations[id] = Operation(session: session, task: task)
        return task
    }

    func pending(for session: UUID? = nil) -> Int {
        operations.values.filter { session == nil || $0.session == nil || $0.session == session }.count
    }

    func cancel(for session: UUID) {
        for operation in operations.values where operation.session == session { operation.task.cancel() }
    }

    func wait(for session: UUID? = nil) async {
        while true {
            let tasks = operations.values.filter { session == nil || $0.session == nil || $0.session == session }.map(\.task)
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }
}
