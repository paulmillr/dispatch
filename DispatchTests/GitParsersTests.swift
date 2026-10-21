import Foundation
import XCTest
@testable import DispatchApp

/// The git parsers against output recorded from real git 2.54 (`git -c core.quotepath=false -c color.ui=never`, the
/// arguments GitQueries sends) in two scratch repositories: one with staged, unstaged, renamed, deleted, binary,
/// untracked and ignored files, tags, a remote branch and an upstream; one with a merge, a conflict, quoted names and a
/// detached HEAD; and a third with a type change, an addition, a deletion and a first-parent merge.
final class GitParsersTests: XCTestCase {
    enum Recorded {
        static let status = "# branch.oid 8c55745e219a449f587bbd4ad476d0f376670a0d\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +1 -0\01 .D N... 100644 100644 000000 825c32f0d03d98995ebe3e6d797f14daf2df51d9 825c32f0d03d98995ebe3e6d797f14daf2df51d9 CHANGELOG.md\01 .M N... 100644 100644 100644 677273046bce3115f56c248238f3b83f77cfc239 677273046bce3115f56c248238f3b83f77cfc239 logo.png\02 R. N... 100644 100644 100644 3367afdbbf91e638efe983616377c60477cc6612 3367afdbbf91e638efe983616377c60477cc6612 R100 new.txt\0old.txt\01 .M N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb src/lib/db.ts\01 MM N... 100644 100644 100644 d68dd4031d2ad5b7a3829ad7df6635e27a7daa22 6fe8acc87876b59a7c33d8f122933869f19f39c4 src/routes/billing.ts\0? notes.md\0? tests/\0! debug.log\0! node_modules/\0"
        static let unstagedNumstat = "0\t1\tCHANGELOG.md\0-\t-\tlogo.png\01\t0\tsrc/lib/db.ts\01\t0\tsrc/routes/billing.ts\0"
        static let stagedNumstat = "0\t0\t\0old.txt\0new.txt\02\t1\tsrc/routes/billing.ts\0"
        static let unstagedDiff = "diff --git a/src/routes/billing.ts b/src/routes/billing.ts\nindex 6fe8acc..91ac79b 100644\n--- a/src/routes/billing.ts\n+++ b/src/routes/billing.ts\n@@ -3,3 +3,4 @@ B\n c\n d\n e\n+f\n"
        static let stagedDiff = "diff --git a/src/routes/billing.ts b/src/routes/billing.ts\nindex d68dd40..6fe8acc 100644\n--- a/src/routes/billing.ts\n+++ b/src/routes/billing.ts\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n d\n+e\n"
        static let renameDiff = "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n"
        static let binaryDiff = "diff --git a/logo.png b/logo.png\nindex 6772730..542a00c 100644\nBinary files a/logo.png and b/logo.png differ\n"
        static let binaryStat = " logo.png | Bin 6 -> 11 bytes\n 1 file changed, 0 insertions(+), 0 deletions(-)\n"
        static let deletedDiff = "diff --git a/CHANGELOG.md b/CHANGELOG.md\ndeleted file mode 100644\nindex 825c32f..0000000\n--- a/CHANGELOG.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-# Changelog\n"
        static let wholeDiff = "diff --git a/CHANGELOG.md b/CHANGELOG.md\ndeleted file mode 100644\nindex 825c32f..0000000\n--- a/CHANGELOG.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-# Changelog\ndiff --git a/logo.png b/logo.png\nindex 6772730..542a00c 100644\nBinary files a/logo.png and b/logo.png differ\ndiff --git a/src/lib/db.ts b/src/lib/db.ts\nindex 587be6b..b77b4eb 100644\n--- a/src/lib/db.ts\n+++ b/src/lib/db.ts\n@@ -1 +1,2 @@\n x\n+y\ndiff --git a/src/routes/billing.ts b/src/routes/billing.ts\nindex 6fe8acc..91ac79b 100644\n--- a/src/routes/billing.ts\n+++ b/src/routes/billing.ts\n@@ -3,3 +3,4 @@ B\n c\n d\n e\n+f\n"
        static let log = "8c55745e219a449f587bbd4ad476d0f376670a0d\u{1F}7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760003600\u{1F}HEAD -> main, tag: v2.4.0, tag: v1, feat/webhook\u{1F}Keep the retry queue bounded\u{1F}Body line one.\nBody line two.\n\0\n7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8\u{1F}\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}origin/main\u{1F}Initial billing route\u{1F}\0\n"
        static let show = "8c55745e219a449f587bbd4ad476d0f376670a0d\u{1F}7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760003600\u{1F}HEAD -> main, tag: v2.4.0, tag: v1, feat/webhook\u{1F}Keep the retry queue bounded\u{1F}Body line one.\nBody line two.\n\0\0\n1\t0\tsrc/routes/billing.ts\0"
        static let showInitial = "7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8\u{1F}\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}origin/main\u{1F}Initial billing route\u{1F}\0\0\n2\t0\t.gitignore\01\t0\tCHANGELOG.md\0-\t-\tlogo.png\01\t0\told.txt\01\t0\tsrc/lib/db.ts\03\t0\tsrc/routes/billing.ts\0"
        static let refs = "refs/heads/feat/webhook\t8c55745e219a449f587bbd4ad476d0f376670a0d\t \t\nrefs/heads/main\t8c55745e219a449f587bbd4ad476d0f376670a0d\t*\t\nrefs/remotes/origin/main\t7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8\t \t\nrefs/tags/v1\t8c55745e219a449f587bbd4ad476d0f376670a0d\t \t\nrefs/tags/v2.4.0\tc7c63c6c5a782e911e9bf0c7591d852c6f792168\t \t8c55745e219a449f587bbd4ad476d0f376670a0d\n"
        static let initial = "# branch.oid (initial)\0# branch.head main\0"
        static let showRename = "b0460ac5b3016c79374a38f5c53b229b6c6a72be\u{1F}399f484a62af678b8a979612e5c7259b998be551\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> side\u{1F}side change\u{1F}\0\0\n1\t1\ta.txt\00\t0\t\0sp ace.txt\0moved é.txt\0"
        static let showRenameDiff = "diff --git a/sp ace.txt b/moved é.txt\nsimilarity index 100%\nrename from sp ace.txt\nrename to moved é.txt\n"
        static let conflict = "# branch.oid 8da878bb4e482918a048afc11d88d4f48e860ffc\0# branch.head main\02 R. N... 100644 100644 100644 2fa992c0b8b5c6acd2bdd4fa31de29d29799bdd5 2fa992c0b8b5c6acd2bdd4fa31de29d29799bdd5 R100 moved é.txt\0sp ace.txt\0u UU N... 100644 100644 100644 100644 814f4a422927b82f5f8a43f8fab6d3839e3983f2 2ea288144e4e628a6f6817790c6bc433f206fcd7 53447347c2f1b3c8bbeb1af0d33a2a25b6a512a8 a.txt\0"
        static let ccDiff = "diff --cc a.txt\nindex 2ea2881,5344734..0000000\n--- a/a.txt\n+++ b/a.txt\n@@@ -1,2 -1,2 +1,6 @@@\n  one\n++<<<<<<< HEAD\n +main\n++=======\n+ side\n++>>>>>>> side\n"
        static let showMerge = "451faed91e84200e696ec548ae874a1e35f1690f\u{1F}8da878bb4e482918a048afc11d88d4f48e860ffc b0460ac5b3016c79374a38f5c53b229b6c6a72be\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> main\u{1F}Merge branch side\u{1F}\0\0\01\t1\ta.txt\00\t0\t\0sp ace.txt\0moved é.txt\0"
        static let quotedDiff = "diff --git \"a/say \\\"hi\\\".txt\" \"b/say \\\"hi\\\".txt\"\nindex bca70f3..d169a2f 100644\n--- \"a/say \\\"hi\\\".txt\"\t\n+++ \"b/say \\\"hi\\\".txt\"\t\n@@ -1 +1 @@\n-q\n+q2\n"
        static let detachedLog = "8da878bb4e482918a048afc11d88d4f48e860ffc\u{1F}399f484a62af678b8a979612e5c7259b998be551\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD\u{1F}main change\u{1F}\0\n"
        static let detached = "# branch.oid 8da878bb4e482918a048afc11d88d4f48e860ffc\0# branch.head (detached)\0"
        // A third repository: a commit that modifies, deletes, turns a file into a symlink, adds a binary and renames, then
        // a merge whose second parent added s.txt; `show` and `diff` with --numstat or --name-status, each -z.
        static let showLettersNumstat = "b542f9a5b890b4843607ab68c7befe781be80e68\u{1F}81fe8edadf5e29a63e381cc9a54ae37f4767c427\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> main\u{1F}Add the logo, drop gone.txt\u{1F}\0\0\n1\t0\ta.txt\00\t1\tgone.txt\01\t1\tlink\0-\t-\tlogo.png\00\t0\t\0sp ace.txt\0moved é.txt\0"
        static let showLetters = "b542f9a5b890b4843607ab68c7befe781be80e68\u{1F}81fe8edadf5e29a63e381cc9a54ae37f4767c427\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> main\u{1F}Add the logo, drop gone.txt\u{1F}\0\0\nM\0a.txt\0D\0gone.txt\0T\0link\0A\0logo.png\0R100\0sp ace.txt\0moved é.txt\0"
        static let mergeNumstat = "3ba89417dc5db6803f441ebaf181aff1a6c4bc86\u{1F}b542f9a5b890b4843607ab68c7befe781be80e68 47dbb20a94eba4d29538662fa9cf4dd761a785c0\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> main\u{1F}Merge branch side\u{1F}\0\0\01\t0\ta.txt\01\t0\ts.txt\0"
        static let mergeShowLetters = "3ba89417dc5db6803f441ebaf181aff1a6c4bc86\u{1F}b542f9a5b890b4843607ab68c7befe781be80e68 47dbb20a94eba4d29538662fa9cf4dd761a785c0\u{1F}Ivan\u{1F}ivan@example.com\u{1F}1760000000\u{1F}HEAD -> main\u{1F}Merge branch side\u{1F}\0\0\0MM\0a.txt\0"
        static let mergeDiffLetters = "M\0a.txt\0A\0s.txt\0"
    }

