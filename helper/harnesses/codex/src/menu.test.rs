//! Codex 0.166 screens, as its TUI drew them in a 120-column terminal (personal values replaced).
use super::*;

const BANNER: &str = "
  >_ OpenAI Codex (v0.166.0)
     ~/work/example

";

const COMPOSER: &str = "
› Ask Codex to do anything

  Model-A high · ~/work/example · ← for agents
";

const PERMISSIONS: &str = "
  Update Model Permissions


  1. Ask for approval          Read and edit workspace files, and ask before network
                               access or edits outside the workspace
› 2. Approve for me (current)  Only ask for actions detected as potentially unsafe
  3. Full Access               Use with caution: Codex can edit files outside this workspace and access the internet
                               without approval
  4. Read Only                 Read workspace files only

  enter select · esc back
";

const USAGE: &str = "
  Usage
  Account example@example.invalid


› 1. View analytics  Usage history
  2. Redeem reset    Check availability

  enter open · esc back
";

const MODEL: &str = "
  Select Model and Effort

› 1. Model-A (current)  Everyday work.
  2. Model-B            Demanding work.
↓

  enter select · esc back
";

const HOOKS: &str = "
  Hooks
  Lifecycle hooks from config and enabled plugins.

  Event                 Installed   Active      Description
› PreToolUse            0           0           Before a tool executes
  PermissionRequest     0           0           When permission is requested
↓

  enter details · esc close
";

const CONFIG: &str = "
  Configuration
  Changes save automatically

   Appearance   Notifications   Input   Sessions   Text selection

› Theme                   example-theme ›      Choose a syntax color palette with a live preview
  Tips                    [x] On               Show helpful shortcuts and suggestions

  left/right group · / search · enter open · esc clear search/close
";

const EXPERIMENTAL: &str = "
  Experimental features
  Checked features are configured on.

› [ ] Prevent sleep while running    Keep your computer awake while Codex is running a thread.

  space toggle · enter save · esc save/close
";

const PAGER: &str = "
~
~
───────────────────────────────────────────────────────────────── 100% ─
 ↑/↓ to scroll · pgup/pgdn to page · home/end to jump
 q close
";

const PICKER: &str = "
    2d ago      Example conversation
  ↓ more
──────────────────────────────────────────────────────── 1 / 50 · 0% ─
 enter resume   ⌃a archive   esc exit   ⌃c exit   tab focus sort/filter   ←/→ change option
 ⌃o comfortable view   ⌃t transcript   ⌃e expand   ↑/↓ browse
";

fn screen(body: &str) -> String {
    format!("{BANNER}{body}")
}

#[test]
fn settings_menus_are_questions_with_their_descriptions() {
    let permissions = prompt(&screen(PERMISSIONS)).expect("/permissions is a question");
    assert_eq!(permissions.title, "Update Model Permissions");
    assert_eq!(permissions.selected, 2);
    assert_eq!(
        permissions.choices,
        vec![
            (1, "Ask for approval".to_owned()),
            (2, "Approve for me (current)".to_owned()),
            (3, "Full Access".to_owned()),
            (4, "Read Only".to_owned()),
        ]
    );
    assert_eq!(
        permissions.details[0].as_deref(),
        Some("Read and edit workspace files, and ask before network access or edits outside the workspace")
    );
    assert_eq!(
        permissions.details[2].as_deref(),
        Some("Use with caution: Codex can edit files outside this workspace and access the internet without approval")
    );
    let usage = prompt(&screen(USAGE)).expect("/usage is a question");
    assert_eq!(usage.title, "Usage\nAccount example@example.invalid");
    assert_eq!(usage.choices.iter().map(|(_, label)| label.as_str()).collect::<Vec<_>>(), ["View analytics", "Redeem reset"]);
    assert_eq!(usage.details[1].as_deref(), Some("Check availability"));
    // The interaction carries the description; ids stay the choice numbers.
    let interaction = interaction(&Screen { text: screen(PERMISSIONS), ..Default::default() }).unwrap();
    assert_eq!(interaction.id, "prompt:Update Model Permissions");
    assert_eq!(interaction.questions[0].options[3].id, "4");
    assert_eq!(interaction.questions[0].options[3].detail.as_deref(), Some("Read workspace files only"));
}

#[test]
fn the_model_picker_is_walked_never_asked() {
    assert!(prompt(&screen(MODEL)).is_none());
    assert!(surface(&screen(MODEL)).is_none());
}

#[test]
fn menus_chat_cannot_drive_cover_the_composer() {
    for body in [HOOKS, CONFIG, EXPERIMENTAL, PAGER, PICKER] {
        assert!(prompt(&screen(body)).is_none(), "{body}");
        assert!(surface(&screen(body)).is_some(), "{body}");
    }
    // Questions are answered in Chat; the composer, a running turn and the goal editor are not menus.
    for body in [PERMISSIONS, USAGE, COMPOSER] {
        assert!(surface(&screen(body)).is_none(), "{body}");
    }
    let working = format!("{BANNER}\n• Working (3s • esc to interrupt)\n{COMPOSER}");
    assert!(surface(&working).is_none());
    // Esc pressed once at the composer offers to edit the previous message: still the composer.
    let hint = format!("{BANNER}{COMPOSER}  esc again to edit previous message\n");
    assert!(surface(&hint).is_none());
}

#[test]
fn reports_of_codex_0_166_are_read() {
    let before = screen(COMPOSER);
    let pwd = screen(&format!("\n• Current working directory: /work/example\n{COMPOSER}"));
    assert_eq!(report("/pwd", &before, &pwd).as_deref(), Some("/work/example"));
    let ps = screen(&format!("\n/ps\n\nBackground terminals\n\n  • No background terminals running.\n{COMPOSER}"));
    assert_eq!(report("/ps", &before, &ps).as_deref(), Some("• No background terminals running."));
    let mcp = screen(&format!(
        "\n/mcp\n\n🔌  MCP Tools\n\n  • example_tools: connected (3 tools)\n\n  Use /mcp verbose for tools and resources.\n{COMPOSER}"
    ));
    assert_eq!(
        report("/mcp", &before, &mcp).as_deref(),
        Some("• example_tools: connected (3 tools)\n\nUse /mcp verbose for tools and resources.")
    );
    let goal = screen(&format!("\n• Usage: /goal [<objective>|clear|edit|pause|resume] No goal is currently set.\n{COMPOSER}"));
    assert_eq!(super::goal(&goal), Some(("No goal is currently set.".to_owned(), false)));
}

#[test]
fn status_of_codex_0_166_is_read() {
    let text = screen(&format!(
        "
/status

  >_ OpenAI Codex (v0.166.0)

  Visit https://example.invalid/usage for up-to-date
  information on rate limits and credits

  Server:              Local background server
  Model:               Model-A (reasoning high)
  Model provider:      openai
  Directory:           ~/work/example
  Permissions:         Workspace write
  Agents.md:           AGENTS.md
  Account:             example@example.invalid (Example plan)
  Collaboration mode:  Default
  Session:             00000000-0000-4000-8000-000000000001

  Weekly limit:        [███████████░░░░░░░░░] 57% left (resets 7:49 PM)
{COMPOSER}"
    ));
    let status = status(&text).expect("/status");
    assert_eq!(status.session, "00000000-0000-4000-8000-000000000001");
    assert_eq!(status.mode.as_deref(), Some("default"));
    assert!(status.text.starts_with("Model:               Model-A (reasoning high)"));
}
