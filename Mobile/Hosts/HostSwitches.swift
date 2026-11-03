import SwiftUI

extension HostSessions {
    /// The Helper switch outside Edit host (the stats' "Install helper…" and "Use plain SSH", Files' Install helper…),
    /// saved at once: the session reconnects with the new choice (`update`). Off turns Chat and Files & git off with it
    /// (`HostRecord.helper`); on turns them on again, as New host does (`HostFeatureDraft`).
    func setHelper(_ helper: Bool, host id: UUID) {
        guard var record = store.record(id), record.helper != helper else { return }
        record.helper = helper
        if helper {
            record.chat = true
            record.files = true
        }
        update(record)
    }
}
