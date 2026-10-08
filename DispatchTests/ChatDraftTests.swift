import XCTest
@testable import DispatchApp

@MainActor final class ChatDraftTests: XCTestCase {
    private func collection(_ store: ChatDraftMemoryStore = ChatDraftMemoryStore()) -> ChatDraftCollection {
        ChatDraftCollection(repository: ChatDraftRepository(store: store))
    }
    func testKeepSwitchEditRenameDeleteAndStickyMultiline() throws {
        let drafts = collection()
        drafts.edit(text: "\nFirst 🧑🏽‍💻\nsecond", selection: NSRange(location: 2, length: 2))
        XCTAssertTrue(drafts.current.multiline)
        drafts.keep()
        XCTAssertFalse(drafts.current.multiline); XCTAssertTrue(drafts.current.isEmpty)
        let id = try XCTUnwrap(drafts.saved.first?.id)
        XCTAssertEqual(drafts.saved.first?.label, "First 🧑🏽‍💻")
        drafts.edit(text: "unfinished")
        drafts.select(id)
        XCTAssertEqual(drafts.current.selection, NSRange(location: 2, length: 2))
        drafts.edit(text: "one line")
        XCTAssertTrue(drafts.current.multiline)
        XCTAssertEqual(drafts.saved.map(\.id), [id])
        drafts.rename(id, title: "Custom")
        XCTAssertEqual(drafts.current.label, "Custom")
        drafts.navigate(1); XCTAssertEqual(drafts.current.text, "unfinished")
        drafts.navigate(-1); XCTAssertEqual(drafts.current.text, "one line")
        drafts.keep()
        XCTAssertTrue(drafts.current.isEmpty)
        XCTAssertEqual(drafts.saved.map(\.text), ["one line", "unfinished"])
        drafts.delete(id); XCTAssertEqual(drafts.saved.count, 1)
        drafts.undoDelete(); XCTAssertEqual(drafts.saved.first?.id, id)
        drafts.edit(text: " \n "); drafts.keep(); XCTAssertEqual(drafts.saved.count, 2)
    }
    func testIsolationMigrationReconnectAndRecoveryMenu() throws {
        let store = ChatDraftMemoryStore(), repository = ChatDraftRepository(store: ChatDraftMemoryStore())
        let drafts = ChatDraftCollection(repository: repository)
        drafts.edit(text: "before identity"); drafts.keep(); drafts.edit(text: "working")
        let provisional = drafts.scope
        drafts.bind(host: "local", agent: "codex", conversation: "one")
        XCTAssertNil(repository.buckets[provisional])
        XCTAssertEqual(drafts.saved.map(\.text), ["before identity"])
        XCTAssertEqual(drafts.current.text, "working")
        let original = drafts.scope
        drafts.bind(host: "ssh:host", agent: "codex", conversation: "one")
        XCTAssertTrue(drafts.current.isEmpty)
        drafts.edit(text: "remote")
        drafts.bind(host: "local", agent: "codex", conversation: "one")
        XCTAssertEqual(drafts.scope, original); XCTAssertEqual(drafts.current.text, "working")
        drafts.bind(host: "local", agent: "claude", conversation: "one")
        XCTAssertTrue(drafts.current.isEmpty)
        XCTAssertTrue(drafts.recoverable.contains(original))
        drafts.recover(original); XCTAssertEqual(drafts.saved.map(\.text), ["before identity", "working"])
        XCTAssertNil(repository.buckets[original])
        let first = collection(store)
        first.bind(host: "ssh:stable-host", agent: "pi", conversation: "conversation")
        first.edit(text: "reconnect\ntext"); first.persist(flush: true)
        let reopened = collection(store)
        reopened.bind(host: "ssh:stable-host", agent: "pi", conversation: "conversation")
        XCTAssertEqual(reopened.current.text, "reconnect\ntext"); XCTAssertTrue(reopened.current.multiline)
    }
    func testDeliveryFailureTargetsOriginalRevisionAndConversation() throws {
        let drafts = collection()
        drafts.bind(host: "local", agent: "codex", conversation: "first")
        drafts.edit(text: "send this")
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: true))
        XCTAssertTrue(drafts.current.isEmpty)
        drafts.edit(text: "newer text")
        drafts.finish(delivery, success: false)
        XCTAssertEqual(drafts.current.text, "newer text")
        XCTAssertEqual(drafts.saved.map(\.text), ["send this"])
        drafts.finish(delivery, success: false)
        XCTAssertEqual(drafts.saved.count, 1, "A completion is idempotent")
        let next = try XCTUnwrap(drafts.prepareDelivery(consume: true))
        drafts.bind(host: "local", agent: "codex", conversation: "second")
        drafts.edit(text: "second conversation")
        drafts.finish(next, success: false)
        XCTAssertEqual(drafts.current.text, "second conversation"); XCTAssertTrue(drafts.saved.isEmpty)
        drafts.bind(host: "local", agent: "codex", conversation: "first")
        XCTAssertEqual(drafts.saved.map(\.text), ["send this", "newer text"])
        drafts.select(drafts.saved[0].id)
        let command = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.edit(text: "edited during send")
        drafts.finish(command, success: true)
        XCTAssertEqual(drafts.current.text, "edited during send")
    }
    func testFailedDeliveryDoesNotDuplicateUnchangedSavedDraftAfterSelectionChanges() throws {
        let drafts = collection()
        drafts.edit(text: "Original"); drafts.keep()
        let original = try XCTUnwrap(drafts.saved.first)
        drafts.select(original.id)
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.select(nil); drafts.edit(text: "New working text")
        drafts.finish(delivery, success: false)
        XCTAssertEqual(drafts.saved, [original])
        XCTAssertEqual(drafts.current.text, "New working text")
    }

    func testProvisionalReconnectPreservesSelectedReplacementDraftWithEmptyWorkingBuffer() throws {
        let drafts = collection()
        drafts.edit(text: "Retained conversation draft")
        let retained = drafts.scope
        drafts.beginProvisional()
        drafts.edit(text: "Replacement draft"); drafts.keep()
        let replacement = try XCTUnwrap(drafts.saved.first)
        drafts.select(replacement.id)
        drafts.resumeProvisional(retained)
        XCTAssertEqual(drafts.scope, retained)
        XCTAssertEqual(drafts.selected, replacement.id)
        XCTAssertEqual(drafts.current.text, "Replacement draft")
        XCTAssertEqual(drafts.bucket.working.text, "Retained conversation draft")
        XCTAssertEqual(drafts.saved.map(\.text), ["Replacement draft"])
    }

    func testConversationDiscoveryKeepsNewWorkingTextVisibleAlongsideRetainedDrafts() throws {
        for retainedSelection in [false, true] {
            let drafts = collection()
            drafts.bind(host: "local", agent: "codex", conversation: "known")
            drafts.edit(text: "Retained saved"); drafts.keep()
            let saved = try XCTUnwrap(drafts.saved.first)
            drafts.edit(text: "Retained working")
            if retainedSelection { drafts.select(saved.id) }
            drafts.beginProvisional()
            drafts.edit(text: "Typed before discovery", selection: NSRange(location: 6, length: 3))
            let visible = drafts.current
            drafts.bind(host: "local", agent: "codex", conversation: "known")
            XCTAssertEqual(drafts.current, visible)
            XCTAssertNil(drafts.selected)
            XCTAssertEqual(drafts.saved.map(\.text), ["Retained saved", "Retained working"])
            XCTAssertEqual(Set((drafts.saved + [drafts.bucket.working]).map(\.id)).count, 3)
        }
    }

    func testPendingDeliveryFollowsProvisionalReconnectAndDiscoveryWithoutReplacingNewTyping() throws {
        for consume in [false, true] {
            for success in [false, true] {
                let store = ChatDraftMemoryStore(), drafts = collection(store)
                drafts.bind(host: "local", agent: "codex", conversation: "known")
                drafts.edit(text: "Known working draft")
                drafts.beginProvisional()
                drafts.edit(text: "Retained provisional draft")
                let retained = drafts.scope
                drafts.beginProvisional()
                drafts.edit(text: "Submitted text")
                let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: consume))
                drafts.edit(text: "New typing", selection: NSRange(location: 2, length: 3))
                let current = drafts.current
                drafts.resumeProvisional(retained)
                drafts.bind(host: "local", agent: "codex", conversation: "known")
                XCTAssertEqual(drafts.current, current)
                drafts.finish(delivery, success: success)
                drafts.finish(delivery, success: success)
                XCTAssertEqual(drafts.current, current)
                XCTAssertEqual(drafts.saved.map(\.text), ["Retained provisional draft", "Known working draft"] + (success ? [] : ["Submitted text"]))
                XCTAssertTrue(drafts.bucket.recovery.isEmpty)
                XCTAssertNil(drafts.repository.buckets[delivery.scope])
                let restarted = collection(store)
                restarted.bind(host: "local", agent: "codex", conversation: "known")
                XCTAssertEqual(restarted.current, current)
                XCTAssertEqual(restarted.saved, drafts.saved)
            }
        }
    }

    func testUndoDeletionAfterFailedDeliveryDoesNotDuplicateRestoredDraft() throws {
        for occupied in [false, true] {
            let drafts = collection()
            drafts.edit(text: "Submitted"); drafts.keep()
            let original = try XCTUnwrap(drafts.saved.first)
            drafts.select(original.id)
            let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
            drafts.delete(original.id)
            if occupied { drafts.edit(text: "New working draft") }
            drafts.finish(delivery, success: false)
            drafts.undoDelete()
            let records = drafts.saved + [drafts.bucket.working]
            XCTAssertEqual(records.filter { $0.revision == original.revision }.count, 1)
            XCTAssertEqual(Set(records.map(\.id)).count, records.count)
            XCTAssertEqual(drafts.current.text, occupied ? "New working draft" : "Submitted")
            XCTAssertFalse(drafts.canUndoDelete)
        }
    }

    func testUndoDeletionAfterEditingFailedDeliverySnapshotKeepsBothVersionsSelectable() throws {
        let drafts = collection()
        drafts.edit(text: "Submitted"); drafts.keep()
        let original = try XCTUnwrap(drafts.saved.first)
        drafts.select(original.id)
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.delete(original.id)
        drafts.finish(delivery, success: false)
        drafts.edit(text: "Edited restored draft")
        drafts.undoDelete()
        XCTAssertEqual(drafts.current.text, "Edited restored draft")
        XCTAssertEqual(drafts.saved.map(\.text), ["Submitted"])
        XCTAssertNotEqual(drafts.saved.first?.id, drafts.current.id)
        drafts.keep()
        XCTAssertEqual(Set(drafts.saved.map(\.id)).count, 2)
    }

    func testDeliveryCompletionAfterConversationSwitchPreservesEditedSelectionAndFailedSnapshot() throws {
        for success in [true, false] {
            let drafts = collection()
            drafts.bind(host: "local", agent: "codex", conversation: "first")
            drafts.edit(text: "Original"); drafts.keep()
            let original = try XCTUnwrap(drafts.saved.first)
            drafts.select(original.id)
            let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
            drafts.edit(text: "Edited during send")
            drafts.bind(host: "local", agent: "codex", conversation: "second")
            drafts.finish(delivery, success: success)
            drafts.bind(host: "local", agent: "codex", conversation: "first")
            XCTAssertEqual(drafts.selected, original.id)
            XCTAssertEqual(drafts.current.text, "Edited during send")
            XCTAssertEqual(drafts.saved.map(\.text), success ? ["Edited during send"] : ["Edited during send", "Original"])
            XCTAssertEqual(Set(drafts.saved.map(\.id)).count, drafts.saved.count)
        }
    }

    func testFailedDeliveryRestoredToWorkingBufferHasDistinctIdentityFromEditedSavedDraft() throws {
        let drafts = collection()
        drafts.edit(text: "Original"); drafts.keep()
        let original = try XCTUnwrap(drafts.saved.first)
        drafts.select(original.id)
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.edit(text: "Edited saved draft")
        drafts.select(nil)
        drafts.finish(delivery, success: false)
        XCTAssertEqual(drafts.current.text, "Original")
        XCTAssertEqual(drafts.saved.map(\.text), ["Edited saved draft"])
        XCTAssertNotEqual(drafts.current.id, original.id)
        drafts.keep()
        XCTAssertEqual(Set(drafts.saved.map(\.id)).count, 2)
    }

    func testAtomicJSONRoundTripAndRestartNeverQueuesSnapshots() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drafts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ChatDraftFileStore(url: url)
        let drafts = ChatDraftCollection(repository: ChatDraftRepository(store: store))
        drafts.bind(host: "local", agent: "codex", conversation: "same")
        drafts.edit(text: "in flight\nλ", selection: NSRange(location: 1, length: 3)); drafts.keep()
        let record = try XCTUnwrap(drafts.saved.first)
        drafts.select(record.id)
        _ = try XCTUnwrap(drafts.prepareDelivery(consume: true))
        drafts.edit(text: "typing"); drafts.persist(flush: true)
        let restarted = ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: store))
        restarted.sessionID = "same"
        XCTAssertEqual(restarted.draft, "typing")
        XCTAssertEqual(restarted.drafts.saved, [record])
        XCTAssertTrue(restarted.queuedMessages.isEmpty); XCTAssertNil(restarted.submissionID)
        restarted.drafts.persist(flush: true)
        let again = ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: store)); again.sessionID = "same"
        XCTAssertEqual(again.drafts.saved, [record])
    }

    func testRestartRecoversRepeatedPendingRevisionOnlyOnceAlongsideNewerEdit() throws {
        let store = ChatDraftMemoryStore()
        let drafts = collection(store)
        drafts.bind(host: "local", agent: "codex", conversation: "repeat-send")
        drafts.edit(text: "Submitted version"); drafts.keep()
        let original = try XCTUnwrap(drafts.saved.first)
        drafts.select(original.id)
        _ = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        _ = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.edit(text: "Newer edit"); drafts.persist(flush: true)
        let restarted = collection(store)
        restarted.bind(host: "local", agent: "codex", conversation: "repeat-send")
        XCTAssertEqual(restarted.current.text, "Newer edit")
        XCTAssertEqual(restarted.saved.map(\.text), ["Newer edit", "Submitted version"])
        XCTAssertEqual(Set(restarted.saved.map(\.id)).count, 2)
        restarted.persist(flush: true)
        let again = collection(store)
        again.bind(host: "local", agent: "codex", conversation: "repeat-send")
        XCTAssertEqual(again.saved, restarted.saved)
    }

    func testRepeatedFailedDeliveriesRestoreOneRevisionInActiveAndInactiveConversation() throws {
        for switchConversation in [false, true] {
            let drafts = collection()
            drafts.bind(host: "local", agent: "codex", conversation: "first")
            drafts.edit(text: "Submitted version"); drafts.keep()
            drafts.select(try XCTUnwrap(drafts.saved.first).id)
            let first = try XCTUnwrap(drafts.prepareDelivery(consume: false))
            let second = try XCTUnwrap(drafts.prepareDelivery(consume: false))
            drafts.edit(text: "Newer edit")
            if switchConversation { drafts.bind(host: "local", agent: "codex", conversation: "second") }
            drafts.finish(first, success: false)
            drafts.finish(second, success: false)
            drafts.bind(host: "local", agent: "codex", conversation: "first")
            XCTAssertEqual(drafts.saved.map(\.text), ["Newer edit", "Submitted version"])
            XCTAssertEqual(drafts.current.text, "Newer edit")
        }
    }

    func testManualRecoveryDeduplicatesPendingVersionsWithoutReplacingDestinationDraft() throws {
        let drafts = collection()
        drafts.bind(host: "local", agent: "codex", conversation: "first")
        drafts.edit(text: "Submitted version"); drafts.keep()
        drafts.select(try XCTUnwrap(drafts.saved.first).id)
        _ = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        _ = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.edit(text: "Newer edit")
        let source = drafts.scope
        drafts.bind(host: "local", agent: "codex", conversation: "second")
        drafts.edit(text: "Destination draft")
        drafts.recover(source)
        XCTAssertEqual(drafts.current.text, "Destination draft")
        XCTAssertEqual(drafts.saved.map(\.text), ["Newer edit", "Submitted version"])
        XCTAssertEqual(Set(drafts.saved.map(\.id)).count, 2)
        XCTAssertFalse(drafts.recoverable.contains(source))
    }
    func testWriteFailurePreservesVisibleDraftAndCanRetry() throws {
        final class FailingStore: ChatDraftPersistence {
            var fail = true
            var writes = 0
            func load() throws -> [String: ChatDraftBucket] { [:] }
            func save(_ buckets: [String: ChatDraftBucket]) throws {
                writes += 1
                if fail { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        let store = FailingStore()
        let actual = ChatDraftRepository(store: store), drafts = ChatDraftCollection(repository: actual)
        drafts.edit(text: "must survive")
        XCTAssertNil(drafts.prepareDelivery(consume: true)); XCTAssertEqual(drafts.current.text, "must survive")
        XCTAssertNotNil(actual.error)
        store.fail = false; XCTAssertTrue(actual.flush()); XCTAssertNil(actual.error)
        XCTAssertNotNil(drafts.prepareDelivery(consume: true))
    }
    func testContinuousTypingHasBoundedAutosaveDelay() async throws {
        let store = ChatDraftMemoryStore()
        let drafts = ChatDraftCollection(repository: ChatDraftRepository(store: store))
        // Never leave the 300ms idle interval required by the ordinary debounce.
        for index in 0..<26 {
            drafts.edit(text: "continuous typing \(index)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let saved = try XCTUnwrap(store.buckets[drafts.scope]?.working.text)
        XCTAssertTrue(saved.hasPrefix("continuous typing "))
        XCTAssertGreaterThanOrEqual(Int(saved.split(separator: " ").last!)!, 15)
        drafts.persist(flush: true)
        XCTAssertEqual(store.buckets[drafts.scope]?.working.text, "continuous typing 25")
    }

    func testDebounceAndCoordinatorClosureFlush() async throws {
        let store = ChatDraftMemoryStore(), closing = ChatDraftMemoryStore()
        let repo = ChatDraftRepository(store: store), chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: closing))
        let drafts = ChatDraftCollection(repository: repo)
        drafts.edit(text: "a"); drafts.edit(text: "ab")
        XCTAssertTrue(store.buckets.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.buckets[drafts.scope]?.working.text, "ab")
        let session = chat.session(for: UUID()); session.sessionID = "close"; session.draft = "close immediately"
        XCTAssertNotEqual(closing.buckets[session.drafts.scope]?.working.text, "close immediately", "The debounce has not written yet")
        chat.close(session.id)
        XCTAssertEqual(closing.buckets[session.drafts.scope]?.working.text, "close immediately")
        let next = chat.session(for: UUID()); next.sessionID = "shutdown"; next.draft = "shutdown immediately"
        XCTAssertNotEqual(closing.buckets[next.drafts.scope]?.working.text, "shutdown immediately")
        chat.stop()
        XCTAssertEqual(closing.buckets[next.drafts.scope]?.working.text, "shutdown immediately")
    }
}

extension ChatDraftTests {
    func testProvisionalDeliveryMigratesAndCompletesInIdentifiedConversation() throws {
        let store = ChatDraftMemoryStore(), drafts = ChatDraftCollection(repository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        drafts.edit(text: "first message")
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: true))
        drafts.bind(host: "ssh:host", agent: "codex", conversation: "identified")
        XCTAssertEqual(drafts.bucket.recovery.count, 1)
        drafts.finish(delivery, success: false)
        XCTAssertEqual(drafts.current.text, "first message"); XCTAssertTrue(drafts.bucket.recovery.isEmpty)
        let session = ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: store))
        session.sessionID = "old"; session.draft = "old conversation"
        let old = session.drafts.scope
        session.sessionID = nil; session.draft = "before new identification"
        XCTAssertTrue(session.drafts.scope.hasPrefix("provisional:"))
        session.sessionID = "new"
        XCTAssertEqual(session.draft, "before new identification")
        XCTAssertEqual(store.buckets[old]?.working.text, "old conversation")
    }
    func testSuccessfulCommandConsumesItsSavedRevisionAfterSwitchingDrafts() throws {
        let drafts = ChatDraftCollection(repository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        drafts.edit(text: "/status"); drafts.keep()
        let id = try XCTUnwrap(drafts.saved.first?.id); drafts.select(id)
        let delivery = try XCTUnwrap(drafts.prepareDelivery(consume: false))
        drafts.select(nil); drafts.edit(text: "next")
        drafts.finish(delivery, success: true)
        XCTAssertEqual(drafts.current.text, "next"); XCTAssertTrue(drafts.saved.isEmpty)
    }
    func testRetryAfterReadFailurePreservesDiskDraftsAlongsideNewTyping() throws {
        final class Store: ChatDraftPersistence {
            var readable = false
            var buckets: [String: ChatDraftBucket]
            init(_ buckets: [String: ChatDraftBucket]) { self.buckets = buckets }
            func load() throws -> [String: ChatDraftBucket] {
                guard readable else { throw NSError(domain: "temporarily-unreadable", code: 1) }
                return buckets
            }
            func save(_ buckets: [String: ChatDraftBucket]) throws { self.buckets = buckets }
        }
        let seed = collection()
        seed.bind(host: "local", agent: "codex", conversation: "existing")
        seed.edit(text: "Saved before restart"); seed.keep()
        seed.edit(text: "Earlier working text"); seed.persist(flush: true)
        _ = try XCTUnwrap(seed.prepareDelivery(consume: true))
        seed.edit(text: "Newer disk working text"); seed.persist(flush: true)
        let store = Store(seed.repository.buckets)
        let repository = ChatDraftRepository(store: store)
        let drafts = ChatDraftCollection(repository: repository)
        drafts.bind(host: "local", agent: "codex", conversation: "existing")
        drafts.edit(text: "Typed while unavailable")
        store.readable = true
        drafts.persist(flush: true)
        XCTAssertNil(repository.error)
        drafts.edit(text: "Continued typing"); drafts.persist(flush: true)
        let texts = Set(store.buckets.values.flatMap { $0.saved.map(\.text) + [$0.working.text] })
        XCTAssertTrue(texts.isSuperset(of: ["Saved before restart", "Earlier working text", "Newer disk working text", "Continued typing"]))
        XCTAssertEqual(drafts.current.text, "Continued typing")
        let restarted = ChatDraftCollection(repository: ChatDraftRepository(store: store))
        restarted.bind(host: "local", agent: "codex", conversation: "existing")
        XCTAssertEqual(restarted.current.text, "Continued typing")
        XCTAssertEqual(restarted.recoverable.count, 1)
        for key in restarted.recoverable { restarted.recover(key) }
        XCTAssertEqual(Set(restarted.saved.map(\.text)), ["Saved before restart", "Earlier working text", "Newer disk working text"])
        XCTAssertEqual(restarted.saved.count, 3)
        XCTAssertEqual(restarted.current.text, "Continued typing")
        let reopened = ChatDraftCollection(repository: ChatDraftRepository(store: store))
        reopened.bind(host: "local", agent: "codex", conversation: "existing")
        XCTAssertEqual(reopened.saved.count, 3)
        XCTAssertTrue(reopened.recoverable.isEmpty)
        XCTAssertTrue(store.buckets.values.allSatisfy { $0.recovery.isEmpty })
    }

    func testUnreadableStoreIsNotOverwrittenByAnEmptyCollection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let malformed = Data("existing damaged recovery".utf8); try malformed.write(to: url)
        let repository = ChatDraftRepository(store: ChatDraftFileStore(url: url))
        let current = ChatDraftCollection(repository: repository)
        current.edit(text: "still editable"); current.keep()
        XCTAssertNotNil(repository.error); XCTAssertEqual(current.saved.first?.text, "still editable")
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }
}
