import Foundation

/// A review that went out (R5's Send or Copy) and can still be taken back until its Undo window closes (S4).
struct ReviewOutgoing {
    /// The `ReviewSent` it stands for.
    let id: UUID
    /// How to take the message back; nil: copied (nothing to take back).
    let delivery: ReviewDelivery?
    /// What Send took from the repository: Undo puts it back even after the repository forgot it (a comment written
    /// meanwhile ends the repository's own Undo, `ReviewRepository.forgetCopied`).
    let taken: Review
    /// The watch's mirror of the Undo (`WatchReviewEvents`), for a Send.
    let watch: String?
    /// Ends the window.
    var timer: Task<Void, Never>?
}

/// Create review's Send, Copy and Undo (R5, S4), as the Mac's `ReviewFinish`: every comment's line is found again in
/// the files as they are now (`ReviewRefresh` through the host's helper), the review becomes one text in the Mac's
/// format (`ReviewText`), leaves the repository, and goes to the agent or the clipboard. For a minute Undo brings the
/// comments back and takes the message back while the agent does not have it yet; the watch mirrors that Undo.
extension MobileReview {
    // MARK: Text

    /// The markdown the agent gets for the review as it is stored (the line numbers as last placed).
    func preview(context: ReviewContext) -> String {
        ReviewText.render(repository.review(context.place.scope), context: textContext(context))
    }

    /// The markdown the agent gets now: the lines found again first (Preview shows this).
    func rendered(context: ReviewContext) async -> String {
        let review = repository.review(context.place.scope)
        let (refreshed, status) = await refreshed(review, place: context.place)
        return ReviewText.render(refreshed, context: textContext(context, status: status))
    }

    /// What the review is of: the repository, the host by its name, the branch and HEAD as `status` (else Review's
    /// last read) says.
    func textContext(_ context: ReviewContext, status: GitStatus? = nil) -> ReviewText.Context {
        let status = status ?? changes(context.place).status
        return ReviewText.Context(root: context.place.root, host: context.host, branch: status?.branch ?? context.branch,
                                  head: status?.head)
    }

    /// The review with every commented file read again through the host's helper (`files.text`, `files.git diff`).
    /// Without a reader (offline, no grant) the comments keep their numbers; a file the helper says is gone marks its
    /// comments outdated. Returns the status it went by (Review's last read, else read now).
    func refreshed(_ review: Review, place: ReviewPlace) async -> (Review, GitStatus?) {
        let changes = changes(place)
        guard let reader = changes.reader else { return (review, changes.status) }
        var status = changes.status
        if status == nil { status = try? await reader.status(place.root) }
        guard !review.comments.isEmpty else { return (review, status) }
        let refreshed = await Self.refresh(review, status: status ?? GitStatus(changes: [], loadedAt: clock()),
                                           root: place.root, reader: reader)
        return (refreshed, status)
    }

    nonisolated private static func refresh(_ review: Review, status: GitStatus, root: String,
                                            reader: ReviewGitReader) async -> Review {
        await ReviewRefresh.refresh(review, status: status, read: { await read($0, root: root, reader: reader) },
                                    diff: { try? await reader.diff(root, $0) })
    }

    /// A commented file as it is now: its lines, gone (the helper says not found), or unknown.
    nonisolated static func read(_ path: String, root: String, reader: ReviewGitReader) async -> ReviewRefresh.File {
        guard GitChange.representable(path) else { return .unknown }
        do {
            guard let text = try await reader.text(FilesPath.join(root, path)) else { return .unknown }
            return .lines(ReviewRefresh.lines(text))
        } catch let failure as HelperFailure where failure.code == "not_found" || failure.code == "not_directory" {
            return .gone
        } catch {
            return .unknown
        }
    }

    // MARK: Send and Copy

