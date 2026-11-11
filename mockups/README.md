# Design mockups

Static SwiftUI screens of the iPhone (the Duo too), iPad and Apple Watch apps as they are meant to become, shot in the simulator
so the chrome (Liquid Glass, bars, sheets) is the real thing. Every screen is fictional data in a throwaway app; none
of it ships, and nothing here is compiled into Dispatch. The screenshots are not tracked (`.gitignore`): render them.

    python3 mockups/shoot.py build phone        # XcodeGen, xcodebuild, install (phone | ipad | duo | watch)
    python3 mockups/shoot.py H2-review          # one screen, dark and light → mockups/shots/
    python3 mockups/shoot.py all ipad           # every screen of a platform, then its contact sheets → mockups/sheets/
    python3 mockups/shoot.py list               # the screen ids by group

`build` needs the pinned XcodeGen (`scripts/setup-build-tools.py` fetches it) and a booted simulator whose name fits
the platform (iPhone, iPad, iPhone Duo, Apple Watch); without one it boots the newest available. `MOCKUPS_DEVICE` names another.
The iPad screens are landscape: `shoot.py rotate` runs the `MockupsRotate` UI test once per simulator boot, because
`simctl` cannot rotate and iPadOS refuses `requestGeometryUpdate`; `shoot.py rotate landscape` turns an iPhone the same way. Contact sheets come from `contact.swift`.

The Mac's screens are a Swift package of their own, drawn offscreen with no simulator (Mac, below).

## Mac

`Mac/` draws the Mac app's screens: a SwiftUI kit of the main window's chrome and a renderer that draws each screen in
an offscreen window, so AppKit's own controls (toggles, fields, pickers, buttons) come out real and in their focused
look, in the app's accent, without taking focus or activating anything.

    python3 mockups/shoot.py mac list                          # ids, groups, titles
    python3 mockups/shoot.py K2-main-chat                      # one screen, dark and light → shots/mac/<id>-<theme>.png
    python3 mockups/shoot.py mac render --themes dark,nautical K2 --flat   # options: README below, or `mac` alone
    python3 mockups/shoot.py all mac                           # every screen, then sheets/mac-<group>-<theme>.png

