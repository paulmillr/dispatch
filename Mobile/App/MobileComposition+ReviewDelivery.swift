import SwiftUI
import UIKit

extension MobileComposition {
    /// Where Create review sends: the agents of a tab's space (`MobileReview.targets`, the tab's own first) and the
    /// conversation's composer path (`MobileReview.outlet`): `MobileChatSession.send(text:steer:)` sends at once when
    /// the agent is idle, else queues on the device and in the helper's queue; Undo takes a queued review back while it
    /// is still queued. Copy goes to the system pasteboard.
    func installReviewDelivery() {
        let tabs = tabs, conversations = conversations, hosts = hosts
        #if DEBUG
        // The Spaces sample's hosts are not sessions: its agents are its tabs' names, and a send goes nowhere.
        let sample = { (host: UUID) in
            hosts.session(host) == nil && [TabsSample.mba2.id, TabsSample.studio.id, TabsSample.ai.id].contains(host)
        }
        #else
        let sample = { (_: UUID) in false }
        #endif
        review.targets = { tab in
            #if DEBUG
            if sample(tab.host) { return Self.reviewTargets(for: tab, tabs: tabs, describe: Self.sampleAgent) }
            #endif
            return Self.reviewTargets(for: tab, tabs: tabs) { key, pane in
                let session = conversations.sessions[key]
                return (session?.agentKey ?? Self.agentName(executable: pane.agent?.executable), session?.modelLabel)
            }
        }
        review.outlet.send = { text, target in
            if sample(target.key.host) { return .success(ReviewDelivery(delivered: false, withdraw: { true })) }
            return await Self.send(text, to: conversations.session(for: target.key))
        }
        review.outlet.draft = { text, target in
            guard !sample(target.key.host) else { return }
            Self.draft(text, in: conversations.session(for: target.key))
        }
        review.outlet.copy = { UIPasteboard.general.string = $0 }
    }

    /// The agent conversations in `tab`'s space, `tab`'s own first, then the others in the space's order: each tab whose
    /// pane runs an agent (`MobileTab.agentPane`), named by `describe` (the agent, "claude", and its model).
    static func reviewTargets(for tab: TabRef, tabs: MobileTabs,
                              describe: (ChatConversationKey, MobilePane) -> (agent: String, model: String?)) -> [ReviewTarget] {
        guard let current = tabs.tab(tab), let space = tabs.space(current.space) else { return [] }
        let host = tabs.workspace(tab.host)?.host
        let targets = space.tabs.compactMap { candidate -> ReviewTarget? in
            guard let pane = candidate.agentPane else { return nil }
            let key = ChatConversationKey(host: tab.host, node: pane.key)
            let (agent, model) = describe(key, pane)
            return ReviewTarget(key: key, agent: agent, tab: tabs.label(of: candidate, host: host), space: space.name,
                                model: model, here: candidate.ref == tab)
        }
        return targets.filter(\.here) + targets.filter { !$0.here }
    }

    /// An agent's name before its conversation said it: the bound process's executable ("claude", "codex", "pi").
    static func agentName(executable: String?) -> String {
        let name = executable.map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
        return ["claude", "codex", "nanocodex", "pi"].contains(name) ? name : "agent"
    }

    #if DEBUG
    /// The sample names its agent tabs after their agents; its models are the mockup's.
    private static func sampleAgent(_ key: ChatConversationKey, _ pane: MobilePane) -> (agent: String, model: String?) {
        let agent = pane.key.hasSuffix("codex") ? "codex" : "claude"
        return (agent, agent == "codex" ? "astra-6" : "fable-5.1")
    }
    #endif

    /// The review into a conversation as its composer's Send would put it, waiting for the outcome: delivered to an idle
    /// agent once `chat.send` confirmed it (nothing to take back), or queued once the device saved it (Undo takes it back
    /// while it is still queued, `MobileChatSession.withdraw`). A prompt that failed is a failure: nothing was taken.
    static func send(_ text: String, to session: MobileChatSession) async -> Result<ReviewDelivery, ReviewSendError> {
        let before = Set(session.queueItems.map(\.id))
        switch await session.sendConfirmed(text: text) {
        case .failure(let refusal):
            return .failure(ReviewSendError(message: refusal.message))
        case .success(let route):
            guard route == .queue || route == .outbox, let queued = session.queueItems.first(where: { !before.contains($0.id) })?.id else {
                return .success(ReviewDelivery(delivered: true, withdraw: { false }))
            }
            return .success(ReviewDelivery(delivered: false, withdraw: { [weak session] in
                guard let session else { return false }
                return await session.withdraw(queued)
            }))
        }
    }

    /// A review that could not be sent goes into the conversation's draft, as the Mac's does: a draft already there is
    /// kept among the saved ones.
    static func draft(_ text: String, in session: MobileChatSession) {
        if !session.drafts.current.isEmpty { session.drafts.keep() }
        session.drafts.edit(text: text)
    }
}
