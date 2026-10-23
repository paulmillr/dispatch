# Design mockups

Static SwiftUI screens of the iPhone, iPad and Apple Watch apps as they are meant to become, shot in the simulator
so the chrome (Liquid Glass, bars, sheets) is the real thing. Every screen is fictional data in a throwaway app; none
of it ships, and nothing here is compiled into Dispatch. The screenshots are not tracked (`.gitignore`): render them.

    python3 mockups/shoot.py build phone        # XcodeGen, xcodebuild, install (phone | ipad | watch)
    python3 mockups/shoot.py H2-review          # one screen, dark and light → mockups/shots/
    python3 mockups/shoot.py all ipad           # every screen of a platform, then its contact sheets → mockups/sheets/
    python3 mockups/shoot.py list               # the screen ids by group

`build` needs the pinned XcodeGen (`scripts/setup-build-tools.py` fetches it) and a booted simulator whose name fits
the platform (iPhone, iPad, Apple Watch); without one it boots the newest available. `MOCKUPS_DEVICE` names another.
The iPad screens are landscape: `shoot.py rotate` runs the `MockupsRotate` UI test once per simulator boot, because
`simctl` cannot rotate and iPadOS refuses `requestGeometryUpdate`. Contact sheets come from `contact.swift`.

## Screens

**iPhone** (`Sources/`). The tab screen's switch is a glass capsule with glyph and title, Terminal · Chat · Files;
inside Files the system bottom tab bar carries Files · Review · Commits with the comment count on Review and Create
review in the accessory slot. Outside a git repository the bar has only Files and hides.

| Group | Screens |
|---|---|
| tab | H0 terminal, H1 files, H2 review, H3 commits |
| review | R2 diff with glass comment cards, R3 line selection with handles, R4 glass composer, R5 Create review sheet (R5b swipe to delete, R5c no agent in the tab) |
| pushed | F2 file preview, C2 commit detail |
| spaces | P1 Spaces tree with the filter row All · Needs you · Agents (P1b Needs you), Detached row per host, branch per space; P2 a space's tabs, titled as the Mac strip titles them with a line that follows the agent's state (P2b swipe Detach / Close, P2c menu, P2d Edit with reorder, P2e New tab held: Shell, Claude, Codex, Pi); P3 the switcher sheet from a tab's host disc |
| host | W0 Spaces tree with the host glyph as the stats button and the Offline group (W0b folded, W0c the filter menu); W1a the small stats sheet (stat strip and sparkline), W1b dragging up, W1c small and offline; W1 the large sheet by CPU, W2 by memory, W3 scrubbing; W4 Host details; W5 disconnected, W6 plain SSH, W7 Low Power Mode |
| states | S1 no helper, S2 no grant, S3 offline, S4 review sent with Undo, S5 diff fold and outdated comment, S6 the turn footnote in chat |
| settings | G1 Settings; G2 terminal font; G3 chat font; G4 theme; G5 notifications |
| terminal | T1 search; T2 the key bar's menu with Clear screen |
| chat | C1 search; C2 slash commands; C3 side conversation; C4 goal strip (C4b Manage goal); C5 conversation mode; C6 Jump to latest |

**iPad** (`Sources/IPad.swift`, `PadStrip.swift`; the same target, landscape). The Mac's layout: a 320-point sidebar
holding the Spaces tree alone (sidebar toggle, title, filter menu and Edit on its bar row, New space in its footer),
and a detail column that opens with the space's tab strip (tab pills with state dot, glyph and title; "+"; the mode
switch Terminal · Chat · Files · Review · Commits as glyphs, the git two only inside a repository). Review and
Commits are a 360-point list beside a pane; the stats widget is a popover on the host glyph.

| Group | Screens |
|---|---|
| ipad | I1 files, I2 review (I2b before a selection), I3 commits (I3b before a selection), I4 chat, I5 host popover, I7 terminal, I8 sidebar hidden |
| ipad-half | I6 Split View at 507 points, which is the phone stack: files, and I6b spaces |

**Apple Watch** (`Watch/`). The phone's row grammar and host strip at watch size.

| Group | Screens |
|---|---|
| watch | K1 Agents list (K1b scrolled), K2 thread, K3 approval, K4 question, K5 dictation reply, K6 host stats (K6b offline), K7 complication layouts as a note, K8 review sent with Undo |

## Decisions these screens carry

- Glyphs as the Mac: Chat `text.bubble`, Review `pencil.and.list.clipboard`, Commits `clock.arrow.circlepath`;
  agents by their marks (Claude's sparkle, Codex's angle brackets, Pi's π).
- Agent tabs are titled by the conversation's title; the line under it is the current step and elapsed time while
  working, the question while waiting, the last message when done.
- Commits list after a History panel: one line per commit, a continuous two-colour graph, the merged span indented.
- Review comments are glass cards over an unbroken diff, with selection handles and a bottom glass composer; the
  review sheet has a To row, quoted lines, pinned actions, Preview, and Copy-only when the tab has no agent.
- Host stats are a Stocks-style strip (CPU %, memory GB, disk GB free) over one 15-minute sparkline; the small
  sheet offline shows the connection facts and Connect instead.
- Offline hosts gather under an Offline group as header rows only; the group folds and the filter menu can hide it.
- No flat Spaces list and no sort menu; the filter is All · Needs you · Agents.

Not drawn: markdown, image, folder and binary previews; listing empty and error states; transfers; renames, binary
rows and the no-newline marker in diffs; Source mode; editing a comment; lane folding and signature verdicts in
Commits; iPad keyboard shortcuts.

## Layout of this folder

`project.yml` (three targets: `Mockups` for iPhone and iPad, `MockupsRotate`, `MockupsWatch`; the `.xcodeproj` is
generated and ignored), `Sources/` (the iOS screens; `Chrome.swift` holds the shared pieces, `Data.swift` the
fictional repo and hosts), `Rotate/`, `Watch/`, `shoot.py`, `contact.swift`. Fictional data only: hosts `mba2`,
`studio`, `ai`; authors Alex Rivera, Sam Example, Priya Example.