`mac` builds the package first (incremental: about a second, then under a second a screen). Options: `--themes`
(dark, light, nautical), `--flat` (flat chrome; Liquid Glass is the app's default), `--font code`
(Same as code interface: Source Code Pro, the mockups' terminal font), `--size` (Settings › Font size, 14), `--scale`, `--out`, `--scheme "Catppuccin Latte"`
(the terminal and chat in a bundled scheme from `Vendor/Term/Resources/ghostty/themes` instead of dispatch-black,
without the theme's overrides, as the app does; the file name gains `-catppuccin-latte`; the glowing schemes, Root
Access, Red Alert and Bluescreen, get the terminal's phosphor pass, `PhosphorGlow` after `GlowShaders.swift`). A selector is an id, its part
before the first dash (`K2`), or a group.

**Drawn with the app's values, not copies.** `Mac/Sources/MacMockups/App/` links the app's `Chrome.swift` (every
theme's palette, `Chrome` metrics), `AppFont.swift` (typography roles, SF Rounded at Source Code Pro's size, line
heights), `HostTint.swift` (host colours), `TerminalFontScale.swift` and `ColorVision.swift`; `Shims.swift` stands in for
what they reach elsewhere, at the app's defaults. The terminal and chat colours come from `extras/ghostty/dispatch-black`
under the theme's overrides, as the app derives them. When one of those sources gains a dependency, the build names it:
add it to `Shims.swift`.

**The kit** (`Kit/`), at the app's defaults (content size 14, icons sidebar, flat order, git branches hidden, Liquid
Glass, chat in San Francisco, Settings › Tool steps at Current step):

| Piece | Draws |
|---|---|
| `DispatchWindow`, `MacWindow` | the main window (sidebar, divider, content) in a window with traffic lights and shadow |
| `Sidebar`, `SidebarTopRow`, `SpaceRow`, `NewSpaceCircle`, `NewSpaceRow` | the glass panel; the header row, icons only (sidebar toggle and tree toggle, then at the end the shortcuts and, in tree order, the New Space circle, ending at the rows' shortcuts; tight, the shortcuts go): no Spaces ⌄ / Tabs ⌄ menu, tabs only being gone; spaces (host disc, name, branch when a screen sets one, activity, ⇧⌘ shortcut), flat or by host (`tree`: each heading the host in capitals and its dimmed icon, centred under New Space; Local always listed); flat, "+ space" under the list, with "+ local" while a remote host is connected; the footer's hosts |
| `Pane`, `TabStrip`, `TabCell`, `Split` | a pane's strip: lone, the glass track and pill with the + circle and the mode · layout pill; in a split (`paneBadge`), one capsule holding the badge, tabs and buttons, and no ⌘N on the tabs; flat, an underline; leading the window (`titleRow`), the host mark or the sidebar toggle, and a lone tab's bare title; focus edge only where no badge shows; splits |
| `TerminalScreen`, `T`, `c` | a terminal in Source Code Pro with ANSI colours from the theme's scheme, a bar cursor at the prompt (`focused: false`: the hollow block); `.prompt(…)`, the zsh prompt from paulmillr/dotfiles (`app dark-mode* ❯`); `Sample.gitLog`, `.tests`, `.server` |
| `ChatPane`, `AgentBubble`, `ToolGroupHeader`, `ToolRow`, `ComposerCard` | the transcript grouped as the app's rows are: tool steps after an agent message join its bubble under the text, the message's time at the end of their header; other steps a bubble of their own; a reply after steps its own bubble. A group's steps show as Tool steps does by default (`live`: the newest group's current step alone; otherwise none), or `shown:` as opened; the reply placeholder (`.pending`). The composer: glass, its footer's model · effort, the agent's activity and Stop, Send (Queue while working), giving way as the footer narrows |
| `SheetOver`, `MacMenu`, `Callout` | a sheet over a window, an opaque menu, numbered notes for review |
| `PlainTerminalWindow`, `CapturedScreen`, `R` | another terminal app's window; a screen captured with `tmux capture-pane -e` (`Screens/Landing.swift`'s herdr) |
| `Hosts`, `Activity`, `Sample` | fictional hosts (local, studio, build-box, ai, staging), agent states, sample spaces/terminal/chat |

Real SwiftUI controls (`Toggle`, `TextField`, `Picker`, `Button`, `Form`) go straight into a screen. Materials and Liquid
Glass do not draw offscreen: glass surfaces are drawn as `GlassTone`'s tones, sampled from the app's capture as ColorSync
renders it into sRGB (`build/ui-audit/main-sidebar-*.png` carries the test VM display's profile: read it through a
`CGContext` in sRGB, not `NSColor.usingColorSpace`, which reads it lighter). The glass changes with macOS: after a
macOS update, take the capture again (below) and resample. `Mock.controlsInset` (where the title row's controls start)
is measured from the same capture.

**A new topic** is a file in `Mac/Sources/MacMockups/Screens/` with `static let screens: [Screen]`, listed in
`Screens.all` (`Screen.swift`). Start from `Reference.swift`'s screens (K0–K4); K9 redraws the app's own capture
(`build/ui-audit/main-sidebar-dark.png` from `MainMockupPresentationTests`) to check the kit against the app. Ids are a
letter and number, then a name; ones the iOS screens use cannot be reused. Once a design ships, delete its exploration
screens: the kit draws what shipped.

**The app's captures** to check against come from its presentation tests, run in the test VM (no host focus taken):
`python3 test/vm.py --vm NAME test MainMockupPresentationTests ChatToolGroupingTests ChatPresentationTests
FilesPresentationTests GitChangesPresentationTests GitCommitsPresentationTests` (more in `DispatchTests/*Presentation*`);
the PNGs land in the run's `build/vm-tests/<run>/build/` (`ui-audit`, `chat-group-validation`, `chat-footer-validation`,
`files-audit`, …). Check a capture's date against the app's commits before trusting it.

The landing page (dispatch.yachts, the `gh-pages` branch) uses K3, the `files` group (J1, J2b, J3) and the `landing`
group: L1 the terminal with the sidebar hidden, rendered once per scheme for the theme picker; L2 herdr in a plain
terminal and L3 the same session in Dispatch (branches shown, Settings › Show git branches on); L4 Claude Code in the
terminal and L5 the same session in Chat, its steps opened; L6 the theme creator, the app's own `ThemeMakerView` linked
into `App/` with the Themes sources it needs (`Shims.swift` stands in for Settings and the custom-scheme store). Shots
are cropped 80 pixels on each side to the window.

The `onboarding` group draws the first-launch setup sheet as it ships (LocalAgentsConsent, OnboardingPages.swift): O1
Chat, O2 Tabs, O3 Prefs, over a fresh install's window.

The `updates` group (`Screens/Updates.swift`) explores the updater's sheet in place of the "is ready" NSAlert: the
release notes' first five items (the version commit's body before its first `---` line, `* ` or `- ` items, `Area:
text` giving a coloured tag), one line each; U4a downloading (a ring round the tile and the footer's edge fill), U4b
verifying, U1 ready; U1b a short list, U2 the list in the terminal's colours, U3 the list in Settings › Updates.

The `ladder` group (`Screens/ModelLadder.swift`) explores the model and effort picker for an agent whose models are all
rungs of one family in a known order (haiku, sonnet, opus, fable; luna, terra, astra), in place of the two lists: E1
the popover over the composer's footer, model and effort as two tracks (a recessed groove filled up to a raised thumb,
a stop per choice), the family's security model (mythos, daybreak-blue) a switch under them, for this chat only; E2
today's lists beside it; E3 the popover's states (pointing, dragging, switching, a model without the effort's level,
the security model on, a failed switch, opened by keyboard, the other family); E4 the footer's model and effort, with
the security model's shield; E5 one track frame by frame: point, click, the choice translucent until the agent
confirms, the thumb held as a lens and dragged, arrow keys, a hatched stop the model lacks. A stroked `Capsule` comes
out offscreen with a flat nub at each end: `PillStroke` there draws the outline in a canvas instead.

