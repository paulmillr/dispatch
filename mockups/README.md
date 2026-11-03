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
`simctl` cannot rotate and iPadOS refuses `requestGeometryUpdate`; `shoot.py rotate landscape` turns an iPhone the same way. Contact sheets come from `contact.swift`.

## Screens

**iPhone** (`Sources/`). A tab's header is B7, as the app ships it: Back with the needs-you count and the host's
glyph (the tab's menu) in one capsule on the left, the title two lines tall (host · folder under a title that fits one
line), and the mode button alone on the right. Most screens still draw the header before it, X9b: a round chevron
Back, the title block, and the host disc with a ⋯ badge, under the Terminal · Chat · Files capsule; inside Files the
system bottom tab bar carries Files · Review · Commits with the comment count on Review and Create review in the
accessory slot. Outside a git repository the bar has only Files and hides.

| Group | Screens |
|---|---|
| tab | H0 terminal, H1 files, H2 review, H3 commits |
| review | R2 diff with glass comment cards, R3 line selection with handles, R4 glass composer, R5 Create review sheet (R5b swipe to delete, R5c no agent in the tab) |
| pushed | F2 file preview, C2 commit detail |
| spaces | P1 Spaces tree with the filter row All · Needs you · Agents (P1b Needs you), Detached row per host, branch per space; P2 a space's tabs, titled as the Mac strip titles them with a line that follows the agent's state (P2b swipe to Close, which ends the tab, P2c menu: New tab, Edit, Detach, Terminate, P2d Edit renaming the space and its tabs, with reorder, P2e New tab held: Shell, Claude, Codex, Pi); P3 the switcher sheet from a tab's host disc |
| host | W0 Spaces tree with the host glyph as the stats button and the Offline group (W0b folded, W0c the filter menu); W1a the small stats sheet (stat strip and sparkline), W1b dragging up, W1c small and offline; W1 the large sheet by CPU, W2 by memory, W3 scrubbing; W5 disconnected, W6 plain SSH, W7 Low Power Mode |
| states | S1 no helper, S2 no grant, S3 offline, S4 review sent with Undo, S5 diff fold and outdated comment, S6d what the turn changed and when it ended in the agent bubble's corner |
| settings | G1 Settings; G2 terminal font; G3 chat font; G4 theme; G5 notifications |
| terminal | T1 search; T2 the key bar's menu with Clear screen |
| chat | C1 search; C2 slash commands; C3 side conversation; C4 goal strip (C4b Manage goal); C5 conversation mode; C6 Jump to latest |
| queue | The queue folded into the working row (`Sources/QueueRow.swift`), Stop beside the clock ("thinking · 38s ■"). Q1 "4 steps" and a pink queue capsule (glyph and count) before the chevron; Q1b tapped: the capsule lit, the card open under the row. Q6 no working row (paused after Stop): the queue's own line, with Resume |
| message | M1 an agent message's details (the app's M5b) redesigned: agent and time as the title, Copy · Reply · Share · Show in Terminal in the ⋯ menu, the whole message raw (Markdown unrendered, one selection), outcome and time as one line, Changes · Tokens with context · the conversation's model, and past 8 steps the steps folded (patches and failures stay; the runs between fold into a row with a disclosure; Show all); M1b a fold open in place, M1c a short turn (nothing folds), M1d a turn stopped by you |
| mode-host | One mode button instead of the capsule, as the Mac strip's (`ModeButton.swift`), shipped 2026-11-01 as the phone's only header: Back and the host share a capsule on the left, a system button-style Toggle alone on the right, on as the system draws a selected toggle (off in primary, not the app tint). B7 Chat shown, the bubble on; B7b an agent's tab in Terminal, the bubble off (tap → Chat); B7c the four states (a shell's tab in Terminal shows the folder off, tap → Files; Files shown, the folder on) |
| header | X9b, the header before B7: the round chevron Back, the title two lines tall, the host disc with a ⋯ badge that is the tab's menu |
| chat-icon | Y5: one secondary text bubble for every agent's chat, a shell's terminal glyph (shipped; every screen's default) |

**iPad** (`Sources/IPad.swift`, `PadStrip.swift`; the same target, landscape). The Mac's layout: a 320-point sidebar
holding the Spaces tree alone (sidebar toggle, title, filter menu and Edit on its bar row, New space in its footer),
and a detail column that opens with the space's tab strip (tab pills with state dot, glyph and title; "+"; the mode
switch Terminal · Chat · Files · Review · Commits as glyphs, the git two only inside a repository). Review and
Commits are a 360-point list beside a pane; the stats widget is a popover on the host glyph.

