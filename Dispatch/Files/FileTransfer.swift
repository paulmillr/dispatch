import Foundation

/// One copy shown as a row under the list. The transfer
/// engine drives it; the row renders it and calls `cancel`, `retry` or `resolveConflict`.
@MainActor @Observable final class FileTransfer: Identifiable {
    enum Kind: Hashable, Sendable {
        /// Files from this Mac (Finder, a local tab) into the shown folder.
        case copyIn
        /// Rows dragged out to Finder or another app.
        case copyOut
        /// Local to local.
        case local
        /// Remote to remote, through this Mac; the second row of the pair.
        case relay
    }

    enum Stage: Hashable, Sendable {
        case preparing
        case packing
        case sending
        /// One helper call extracts the archive beside the target and moves the entries in; Cancel is gone.
        case unpacking
        case done
        /// Asked before anything is written: these top-level names already exist in the target.
        case conflict(existing: [String])
        case failed(message: String, retryable: Bool)
        case cancelled
    }

    enum ConflictResolution: Hashable, Sendable {
        case replace, keepBoth, skip, cancel
    }

    let id: UUID
    let kind: Kind
    /// Top-level items being copied (the drag's count).
    var items: Int
    /// Entries in the archive, once packing reported them.
    var entries: UInt64?
    var targetPath: String
    /// What the row names: "fixtures/" or "Downloads".
    var targetLabel: String
    var stage: Stage = .preparing
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64?
    var entriesDone: UInt64 = 0
    /// Bytes per second over the recent window, while sending.
    var rate: Double?
    var startedAt: Date
    var finishedAt: Date?
    /// The copy travels as archives (pack · send · unpack); false for a few small files written one by one.
    var archived = true
    /// Top-level items left out: those the user chose to skip, and under Skip those that appeared since.
    var skipped: UInt64 = 0
    /// A request that writes into the target ended without an answer (a dropped connection, a timeout, a cancel in
    /// flight): it may have written, so the row says so and offers no Retry.
    var uncertain = false

    var cancel: (@MainActor () -> Void)?
    var retry: (@MainActor () -> Void)?
    var resolveConflict: (@MainActor (ConflictResolution) -> Void)?

    init(id: UUID = System.uuid(), kind: Kind, items: Int, targetPath: String, targetLabel: String,
         startedAt: Date = System.date()) {
        self.id = id
        self.kind = kind
        self.items = items
        self.targetPath = targetPath
        self.targetLabel = targetLabel
        self.startedAt = startedAt
    }

    var isActive: Bool {
        switch stage {
        case .preparing, .packing, .sending, .unpacking: true
        case .done, .conflict, .failed, .cancelled: false
        }
    }

    var cancellable: Bool {
        switch stage {
        case .preparing, .packing, .sending: cancel != nil
        case .unpacking, .done, .conflict, .failed, .cancelled: false
        }
    }
}