The `limits` group (`Screens/ClaudeLimits.swift`) explores Claude's subscription limits in the popover the composer's
activity opens, read only as it opens and at most once a minute: D1 in the window, D2 three looks (rows, one line,
rings), D3 the states (before consent, reading, opened again within a minute, near the limit, one window reported,
nothing to report, no answer), D4 limits from a Pi extension the user installed (OpenCode Go, OpenRouter).

## Screens

**iPhone** (`Sources/`). A tab's header is the app's (`Sources/TitleCapsule.swift`): Back alone in its circle with the needs-you count,
beside it one capsule with the host's glyph on a disc of its colour, the title and host · folder under it (one line
each), which opens the tab's menu, and the mode button alone on the right (its glyph filled in the accent away from
Terminal). Every tab screen draws it: no switch sits under it, in Files neither: Files, Review and Commits are the
mode button's menu, its glyph the shown mode's (the folder, Review's clipboard, Commits' clock), the mode's own row
under the header, Create review a glass capsule at the bottom; there is no system tab bar. Branch names stand alone, without a glyph. Pushed screens
(a file, a commit, a side conversation) keep the back pill naming where it returns.

| Group | Screens |
|---|---|
| tab | H0 terminal (the program in the subtitle, the key bar), H1 files, H2 review, H3 commits: the shipped header, the mode button naming the Files mode; B8c the title capsule tapped: the tab's menu, Search, Stats, Side Conversation, then Tab: Rename…, Detach, Close Tab; B8d a long title, one line cut, host · folder kept |
| review | R2 diff with glass comment cards, R3 line selection with handles, R4 glass composer, R5 Create review sheet (R5b swipe to delete, R5c no agent in the tab) |
| pushed | F2 file preview, C2 commit detail |
| spaces | P1 Spaces tree with the filter row All · Needs you · Agents (P1b Needs you), Detached row per host, branch per space; P2 a space's tabs, titled as the Mac strip titles them with a line that follows the agent's state (P2b swipe to Close, which ends the tab, P2c menu: New tab, Edit, Detach, Terminate, P2d Edit renaming the space and its tabs, with reorder, P2e New tab held: Shell, Claude, Codex, Pi); P3 the switcher sheet from a tab's host disc |
| host | W0 Spaces tree with the host glyph as the stats button and the Offline group (W0b folded, W0c the filter menu); W1a the small stats sheet (stat strip and sparkline), W1b dragging up, W1c small and offline; W1 the large sheet by CPU, W2 by memory, W3 scrubbing; W5 disconnected, W6 plain SSH, W7 Low Power Mode |
| states | S1 no helper, S2 no grant, S3 offline, S4 review sent with Undo, S5 diff fold and outdated comment |
| settings | G1 Settings as the app's (Appearance with Color scheme and Colorblind-friendly, no app theme; Terminal; Chat; Notifications; Hosts; Remove all data); G2 terminal font; G3 chat font; G5 notifications |
| terminal | T1 search; T2 the key bar's menu with Clear screen |
| chat | C1 search; C2 slash commands; C3 side conversation; C4 goal strip (C4b Manage goal); C5 conversation mode; C6 Jump to latest |
| queue | As the app ships it (`Sources/QueueRow.swift`, `ChatQueuedBubbles`), as Messages' Send Later: queued messages are the user's bubbles, faded, under the working row (Stop beside the clock, "thinking · 38s ■"), the last captioned "2 queued · sends after this turn". Q1 the queue; Q1b a queued bubble tapped: its menu, Send Now ("Interrupts the current turn"), Edit, Move Down, Delete; Q1c Edit: the text in the composer under "Editing queued message · Cancel", send a ✓; Q6 no working row (paused after Stop): "paused after Stop" with Resume |
| message | M1 an agent message's details (the app's M5b) redesigned: agent and time as the title, Copy · Reply · Share · Show in Terminal in the ⋯ menu, the whole message raw (Markdown unrendered, one selection), outcome and time as one line, Changes · Tokens with context · the conversation's model, and past 8 steps the steps folded (patches and failures stay; the runs between fold into a row with a disclosure; Show all); M1b a fold open in place, M1c a short turn (nothing folds), M1d a turn stopped by you |