| Group | Screens |
|---|---|
| ipad | I1 files, I2 review (I2b before a selection), I3 commits (I3b before a selection), I4 chat, I5 host popover, I7 terminal, I8 sidebar hidden |
| ipad-half | I6 Split View at 507 points, which is the phone stack: files, and I6b spaces |

**iPhone on its side** (`Sources/FullHeight.swift`, `Landscape.swift`; an iPhone simulator turned by
`shoot.py rotate landscape`, then `shoot.py all landscape`). Height is the scarce axis (402 points on an iPhone 18
Pro, against 874 wide), so every point of it goes to the content: the chrome stands in one rail just inside the safe
area, on the Dynamic Island's side, as the app ships it (docs/ios.md, Landscape). The title is the content's first
lines.

| Group | Screens |
|---|---|
| onerail | Back with its count and the menu disc at the rail's top, the five modes stacked, the mode's action at its foot. L12 Chat: Reply is the pink button (attach and send options in the menu disc, dictation on the keyboard's mic), the thread right of the rail; L12b writing: the field alone, text and Send; L12c a draft kept: Reply marked. L13 Review: Create review at the foot with its count, search heading the list, Comment in the diff's header. L14 Terminal: every column right of the rail, the keyboard the rail's foot; L14b typing: the key row (Ctrl, Esc, Tab, Alt, arrows) rides the keyboard; L14c the keyboard button held: Esc, Ctrl-C, Ctrl-D, Tab, Previous command, Paste (Esc without the keyboard is two taps) |
| onerail (edge) | L15 Terminal and L15b Chat to the window's edge: iOS insets both sides 62 points for the Dynamic Island, which is on one side only; the rail stands on the island's side (50 points in, clear of it) and the content runs into the other side's inset to 12 points from the glass, Chat without its 600-point measure. Turned the other way, the rail moves to the right edge with the island |

**Apple Watch** (`Watch/`). The phone's row grammar and host strip at watch size.

| Group | Screens |
|---|---|
| watch | K1 Agents list (K1b scrolled), K2 thread, K3 approval, K4 question, K5 dictation reply, K6 host stats (K6b offline), K7 complication layouts as a note, K8 review sent with Undo |

## Decisions these screens carry

- Glyphs as the Mac: Chat `text.bubble`, Review `pencil.and.list.clipboard`, Commits `clock.arrow.circlepath`. Every
  agent's tab carries the Chat bubble in secondary (Y5), a shell the terminal glyph; the agent is not told apart by its
  mark. `agentIconStyle` defaults to it, so every screen draws what the app does.
- Agent tabs are titled by the conversation's title; the line under it is the current step and elapsed time while
  working, the question while waiting, the last message when done.
- Commits list after a History panel: one line per commit, a continuous two-colour graph, the merged span indented.
- Review comments are glass cards over an unbroken diff, with selection handles and a bottom glass composer; the
  review sheet has a To row, quoted lines, pinned actions, Preview, and Copy-only when the tab has no agent.
- Host stats are a Stocks-style strip (CPU %, memory GB, disk GB free) over one 15-minute sparkline; the small
  sheet offline shows the connection facts and Connect instead.
- Offline hosts gather under an Offline group as header rows only; the group folds and the filter menu can hide it.
- No flat Spaces list and no sort menu; the filter is All · Needs you · Agents.
- A chat turn's summary sits in its last agent bubble's corner, as a messenger's time: what it changed and when it
  ended ("3 files +127 −22 · 10:17"); every other reply, and a plain answer, has its time there; steps and duration
  stay in message details (S6d). While the agent works the working row tells the work.

Not drawn: markdown, image, folder and binary previews; listing empty and error states; transfers; renames, binary
rows and the no-newline marker in diffs; Source mode; editing a comment; lane folding and signature verdicts in
Commits; iPad keyboard shortcuts.

## Layout of this folder

`project.yml` (three targets: `Mockups` for iPhone and iPad, `MockupsRotate`, `MockupsWatch`; the `.xcodeproj` is
generated and ignored), `Sources/` (the iOS screens; `Chrome.swift` holds the shared pieces, `Data.swift` the
fictional repo and hosts), `Rotate/`, `Watch/`, `shoot.py`, `contact.swift`. Fictional data only: hosts `mba2`,
`studio`, `ai`; authors Alex Rivera, Sam Example, Priya Example.
