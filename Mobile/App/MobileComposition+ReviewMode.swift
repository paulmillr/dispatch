import SwiftUI

extension MobileComposition {
    /// The Files segment's Review mode (`FilesModeSlot`): the changes list (H2) with its bar and accessory (Create
    /// review, or the sent note with Undo), Create review's sheet, the pushed diffs, and the tab's comment count for the
    /// badges. Every tab in one repository on one host shares its review (`ReviewPlace`).
    func installReviewMode(_ slot: inout FilesModeSlot) {
        let review = review, gitFacts = gitFacts, tabs = tabs, navigator = navigator
        slot.body = { context in
            guard let place = Self.reviewContext(context, review: review) else { return AnyView(Color.canvas) }
            return AnyView(ReviewModeBody(context: place))
        }
        slot.bar = { context in
            Self.reviewContext(context, review: review).map { AnyView(ReviewBar(context: $0)) }
        }
        slot.accessory = { context in
            guard let place = Self.reviewContext(context, review: review), ReviewAccessory.shows(place) else { return nil }
            return AnyView(ReviewAccessory(context: place))
        }
        slot.destination = { tab, route in
            guard let place = Self.reviewContext(tab, review: review, gitFacts: gitFacts, tabs: tabs,
                                                 push: { navigator.path.append(.files(tab, $0)) }),
                  let path = route.path else { return AnyView(FilesModePlaceholder(mode: .review)) }
            return AnyView(ReviewDiffScreen(context: place, path: path, area: route.reviewArea))
        }
        // The iPad: a change's diff in the pane beside the list (`PadListPane`), its own header in place of the bar.
        slot.pane = { tab, route in
            guard let place = Self.reviewContext(tab, review: review, gitFacts: gitFacts, tabs: tabs,
                                                 push: { navigator.path.append(.files(tab, $0)) }),
                  let path = route.path else { return AnyView(FilesModePlaceholder(mode: .review)) }
            return AnyView(ReviewDiffScreen(context: place, path: path, area: route.reviewArea, showsBack: false))
        }
        // A change committed or reverted meanwhile leaves the list: its pane empties (once the list has read).
        slot.paneShows = { tab, route in
            guard let path = route.path,
                  let place = Self.reviewContext(tab, review: review, gitFacts: gitFacts, tabs: tabs, push: { _ in }),
                  let status = review.changes(place.place).status else { return true }
            return status.changes.contains { change in change.path == path && (route.reviewArea.map { change.area == $0 } ?? true) }
        }
        // The iPad's banner under the row: only the review just sent (with Undo) and the notices; Create review is the
        // row's pill there (`ReviewBar`).
        slot.banner = { context in
            guard let place = Self.reviewContext(context, review: review),
                  review.sent[place.place] != nil || review.notices[place.place] != nil else { return nil }
            return AnyView(ReviewAccessory(context: place))
        }
        slot.count = { tab in
            guard let root = gitFacts.facts(SpaceGitFacts.Key(host: tab.host, key: tab.key))?.root else { return 0 }
            return review.count(ReviewPlace(host: tab.host, root: root))
        }
    }

    /// Review's view of a Files mode's context; nil outside a repository (Review does not show there).
    static func reviewContext(_ context: FilesModeContext, review: MobileReview) -> ReviewContext? {
        guard let root = context.git?.root else { return nil }
        return ReviewContext(review: review, place: ReviewPlace(host: context.host.id, root: root), tab: context.tab.ref,
                             host: context.host.name, branch: context.git?.branch, offline: context.availability.isOffline,
                             push: context.push)
    }

    /// The same for a pushed screen, from the tab's facts.
    static func reviewContext(_ tab: TabRef, review: MobileReview, gitFacts: SpaceGitFacts, tabs: MobileTabs,
                              push: @escaping (FilesRoute) -> Void) -> ReviewContext? {
        guard let facts = gitFacts.facts(SpaceGitFacts.Key(host: tab.host, key: tab.key)), let root = facts.root else { return nil }
        let host = tabs.workspace(tab.host)?.host
        return ReviewContext(review: review, place: ReviewPlace(host: tab.host, root: root), tab: tab,
                             host: host?.name ?? "", branch: facts.branch,
                             offline: host.map { MobileFilesAvailability($0).isOffline } ?? false, push: push)
    }
}

/// Review's body: the list, and Create review's sheet over it while `MobileReview.sheet` names this tab.
private struct ReviewModeBody: View {
    let context: ReviewContext

    var body: some View {
        let review = context.review
        ReviewChangesScreen(context: context)
            .sheet(isPresented: Binding(get: { review.sheet == context.tab }, set: { if !$0, review.sheet == context.tab { review.sheet = nil } })) {
                CreateReviewSheet(context: context)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                // Debug (`-DispatchReviewSheet`): Create review opens over the shown tab's list.
                if review.demo?.sheet != nil, !Self.demoShown {
                    Self.demoShown = true
                    review.sheet = context.tab
                }
            }
    }

    @MainActor private static var demoShown = false
}