**iPad** (`Sources/IPad.swift`, `PadStrip.swift`; the same target, landscape). The Mac's layout: a 320-point sidebar
holding the Spaces tree alone (sidebar toggle, title, filter menu and Edit on its bar row, New space in its footer),
and a detail column that opens with the space's tab strip (tab pills with state dot, glyph and title; "+"; the mode
button, the shown mode's glyph and title, whose menu lists Terminal, Chat, Files, Review and Commits, the git two
only inside a repository). Review and
Commits are a 360-point list beside a pane; the stats widget is a popover on the host glyph.

| Group | Screens |
|---|---|
| ipad | I1 files, I2 review (I2b before a selection), I3 commits (I3b before a selection), I4 chat, I5 host popover, I7 terminal, I8 sidebar hidden |
| ipad-half | I6 Split View at 507 points, which is the phone stack: files, and I6b spaces |

**iPhone on its side** (`Sources/FullHeight.swift`, `Landscape.swift`; an iPhone simulator turned by
`shoot.py rotate landscape`, then `shoot.py all landscape`). Height is the scarce axis (402 points on an iPhone 18
Pro, against 874 wide), so every point of it goes to the content: the chrome stands in one rail just inside the safe
area, on the Dynamic Island's side, as the app ships it (docs/ios.md, Landscape). The tab's title is the upright
header's capsule, over the content's top for a moment as the tab opens (the Chat screens show that moment).