    /// Send to an agent's conversation, as its composer would (at once when it is idle, else queued). The comments stay
    /// until the conversation confirmed the review ("Sending…"); a failure keeps them, puts the review into the
    /// conversation's draft and says why in the sheet (`failures`). Success closes the sheet and opens Undo for a minute;
    /// the watch mirrors that Undo only while the review is queued (an idle agent has it at once: no Undo there).
    func send(to target: ReviewTarget, context: ReviewContext) async {
        await finish(context: context, agent: target.agent) { text in
            switch await self.outlet.send(text, target) {
            case .success(let delivery): return .success(delivery)
            case .failure(let error):
                self.outlet.draft(text, target)
                return .failure(ReviewSendError(message: Self.notSent(error.message, agent: target.agent)))
            }
        } posted: { sent, delivery in
            // Delivered at once: the watch shows no Undo for it (an event with no window).
            let window = delivery?.delivered == false ? Self.undoWindow : 0
            return self.watch?.post(key: target.key, agent: target.agent, title: target.tab, comments: sent.comments,
                                    files: sent.files, window: window) { [weak self] in
                await self?.watchUndo(sent.place, id: sent.id) ?? false
            }
        }
    }

    /// "terminal_unavailable … The review is in claude's draft; the comments are still here."
    static func notSent(_ reason: String, agent: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = reason.isEmpty || reason.hasSuffix(".") ? reason : reason + "."
        return [ended, "The review is in \(agent)’s draft; the comments are still here."].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Copy review: the text on the clipboard, the comments cleared with the same Undo ("Copied").
    func copy(context: ReviewContext) async {
        await finish(context: context, agent: nil) { text in
            self.outlet.copy(text)
            return .success(nil)
        } posted: { _, _ in nil }
    }

    /// Finds the lines again, hands the review's text to `deliver` and, once it went, takes the sent comments from the
    /// repository. Nothing happens with nothing to hand over or while a check or a send runs; a review changed during the
    /// check (the overall comment typed on) is checked again.
    private func finish(context: ReviewContext, agent: String?,
                        deliver: @MainActor (String) async -> Result<ReviewDelivery?, ReviewSendError>,
                        posted: @MainActor (ReviewSent, ReviewDelivery?) -> String?) async {
        let place = context.place, scope = place.scope
        guard !checking.contains(place), !sending.contains(place), !repository.review(scope).isEmpty else { return }
        failures[place] = nil
        checking.insert(place)
        var review = repository.review(scope)
        var refreshed = review
        var status: GitStatus?
        for _ in 0..<3 {
            (refreshed, status) = await self.refreshed(review, place: place)
            let now = repository.review(scope)
            if now == review { break }
            review = now
            refreshed = now
        }
        checking.remove(place)
        guard repository.review(scope) == review, !review.isEmpty else { return }
        let text = ReviewText.render(refreshed, context: textContext(context, status: status))
        sending.insert(place)
        let outcome = await deliver(text)
        sending.remove(place)
        let delivery: ReviewDelivery?
        switch outcome {
        case .failure(let error):
            failures[place] = error.message
            if sheet != context.tab { notice(error.message, place: place) }
            return
        case .success(let value):
            delivery = value
        }
        // A review still in its window is settled first: its Undo would bring back what this one takes.
        end(place, finishWatch: true)
        take(review, scope: scope, agent: agent)
        let now = clock()
        let sent = ReviewSent(id: System.uuid(), place: place, agent: agent, comments: review.comments.count,
                              files: Set(review.comments.map(\.path)).count, sent: now,
                              until: now.addingTimeInterval(Self.undoWindow))
        self.sent[place] = sent
        var outgoing = ReviewOutgoing(id: sent.id, delivery: delivery, taken: review, watch: posted(sent, delivery))
        let sleep = sleep
        outgoing.timer = Task { [weak self] in
            do { try await sleep(.seconds(Self.undoWindow)) } catch { return }
            self?.windowEnded(place, id: sent.id)
        }
        self.outgoing[place] = outgoing
        if sheet == context.tab { sheet = nil }
    }

    /// The sent comments leave the repository: the whole review when nothing changed while it went (the repository's
    /// own Undo keeps it), else only what was sent (a comment written meanwhile from another tab stays).
    private func take(_ review: Review, scope: String, agent: String?) {
        if repository.review(scope) == review {
            repository.take(scope, sentTo: agent)
            return
        }
        for comment in review.comments { repository.remove(comment.id, from: scope) }
        if repository.review(scope).summary == review.summary, !review.summary.isEmpty { repository.setSummary("", in: scope) }
    }

    // MARK: Undo

    /// S4's Undo: the comments come back at once; the message is taken back when it is still queued. When the agent has
    /// it already (delivered at once, or the helper refused to remove it), the accessory says so.
    func undo(_ place: ReviewPlace) async {
        guard let outgoing = outgoing[place] else {
            // Debug's S4 demo: a sent note without a review behind it.
            sent[place] = nil
            return
        }
        let agent = sent[place]?.agent
        end(place, finishWatch: true)
        restore(outgoing.taken, place: place)
        guard let delivery = outgoing.delivery, let agent else { return }
        if delivery.delivered {
            notice("Comments restored · \(agent) already has the review", place: place)
        } else if await !delivery.withdraw() {
            notice("Already sent · comments restored", place: place)
        }
    }

    /// The watch's Undo: only when the message could be taken back (else the agent has it: too late).
    private func watchUndo(_ place: ReviewPlace, id: UUID) async -> Bool {
        guard let outgoing = outgoing[place], outgoing.id == id, let delivery = outgoing.delivery, !delivery.delivered,
              await delivery.withdraw() else { return false }
        restore(outgoing.taken, place: place)
        // `WatchReviewEvents.undo` finishes its own event; the phone's Undo may have taken it meanwhile.
        if self.outgoing[place]?.id == id { end(place, finishWatch: false) }
        return true
    }

    /// A note in the accessory for `noticeDuration`.
    private func notice(_ text: String, place: ReviewPlace) {
        notices[place] = text
        let sleep = sleep
        Task { [weak self] in
            do { try await sleep(Self.noticeDuration) } catch { return }
            if self?.notices[place] == text { self?.notices[place] = nil }
        }
    }

    /// The window closed: the agent keeps the review, the note goes.
    private func windowEnded(_ place: ReviewPlace, id: UUID) {
        guard outgoing[place]?.id == id else { return }
        end(place, finishWatch: true)
        repository.forgetCopied(place.scope)
    }

    /// The taken comments back beside any written since (the repository's own Undo while it still has it).
    private func restore(_ taken: Review, place: ReviewPlace) {
        let scope = place.scope
        if repository.copied[scope] == taken {
            repository.restore(scope)
            return
        }
        let current = repository.review(scope)
        for comment in taken.comments where !current.comments.contains(where: { $0.id == comment.id }) {
            repository.add(comment, to: scope)
        }
        if current.summary.isEmpty, !taken.summary.isEmpty { repository.setSummary(taken.summary, in: scope) }
    }

    /// Forgets the review in its window: the note, the timer and (unless the watch took it back itself) its event.
    private func end(_ place: ReviewPlace, finishWatch: Bool) {
        if let outgoing = outgoing.removeValue(forKey: place) {
            outgoing.timer?.cancel()
            if finishWatch, let id = outgoing.watch { watch?.finished(id) }
        }
        if sent[place] != nil { sent[place] = nil }
    }

    // MARK: Remove all data

    /// Settings' Remove all data: every review and overall comment, the notes and their Undo, and `reviews.json` itself
    /// (`file`); the repository starts over empty and writable.
    func removeAll() {
        for place in Array(outgoing.keys) { end(place, finishWatch: true) }
        sent = [:]
        failures = [:]
        notices = [:]
        repository.reset()
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