    func testPorcelainReadsBranchHeadersAndEveryEntryKind() {
        let status = GitParsers.porcelain(Recorded.status)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.head, "8c55745e219a449f587bbd4ad476d0f376670a0d")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.changes, [
            GitChange(path: "CHANGELOG.md", kind: .deleted, area: .unstaged),
            GitChange(path: "logo.png", kind: .modified, area: .unstaged),
            GitChange(path: "new.txt", oldPath: "old.txt", kind: .renamed, area: .staged),
            GitChange(path: "src/lib/db.ts", kind: .modified, area: .unstaged),
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged),
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .unstaged),
            GitChange(path: "notes.md", kind: .untracked, area: .untracked),
            GitChange(path: "tests/", kind: .untracked, area: .untracked),
        ])
        XCTAssertEqual(status.ignored, ["debug.log", "node_modules/"])
        XCTAssertEqual(status.changes.first { $0.path == "tests/" }?.name, "tests")
    }

    func testPorcelainReadsConflictsRenamedNamesAndEmptyOrDetachedHeads() {
        let conflict = GitParsers.porcelain(Recorded.conflict)
        XCTAssertEqual(conflict.changes, [
            GitChange(path: "moved é.txt", oldPath: "sp ace.txt", kind: .renamed, area: .staged),
            GitChange(path: "a.txt", kind: .conflicted, area: .unstaged),
        ])
        let initial = GitParsers.porcelain(Recorded.initial)
        XCTAssertNil(initial.head, "Before the first commit HEAD has no hash")
        XCTAssertEqual(initial.branch, "main")
        XCTAssertEqual(initial.changes, [])
        let detached = GitParsers.porcelain(Recorded.detached)
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, "8da878bb4e482918a048afc11d88d4f48e860ffc")
    }

    func testPorcelainCutByTheBoundDropsItsLastEntry() {
        let cut = String(Recorded.status.prefix(Recorded.status.count - 6))
        let status = GitParsers.porcelain(cut)
        XCTAssertEqual(status.ignored, ["debug.log"], "The cut entry (\"! node_m…\") is not read as a name")
        XCTAssertEqual(GitParsers.porcelain("").changes, [])
    }

    /// `log --pretty=raw`: which commits carry a signature header, and its kind; a message line can't pose as one.
    func testRawLogNamesSignedCommitsAndTheirKind() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let raw = """
        commit \(a)
        tree 1111111111111111111111111111111111111111
        author P <p@x> 1 +0000
        committer P <p@x> 1 +0000
        gpgsig -----BEGIN PGP SIGNATURE-----
         
         iQEzBAABCAAdFiEE
         -----END PGP SIGNATURE-----

            Signed with gpg

        commit \(b)
        tree 1111111111111111111111111111111111111111
        gpgsig -----BEGIN SSH SIGNATURE-----
         U1NIU0lH
         -----END SSH SIGNATURE-----

            Signed with ssh

        commit \(c)
        tree 1111111111111111111111111111111111111111

            gpgsig -----BEGIN PGP SIGNATURE----- in a message is not a header
        """
        let headers = GitParsers.rawHeaders(raw)
        XCTAssertEqual(headers.compactMapValues(\.signature), [a: .gpg, b: .ssh])
        XCTAssertEqual(headers[a]?.author, GitPerson(name: "P", email: "p@x", date: Date(timeIntervalSince1970: 1), zone: "+0000"))
        XCTAssertNil(headers[c]?.author, "no author header")
    }

    /// The raw headers' author and committer: name, email, time and the offset git wrote, a name with `<` in it too.
    func testRawLogReadsTheAuthorAndCommitterWithTheirOffsets() {
        let a = String(repeating: "a", count: 40)
        let raw = """
        commit \(a)
        tree 1111111111111111111111111111111111111111
        parent 2222222222222222222222222222222222222222
        author Robin Example <robin@example.com> 1792349447 +0200
        committer GitHub <noreply@github.com> 1792363575 -0730

            Merge pull request #12
        """
        let headers = GitParsers.rawHeaders(raw)[a]
        XCTAssertEqual(headers?.author, GitPerson(name: "Robin Example", email: "robin@example.com",
                                                  date: Date(timeIntervalSince1970: 1792349447), zone: "+0200"))
        XCTAssertEqual(headers?.committer, GitPerson(name: "GitHub", email: "noreply@github.com",
                                                     date: Date(timeIntervalSince1970: 1792363575), zone: "-0730"))
        XCTAssertEqual(GitParsers.person("a <b> <c@d> 5 +0100")?.name, "a <b>")
        XCTAssertNil(GitParsers.person("Nobody <n@x>"), "no time")
        XCTAssertNil(GitParsers.person("Nobody <n@x> 5 0100"), "no sign on the offset")

        var commit = GitCommit(hash: a, parents: [], subject: "", body: "", author: "Robin Example", email: "robin@example.com",
                               date: Date(timeIntervalSince1970: 1792349447), refs: [])
        XCTAssertNil(commit.distinctCommitter, "not read yet")
        commit.committer = headers?.author
        XCTAssertNil(commit.distinctCommitter, "the author committed it then")
        commit.committer?.date = Date(timeIntervalSince1970: 1792363575)
        XCTAssertEqual(commit.distinctCommitter?.name, "Robin Example", "committed later: rebased or amended")
        commit.committer = headers?.committer
        XCTAssertEqual(commit.distinctCommitter?.name, "GitHub")
    }

    /// `verify-commit --raw`: gpg's status lines (as this Mac's gpg 2.5 printed them) and ssh-keygen's words.
    func testSignatureChecksReadGpgAndSshVerdicts() {
        let good = """
        [GNUPG:] NEWSIG sam@example.com
        [GNUPG:] KEY_CONSIDERED 0123456789ABCDEF0123456789ABCDEF89ABCDEF 0
        [GNUPG:] GOODSIG 0123456789ABCDEF Sam Example <sam@example.com>
        [GNUPG:] VALIDSIG 0123456789ABCDEF0123456789ABCDEF89ABCDEF 2026-10-18 1792363575 0 4 0 22 10 00 0123456789ABCDEF0123456789ABCDEF89ABCDEF
        [GNUPG:] TRUST_ULTIMATE 0 pgp sam@example.com
        """
        let check = GitParsers.signatureCheck(good, status: 0)
        XCTAssertEqual(check, GitSignatureCheck(verdict: .good(certified: true), kind: .gpg,
                                                signer: "Sam Example <sam@example.com>",
                                                key: "0123456789ABCDEF0123456789ABCDEF89ABCDEF"))
        XCTAssertEqual(GitSignatureText.short(check), "Signed")
        XCTAssertEqual(GitSignatureText.detail(check, kind: .gpg),
                       "Sam Example <sam@example.com> · GPG key ID: 0123456789ABCDEF0123456789ABCDEF89ABCDEF")
        XCTAssertEqual(GitSignatureText.detail(nil, kind: .gpg), "Checking the GPG signature…")
        XCTAssertEqual(GitSignatureText.short(nil), "Signed")
        var uncertified = check
        uncertified.verdict = .good(certified: false)
        XCTAssertEqual(GitSignatureText.detail(uncertified, kind: .gpg),
                       "Good GPG signature, key not certified · Sam Example <sam@example.com> · GPG key ID: 0123456789ABCDEF0123456789ABCDEF89ABCDEF")
        XCTAssertEqual(GitSignatureText.detail(GitSignatureCheck(verdict: .good(certified: true)), kind: .gpg), "Good GPG signature")
        XCTAssertEqual(GitParsers.signatureCheck(good.replacingOccurrences(of: "TRUST_ULTIMATE", with: "TRUST_UNDEFINED"),
                                                 status: 0).verdict, .good(certified: false))
        XCTAssertEqual(GitParsers.signatureCheck("[GNUPG:] NEWSIG\n[GNUPG:] BADSIG 0123456789ABCDEF Sam <s@x>", status: 1).verdict, .bad)
        XCTAssertEqual(GitParsers.signatureCheck("[GNUPG:] ERRSIG 0123456789ABCDEF 22 10 00 1 9 -\n[GNUPG:] NO_PUBKEY 0123456789ABCDEF",
                                                 status: 1),
                       GitSignatureCheck(verdict: .unknownKey, kind: .gpg, key: "0123456789ABCDEF"))
        XCTAssertEqual(GitParsers.signatureCheck("[GNUPG:] EXPKEYSIG 6978 Sam <s@x>", status: 1).verdict, .expiredKey)
        XCTAssertEqual(GitParsers.signatureCheck("[GNUPG:] REVKEYSIG 6978 Sam <s@x>", status: 1).verdict, .revokedKey)

        let ssh = GitParsers.signatureCheck("Good \"git\" signature for sam@x.com with ED25519 key SHA256:abcDEF", status: 0)
        XCTAssertEqual(ssh, GitSignatureCheck(verdict: .good(certified: true), kind: .ssh, signer: "sam@x.com", key: "SHA256:abcDEF"))
        XCTAssertEqual(GitParsers.signatureCheck("No principal matched.", status: 1).verdict, .unknownKey)
        XCTAssertEqual(GitParsers.signatureCheck("", status: 1).verdict, .unsigned)
        let unchecked = GitParsers.signatureCheck("error: cannot run /nonexistent: No such file or directory", status: 1)
        XCTAssertEqual(unchecked.verdict, .unchecked("cannot run /nonexistent: No such file or directory"))
        XCTAssertEqual(GitSignatureText.short(unchecked), "Unverified")
        XCTAssertEqual(GitSignatureText.detail(unchecked, kind: .gpg),
                       "Signed with GPG · couldn’t check: cannot run /nonexistent: No such file or directory")
        XCTAssertEqual(GitSignatureText.detail(ssh, kind: .gpg), "sam@x.com · SSH key: SHA256:abcDEF", "the check's own kind")
        XCTAssertEqual(GitSignatureText.short(GitSignatureCheck(verdict: .bad)), "Bad signature")
    }

    /// A commit's file for Source: the new side of its one-hunk patch, without the removed lines or git's markers.
    func testNewSideReadsTheWholeFileFromAOneHunkPatch() {
        let patch = "diff --git a/a.ts b/a.ts\nindex 1..2 100644\n--- a/a.ts\n+++ b/a.ts\n@@ -1,3 +1,3 @@\n keep\n-gone\n+new\n"
            + " +plus kept\n"
        XCTAssertEqual(GitParsers.newSide(patch), "keep\nnew\n+plus kept\n")
        let noNewline = "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"
        XCTAssertEqual(GitParsers.newSide(noNewline), "new")
        XCTAssertEqual(GitParsers.newSide("@@ -0,0 +1,2 @@\n+a\n+b\n"), "a\nb\n", "an added file")
        XCTAssertNil(GitParsers.newSide("diff --git a/x b/x\nold mode 100644\nnew mode 100755\n"), "a mode change has no lines")
        XCTAssertNil(GitParsers.newSide("Binary files a/x and b/x differ\n"))
    }

    func testNumstatReadsCountsBinariesAndRenames() {
        XCTAssertEqual(GitParsers.numstat(Recorded.unstagedNumstat), [
            GitNumstat(path: "CHANGELOG.md", additions: 0, deletions: 1),
            GitNumstat(path: "logo.png", additions: nil, deletions: nil),
            GitNumstat(path: "src/lib/db.ts", additions: 1, deletions: 0),
            GitNumstat(path: "src/routes/billing.ts", additions: 1, deletions: 0),
        ])
        XCTAssertTrue(GitParsers.numstat(Recorded.unstagedNumstat)[1].binary)
        XCTAssertEqual(GitParsers.numstat(Recorded.stagedNumstat), [
            GitNumstat(path: "new.txt", oldPath: "old.txt", additions: 0, deletions: 0),
            GitNumstat(path: "src/routes/billing.ts", additions: 2, deletions: 1),
        ])
    }

    func testLogReadsRecordsDecorationsAndBodies() throws {
        let commits = GitParsers.log(Recorded.log)
        XCTAssertEqual(commits.map(\.hash), ["8c55745e219a449f587bbd4ad476d0f376670a0d", "7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8"])
        let head = try XCTUnwrap(commits.first)
        XCTAssertEqual(head.parents, ["7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8"])
        XCTAssertEqual(head.subject, "Keep the retry queue bounded")
        XCTAssertEqual(head.body, "Body line one.\nBody line two.", "The body loses git's trailing newline only")
        XCTAssertEqual(head.author, "Ivan")
        XCTAssertEqual(head.email, "ivan@example.com")
        XCTAssertEqual(head.date, Date(timeIntervalSince1970: 1_760_003_600))
        XCTAssertEqual(head.short, "8c55745")
        XCTAssertEqual(head.refs, [
            GitRef(name: "main", kind: .branch, current: true),
            GitRef(name: "v2.4.0", kind: .tag, current: false),
            GitRef(name: "v1", kind: .tag, current: false),
            GitRef(name: "feat/webhook", kind: .branch, current: false),
        ])
        XCTAssertEqual(commits[1].parents, [], "The root commit has no parents")
        XCTAssertEqual(commits[1].body, "")
        XCTAssertEqual(commits[1].refs, [GitRef(name: "origin/main", kind: .branch, current: false)],
                       "A plain name is a branch until for-each-ref says otherwise")
        XCTAssertEqual(GitParsers.log(Recorded.detachedLog).first?.refs, [GitRef(name: "HEAD", kind: .head, current: true)])
        XCTAssertEqual(GitParsers.log(String(Recorded.log.dropLast(30))).count, 1, "A record the bound cut is dropped")
        XCTAssertEqual(GitParsers.decorations("HEAD -> main, origin/main, origin/HEAD").map(\.name), ["main", "origin/main"],
                       "A remote's HEAD only repeats its default branch")
        XCTAssertEqual(GitParsers.decorations("grafted, replaced, refs/stash, refs/notes/commits, feat/x").map(\.name), ["feat/x"],
                       "Grafts, replacements and full names are not branches")
    }

    func testLogRecordsCannotBeForgedOrShifted() throws {
        let hash = "8c55745e219a449f587bbd4ad476d0f376670a0d", parent = "7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8"
        func record(_ fields: [String]) -> String { fields.joined(separator: "\u{1F}") + "\0\n" }
        // A body holding the old record end and a whole record of its own is still one commit's body.
        let fake = "\u{1E}\n" + [parent, "", "Mallory", "m@example.com", "1760009999", "HEAD -> main", "Release", ""]
            .joined(separator: "\u{1F}") + "\u{1E}\n"
        let forged = GitParsers.log(record([hash, parent, "Ivan", "ivan@example.com", "1760000000", "", "Fix", "Body" + fake]))
        XCTAssertEqual(forged.map(\.hash), [hash])
        XCTAssertEqual(try XCTUnwrap(forged.first).body, ("Body" + fake).trimmingCharacters(in: .newlines))
        XCTAssertEqual(forged.first?.parents, [parent])

        // Fields out of place (a name holding 0x1f) or not what git prints: no commit rather than a wrong one.
        let good = [hash, parent, "Ivan", "ivan@example.com", "1760000000", "", "Fix", ""]
        XCTAssertEqual(GitParsers.log(record(good)).count, 1)
        for (index, value) in [(0, "8c55745"), (0, "--all"), (0, String(repeating: "\u{FF10}", count: 40)), (1, "HEAD~1"),
                               (1, parent + " 7b984b7"), (4, "1e9"), (4, "nan"), (4, "Ivan")] {
            var fields = good
            fields[index] = value
            XCTAssertEqual(GitParsers.log(record(fields)), [], "\(index): \(value)")
        }
        var shifted = good
        shifted[2] = "Iv\u{1F}an"
        XCTAssertEqual(GitParsers.log(record(shifted)), [], "A separator in the name moves the date out of place")
        XCTAssertEqual(GitParsers.log(record(good) + record(good.map { $0 == hash ? parent : $0 == parent ? "" : $0 })).count, 2)
    }

    func testRefsClassifyDecorationsAndAddWhatTheyLeftOut() {
        let records = GitParsers.refs(Recorded.refs)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[1], GitRefRecord(refname: "refs/heads/main", hash: "8c55745e219a449f587bbd4ad476d0f376670a0d", head: true))
        XCTAssertEqual(records.compactMap(\.ref).map(\.kind), [.branch, .branch, .remote, .tag, .tag])
        XCTAssertEqual(GitRefRecord(refname: "refs/remotes/origin/HEAD", hash: "1", head: false).ref, nil)

        let merged = GitRefs.merge(GitParsers.log(Recorded.log), refs: records)
        XCTAssertEqual(merged[1].refs, [GitRef(name: "origin/main", kind: .remote, current: false)])
        XCTAssertEqual(merged[0].refs.filter(\.current).map(\.name), ["main"])
        // A decoration filter (log.excludeDecoration) left v1 out: for-each-ref puts it back.
        var bare = GitParsers.log(Recorded.log)
        bare[0].refs = [GitRef(name: "main", kind: .branch, current: true)]
        XCTAssertEqual(GitRefs.merge(bare, refs: records)[0].refs.map(\.name), ["main", "feat/webhook", "v1", "v2.4.0"],
                       "An annotated tag is placed by the commit it peels to")
        XCTAssertEqual(records[4].hash, "8c55745e219a449f587bbd4ad476d0f376670a0d")
        XCTAssertEqual(GitParsers.refs("refs/heads/main\t8c55745e219a449f587bbd4ad476d0f376670a0d\t*\n"), [],
                       "A line without the peeled field is not this format's")
    }

    func testCommitDetailReadsTheRecordAndItsFiles() throws {
        let detail = try XCTUnwrap(GitParsers.commitDetail(Recorded.show))
        XCTAssertEqual(detail.commit.subject, "Keep the retry queue bounded")
        XCTAssertEqual(detail.files, [GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged, additions: 1, deletions: 0)])
        let initial = try XCTUnwrap(GitParsers.commitDetail(Recorded.showInitial))
        XCTAssertEqual(initial.files.map(\.path), [".gitignore", "CHANGELOG.md", "logo.png", "old.txt", "src/lib/db.ts", "src/routes/billing.ts"])
        XCTAssertEqual(initial.files[2].binary, true)
        XCTAssertNil(initial.files[2].additions)
        let rename = try XCTUnwrap(GitParsers.commitDetail(Recorded.showRename))
        XCTAssertEqual(rename.files[1], GitChange(path: "moved é.txt", oldPath: "sp ace.txt", kind: .renamed, area: .staged,
                                                  additions: 0, deletions: 0))
        let merge = try XCTUnwrap(GitParsers.commitDetail(Recorded.showMerge))
        XCTAssertEqual(merge.commit.parents.count, 2)
        XCTAssertEqual(merge.files.map(\.path), ["a.txt", "moved é.txt"], "A merge's counts follow an extra NUL")
        XCTAssertNil(GitParsers.commitDetail(""))
    }

    func testCommitDetailTakesEachFilesLetterFromNameStatus() throws {
        let letters = GitParsers.commitNameStatus(Recorded.showLetters)
        XCTAssertEqual(letters, [
            GitNameStatus(path: "a.txt", kind: .modified), GitNameStatus(path: "gone.txt", kind: .deleted),
            GitNameStatus(path: "link", kind: .typeChanged), GitNameStatus(path: "logo.png", kind: .added),
            GitNameStatus(path: "moved é.txt", oldPath: "sp ace.txt", kind: .renamed),
        ])
        let detail = try XCTUnwrap(GitParsers.commitDetail(Recorded.showLettersNumstat, letters: letters))
        XCTAssertEqual(detail.files, [
            GitChange(path: "a.txt", kind: .modified, area: .staged, additions: 1, deletions: 0),
            GitChange(path: "gone.txt", kind: .deleted, area: .staged, additions: 0, deletions: 1),
            GitChange(path: "link", kind: .typeChanged, area: .staged, additions: 1, deletions: 1),
            GitChange(path: "logo.png", kind: .added, area: .staged, binary: true),
            GitChange(path: "moved é.txt", oldPath: "sp ace.txt", kind: .renamed, area: .staged, additions: 0, deletions: 0),
        ])
        // Without letters numstat alone guesses: a pair is a rename, anything else a change.
        let guessed = try XCTUnwrap(GitParsers.commitDetail(Recorded.showLettersNumstat))
        XCTAssertEqual(guessed.files.map(\.kind), [.modified, .modified, .modified, .modified, .renamed])

        // A merge: show's combined letters cover only a.txt (first parent's letter read); diff against the first parent
        // names s.txt as added, as the counts do.
        XCTAssertEqual(GitParsers.commitNameStatus(Recorded.mergeShowLetters), [GitNameStatus(path: "a.txt", kind: .modified)])
        let merge = try XCTUnwrap(GitParsers.commitDetail(Recorded.mergeNumstat,
                                                          letters: GitParsers.nameStatus(Recorded.mergeDiffLetters)))
        XCTAssertEqual(merge.files.map(\.path), ["a.txt", "s.txt"])
        XCTAssertEqual(merge.files.map(\.kind), [.modified, .added])

        // Cut short by the bound: the incomplete last entry is dropped, not misread.
        XCTAssertEqual(GitParsers.nameStatus("M\0a.txt\0R100\0old.txt\0"), [GitNameStatus(path: "a.txt", kind: .modified)])
        XCTAssertEqual(GitParsers.nameStatus(""), [])
        XCTAssertEqual(GitParsers.commitNameStatus(""), [])
    }

    func testDiffSplitterNamesEachFileAndKeepsItsText() throws {
        let whole = GitParsers.diffs(Recorded.wholeDiff)
        XCTAssertEqual(whole.map(\.path), ["CHANGELOG.md", "logo.png", "src/lib/db.ts", "src/routes/billing.ts"])
        XCTAssertEqual(whole.map(\.binary), [false, true, false, false])
        XCTAssertEqual(whole.map(\.text).joined(), Recorded.wholeDiff, "Every line belongs to exactly one file")
        XCTAssertEqual(whole[0].oldPath, nil, "A deleted file keeps its own name")
        XCTAssertTrue(whole[3].text.hasPrefix("diff --git a/src/routes/billing.ts"))

        let staged = try XCTUnwrap(GitParsers.diffs(Recorded.stagedDiff).first)
        XCTAssertEqual(staged.text, Recorded.stagedDiff)
        XCTAssertFalse(staged.truncated)
        XCTAssertTrue(try XCTUnwrap(GitParsers.diffs(Recorded.unstagedDiff, truncated: true).last).truncated)

        let rename = try XCTUnwrap(GitParsers.diffs(Recorded.renameDiff).first)
        XCTAssertEqual(rename.path, "new.txt")
        XCTAssertEqual(rename.oldPath, "old.txt")
        let spaced = try XCTUnwrap(GitParsers.diffs(Recorded.showRenameDiff).first)
        XCTAssertEqual(spaced.path, "moved é.txt")
        XCTAssertEqual(spaced.oldPath, "sp ace.txt")

        let quoted = try XCTUnwrap(GitParsers.diffs(Recorded.quotedDiff).first)
        XCTAssertEqual(quoted.path, "say \"hi\".txt")
        XCTAssertNil(quoted.oldPath)
        let combined = try XCTUnwrap(GitParsers.diffs(Recorded.ccDiff).first)
        XCTAssertEqual(combined.path, "a.txt")
        XCTAssertEqual(combined.text, Recorded.ccDiff)
        XCTAssertEqual(GitParsers.diffs(""), [])
    }

    func testBinarySizesComeFromStat() throws {
        let sizes = try XCTUnwrap(GitParsers.binarySizes(Recorded.binaryStat))
        XCTAssertEqual(sizes.old, 6)
        XCTAssertEqual(sizes.new, 11)
        XCTAssertNil(GitParsers.binarySizes(" a.txt | 2 +-\n 1 file changed\n"))
        XCTAssertTrue(try XCTUnwrap(GitParsers.diffs(Recorded.binaryDiff).first).binary)
    }

    func testUnquoteDecodesGitsEscapes() {
        XCTAssertEqual(GitParsers.unquote("\"a\\tb\""), "a\tb")
        XCTAssertEqual(GitParsers.unquote("\"caf\\303\\251\""), "café")
        XCTAssertEqual(GitParsers.unquote("\"back\\\\slash\""), "back\\slash")
        XCTAssertEqual(GitParsers.unquote("plain name"), "plain name")
    }

    func testMarksFollowTheStatus() {
        let marks = GitMarks(GitParsers.porcelain(Recorded.status))
        XCTAssertEqual(marks.mark("src/routes/billing.ts", directory: false), "M", "Staged and unstaged: still M")
        XCTAssertEqual(marks.mark("src/lib/db.ts", directory: false), "M")
        XCTAssertEqual(marks.mark("new.txt", directory: false), "R")
        XCTAssertEqual(marks.mark("CHANGELOG.md", directory: false), "D")
        XCTAssertEqual(marks.mark("notes.md", directory: false), "U")
        XCTAssertEqual(marks.mark("tests", directory: true), "U", "A folder the status lists whole")
        XCTAssertEqual(marks.mark("tests/idempotency.test.ts", directory: false), "U", "Inside an untracked folder")
        XCTAssertEqual(marks.mark("node_modules", directory: true), "!")
        XCTAssertEqual(marks.mark("node_modules/x/y.js", directory: false), "!")
        XCTAssertEqual(marks.mark("debug.log", directory: false), "!")
        XCTAssertNil(marks.mark("src", directory: true), "A folder holding changes shows no mark")
        XCTAssertNil(marks.mark("src/routes", directory: true))
        XCTAssertNil(marks.mark("package.json", directory: false))
        XCTAssertEqual(GitMarks(GitParsers.porcelain(Recorded.conflict)).mark("a.txt", directory: false), "X")

        // An index addition modified again in the work tree is still new against HEAD; a work tree deletion wins.
        let both = GitPorcelain(changes: [GitChange(path: "a", kind: .added, area: .staged), GitChange(path: "a", kind: .modified, area: .unstaged),
                                          GitChange(path: "b", kind: .modified, area: .staged), GitChange(path: "b", kind: .deleted, area: .unstaged)])
        XCTAssertEqual(GitMarks(both).mark("a", directory: false), "A")
        XCTAssertEqual(GitMarks(both).mark("b", directory: false), "D")
    }
}