| Group | Screens |
|---|---|
| onerail | Back with its count and the menu disc at the rail's top, the five modes stacked, the mode's action at its foot. L12 Chat: Reply is the pink button (attach and send options in the menu disc, dictation on the keyboard's mic), the thread right of the rail; L12b writing: the field alone, text and Send; L12c a draft kept: Reply marked. L13 Review: Create review at the foot with its count, search heading the list, Comment in the diff's header. L14 Terminal: every column right of the rail, the keyboard the rail's foot; L14b typing: the key row (Ctrl, Esc, Tab, Alt, arrows) rides the keyboard; L14c the keyboard button held: Esc, Ctrl-C, Ctrl-D, Tab, Previous command, Paste (Esc without the keyboard is two taps) |
| onerail (edge) | L15 Terminal and L15b Chat to the window's edge: iOS insets both sides 62 points for the Dynamic Island, which is on one side only; the rail stands on the island's side (50 points in, clear of it) and the content runs into the other side's inset to 12 points from the glass, Chat without its 600-point measure. Turned the other way, the rail moves to the right edge with the island |

**iPhone Duo** (`Sources/Duo.swift`; the `Mockups` target on an iPhone Duo simulator, `shoot.py all duo`). As the app
draws it (docs/ios.md, Windows). Unfolded, the inner screen (951 × 669 points, book posture): the Spaces tree in the
iPad's 320-point sidebar (title and Edit on the bar row, the phone's Spaces · Agents bar with New apart) beside the
tab, across the fold, whose header is the phone's without Back (the title capsule, which opens the tab's menu, and
the mode button), the status (time, signal) in the bar's row; Files is the phone's, no tab bar. Folded, the cover screen: the phone's stack,
the tab's header as on the phone. `simctl` has no hinge, so `shoot.py` folds and unfolds the simulator through DeviceHub's hinge buttons
(`hinge.swift`, the accessibility API: the shell running it needs Accessibility access) and shoots the inner screen
as display 3, the cover as the primary display.

| Group | Screens |
|---|---|
| duo | V1 Chat, V2 Files, V3 an agent's tab in Terminal, beside the sidebar at Spaces; V7 inside the space: the sidebar is its screen (Back to Spaces, its tabs without chevrons, New tab), Chat beside it; V8 no tab open |
| duo-cover | V4 Chat, V5 Files, V6 Terminal on the cover screen |

**Apple Watch** (`Watch/`). The phone's row grammar and host strip at watch size.

| Group | Screens |
|---|---|
| watch | K1 Agents list (K1b scrolled), K2 thread, K3 approval, K4 question, K5 dictation reply, K6 host stats (K6b offline), K7 complication layouts as a note, K8 review sent with Undo |

## Decisions these screens carry

- Glyphs: Chat the app's own capsule, `dispatch.chat` (and `.fill` lit; a symbol in the shared asset catalog, drawn
  with `Image(symbol:)`), Review `pencil.and.list.clipboard`, Commits `clock.arrow.circlepath`. Every agent's tab
  carries the Chat capsule in secondary (`AgentMark`), a shell the terminal glyph; the agent is not told apart by its
  mark. The mode button is the app's bar item: the glyph filled in the accent while Chat or Files shows.
- Agent tabs are titled by the conversation's title; the line under it is the current step and elapsed time while
  working, the question while waiting, the last message when done.
- Commits list after a History panel: one line per commit, a continuous two-colour graph, the merged span indented.
- Review comments are glass cards over an unbroken diff, with selection handles and a bottom glass composer; the
  review sheet has a To row, quoted lines, pinned actions, Preview, and Copy-only when the tab has no agent.
- Host stats are a Stocks-style strip (CPU %, memory GB, disk GB free) over one 15-minute sparkline; the small
  sheet offline shows the connection facts and Connect instead.
- Offline hosts gather under an Offline group as header rows only; the group folds and the filter menu can hide it.
- No flat Spaces list and no sort menu; the filter is All · Needs you · Agents.
- Bubbles as the app's (`ChatBubble`): callout in SF Rounded, 20-point corners with a 6-point one at the speaker's
  bottom, the user's in the accent on the right, the agent's grey on the left; nothing in their corners (times and a
  turn's summary come in on a swipe, as Messages'; steps and duration stay in message details). While the agent works
  the working row tells the work.

Not drawn: markdown, image, folder and binary previews; listing empty and error states; transfers; renames, binary
rows and the no-newline marker in diffs; Source mode; editing a comment; lane folding and signature verdicts in
Commits; iPad keyboard shortcuts.

## Layout of this folder

`Mac/` (the Mac screens: a Swift package, built into `build/mac`), `project.yml` (three targets: `Mockups` for iPhone and iPad, `MockupsRotate`, `MockupsWatch`; the `.xcodeproj` is
generated and ignored), `Sources/` (the iOS screens; `Chrome.swift` holds the shared pieces, `Data.swift` the
fictional repo and hosts), `Rotate/`, `Watch/`, `shoot.py`, `contact.swift`, `hinge.swift` (the Duo's hinge). Fictional data only: hosts `mba2`,
`studio`, `ai`; authors Alex Rivera, Sam Example, Priya Example.
