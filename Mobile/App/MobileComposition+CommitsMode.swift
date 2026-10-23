import SwiftUI

extension MobileComposition {
    /// The Files segment's Commits mode (`FilesModeSlot`, H3): the log under the capsule, its bar (branch, count, search,
    /// filters), and the screens it pushes: a commit (C2, `FilesRoute.revision`) and a commit's file (`path`, a rename's
    /// old path in `detail`).
    func installCommitsMode(_ slot: inout FilesModeSlot) {
        let commits = commits
        slot.body = { context in
            AnyView(CommitsListView(log: commits.log(context.tab.ref), context: context, queries: commits.queries(context.tab.ref)))
        }
        slot.bar = { context in AnyView(CommitsBar(log: commits.log(context.tab.ref), context: context)) }
        slot.destination = { tab, route in
            let log = commits.log(tab)
            guard let revision = route.revision else { return AnyView(FilesModePlaceholder(mode: .commits)) }
            if let path = route.path {
                return AnyView(CommitFileScreen(log: log, hash: revision, path: path, oldPath: route.detail,
                                                queries: commits.queries(tab)))
            }
            return AnyView(CommitDetailScreen(log: log, tab: tab, hash: revision, queries: commits.queries(tab)))
        }
        // The iPad: a commit in the pane beside the log (`PadListPane`), with its own header.
        slot.pane = { tab, route in
            guard let revision = route.revision else { return AnyView(FilesModePlaceholder(mode: .commits)) }
            return AnyView(CommitDetailScreen(log: commits.log(tab), tab: tab, hash: revision, queries: commits.queries(tab),
                                              pane: true))
        }
    }

    /// Where the Commits mode reads: the tab's repository (`SpaceGitFacts`) through the host's helper when its grant has
    /// `git.read`; in Debug's Spaces sample the mockup's repository (`CommitsFixture.sample`).
    func wireCommits(sample: Bool) {
        let gitFacts = gitFacts, tabs = tabs
        #if DEBUG
        if sample {
            let fixture = CommitsFixture.sample()
            commits.queries = { ref in
                let root = gitFacts.facts(SpaceGitFacts.Key(host: ref.host, key: ref.key))?.root
                return root.map { CommitsQueries(git: fixture, root: $0, host: tabs.workspace(ref.host)?.host.name ?? "") }
            }
            return
        }
        #endif
        commits.queries = { ref in
            guard let root = gitFacts.facts(SpaceGitFacts.Key(host: ref.host, key: ref.key))?.root,
                  let client = gitFacts.client(ref.host) else { return nil }
            return CommitsQueries(git: HelperCommitsGit(client: client), root: root,
                                  host: tabs.workspace(ref.host)?.host.name ?? "the host")
        }
    }
}
