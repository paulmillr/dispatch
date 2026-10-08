//! Native fixed prompts and one navigation walk; the mux performs all screen/key IO.
use crate::history::error;
use dispatch_helper4_core::api::*;

const PROMPTS: [&str; 3] = ["Select model", "Switch model?", "Change effort level?"];
pub fn lines(s: &str) -> Option<impl DoubleEndedIterator<Item = &str> + Clone> {
    (s.len() <= 65_536).then(|| s.lines().map(str::trim))
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub number: u64,
    pub name: String,
    pub detail: String,
    pub current: bool,
    pub default: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
    pub choices: Vec<Row>,
    pub selected: String,
    pub effort: Option<String>,
    pub count: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Startup {
    pub model: Option<String>,
    pub effort: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Confirmation {
    pub title: String,
    pub choices: Vec<Row>,
    pub selected: String,
    pub detail: String,
}

/// 1-3 digits, like the old patterns' `\d{1,3}`.
fn number(s: &str) -> Option<u64> {
    (!s.is_empty() && s.len() <= 3 && s.bytes().all(|b| b.is_ascii_digit()))
        .then(|| s.parse().ok())?
}
/// e076fd7 ClaudeModelMenu row: `^(?:(❯)|[↑↓])?\s*(\d{1,3})\.\s+(.+)$`, label before the first
/// gap of 2+ spaces.
fn row(s: &str) -> Option<Row> {
    let (n, tail) = s
        .strip_prefix(['❯', '↑', '↓'])
        .unwrap_or(s)
        .trim_start()
        .split_once('.')?;
    let tail = tail.strip_prefix(char::is_whitespace)?.trim_start();
    if tail.is_empty() {
        return None;
    }
    let (name, detail) = tail.split_once("  ").unwrap_or((tail, ""));
    let plain = name.replace('✔', "").replace(" (recommended)", "");
    Some(Row {
        number: number(n)?,
        name: plain.trim().into(),
        detail: detail.trim().into(),
        current: name.contains('✔'),
        default: name.contains("(recommended)"),
    })
}
/// e076fd7 `(?:^|\s)([a-zA-Z][a-zA-Z0-9-]*) effort\b`, first match.
fn effort(s: &str) -> Option<String> {
    s.match_indices(" effort").find_map(|(at, word)| {
        let level = s[..at].rsplit(char::is_whitespace).next()?;
        (level.starts_with(|c: char| c.is_ascii_alphabetic())
            && level.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && !s[at + word.len()..].starts_with(|c: char| c.is_alphanumeric() || c == '_'))
        .then(|| level.to_ascii_lowercase())
    })
}
pub fn read(s: &str) -> Option<View> {
    let all: Vec<_> = lines(s)?.collect();
    let start = all.iter().rposition(|s| *s == PROMPTS[0])?;
    let end = all
        .iter()
        .rposition(|s| s.contains("s to use this session only") && s.contains("Esc to cancel"))?;
    if end <= start
        || all[end + 1..]
            .iter()
            .any(|s| !s.chars().all(|c| matches!(c, '─' | '▔')))
    {
        return None;
    }
    let body = &all[start + 1..end];
    let (mut choices, mut selected, mut effort_, mut hidden) = (Vec::new(), None, None, None);
    for s in body {
        if let Some(row) = row(s) {
            if row.name.is_empty() || row.name.chars().count() >= 150 {
                return None;
            }
            if s.starts_with('❯') {
                selected = Some(row.name.clone());
            }
            choices.push(row);
        } else if let Some(level) = effort(s) {
            effort_ = Some(level);
        } else if let Some(n) = s
            .strip_prefix("… +")
            .and_then(|s| {
                s.strip_suffix(" models")
                    .or_else(|| s.strip_suffix(" model"))
            })
            .and_then(number)
        {
            hidden = Some(n);
        }
    }
    let total = choices.len() as u64 + hidden.unwrap_or(0);
    let count = ((hidden.is_some() || !body.iter().any(|s| s.starts_with(['↑', '↓'])))
        && total <= 100
        && choices
            .iter()
            .all(|r| (1..=total.max(1)).contains(&r.number)))
    .then_some(total);
    let unique = |key: fn(&Row) -> String| {
        choices
            .iter()
            .map(key)
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            == choices.len()
    };
    if choices.is_empty()
        || choices.len() > 100
        || !unique(|r| r.name.clone())
        || !unique(|r| r.number.to_string())
        || choices.iter().filter(|r| r.current).count() > 1
        || count == Some(choices.len() as u64) && !choices.iter().any(|r| r.current)
    {
        return None;
    }
    Some(View {
        choices,
        selected: selected?,
        effort: effort_,
        count,
    })
}
impl View {
    pub fn catalog(&self) -> Menu {
        Menu {
            default: self.choices.iter().find(|row| row.default).map(|row| row.name.clone()),
            result: None,
            choices: self
                .choices
                .iter()
                .map(|r| Choice {
                    id: r.name.clone(),
                    label: r.name.clone(),
                    detail: (!r.detail.is_empty()).then(|| r.detail.clone()),
                })
                .collect(),
            current: self
                .choices
                .iter()
                .find(|r| r.current)
                .map(|r| r.name.clone()),
        }
    }
}
pub fn model(s: &str) -> Option<String> {
    let (family, tail) = s.split_once(' ')?;
    if family.is_empty() || !family.bytes().all(|b| b.is_ascii_alphabetic()) {
        return None;
    }
    let end = tail.find(char::is_whitespace).unwrap_or(tail.len());
    let v = &tail[..end];
    if end < tail.len() && !tail[end..].trim_start().starts_with('·') {
        return None;
    }
    if v.is_empty()
        || !v
            .split('.')
            .all(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    Some(format!(
        "claude-{}-{}",
        family.to_ascii_lowercase(),
        v.replace('.', "-")
    ))
}
/// e076fd7 ClaudeStartupConfiguration: banner `Family N.N[ (…)][ with level effort] · `, the
/// live footer `<mark> level · /effort` wins over the banner's effort.
pub fn startup(s: &str) -> Option<Startup> {
    let all: Vec<_> = lines(s)?.collect();
    let start = all.iter().position(|s| {
        s.trim_start_matches(|c: char| !c.is_ascii_alphabetic())
            .strip_prefix("Claude Code v")
            .is_some_and(|v| v.starts_with(|c: char| c.is_ascii_digit()))
    })?;
    let prompt = all.iter().rposition(|s| s.starts_with('❯'))?;
    if prompt <= start + 2
        || border(all[prompt - 1]).is_none()
        || all[start + 2..prompt - 1]
            .iter()
            .any(|s| s.starts_with('❯'))
    {
        return None;
    }
    let banner = (|| {
        let line = all[start + 1].trim_start_matches(|c: char| !c.is_ascii_alphabetic());
        let family = line.find(|c: char| !c.is_ascii_alphabetic())?;
        let rest = line[family..].strip_prefix(' ')?;
        let version = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(rest.len());
        let model = model(&format!("{} {}", &line[..family], &rest[..version]))?;
        let mut tail = &rest[version..];
        if let Some(close) = tail.strip_prefix(" (").and_then(|t| t.find(')')) {
            tail = &tail[close + 3..];
        }
        let mut level = None;
        if let Some((value, rest)) = tail
            .strip_prefix(" with ")
            .and_then(|t| t.split_once(" effort"))
            .filter(|(v, _)| !v.is_empty() && v.bytes().all(|b| b.is_ascii_lowercase()))
        {
            level = Some(value.to_owned());
            tail = rest;
        }
        tail.starts_with(" · ").then_some((model, level))
    })();
    let live = all[prompt + 1..].iter().rev().find_map(|s| {
        let (mark, level) = s.strip_suffix(" · /effort")?.rsplit_once(' ')?;
        (!level.is_empty()
            && level.bytes().all(|b| b.is_ascii_lowercase())
            && mark.rsplit(char::is_whitespace).next()?.chars().count() == 1)
            .then(|| level.to_owned())
    });
    let (model, level) = banner.unzip();
    let effort = live.or(level.flatten());
    (model.is_some() || effort.is_some()).then_some(Startup { model, effort })
}
pub fn confirmation(s: &str) -> Option<Confirmation> {
    let all: Vec<_> = lines(s)?.collect();
    let start = all.iter().rposition(|s| PROMPTS[1..].contains(s))?;
    let body = &all[start + 1..];
    if !body.iter().any(|s| {
        [
            "Your next response will be slower and use more tokens",
            "A PreModelSwitch hook asked you to confirm",
        ]
        .contains(s)
    }) {
        return None;
    }
    // e076fd7 ClaudeModelConfirmation: exactly the two rows, one marked, and nothing after them.
    let rows: Vec<_> = body
        .iter()
        .filter(|s| ["❯ ", "1. ", "2. "].iter().any(|p| s.starts_with(p)))
        .collect();
    let names: Vec<_> = rows.iter().map(|s| s.replace("❯ ", "")).collect();
    if rows.len() != 2
        || !names[0].starts_with("1. Yes, switch to ")
        || names[1] != "2. No, go back"
        || all.iter().rfind(|s| !s.is_empty()) != Some(rows[1])
        || rows.iter().filter(|s| s.starts_with("❯ ")).count() != 1
    {
        return None;
    }
    let choices: Vec<_> = names
        .iter()
        .enumerate()
        .map(|(index, name)| Row {
            number: index as u64 + 1,
            name: name[3..].into(),
            detail: String::new(),
            current: false,
            default: false,
        })
        .collect();
    let selected = choices[usize::from(!rows[0].starts_with("❯ "))]
        .name
        .clone();
    let detail = body
        .iter()
        .take_while(|s| *s != rows[0])
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join("\n\n");
    Some(Confirmation {
        title: all[start].into(),
        choices,
        selected,
        detail,
    })
}
/// Claude's native permission panel: a full rule opens it; the "...?" question sits above the
/// numbered options (one marked "❯ ") and the footer "Esc to cancel ...". Detail: the panel's
/// lines above the question (tool kind, description, the command box without its frame).
pub fn permission(s: &str) -> Option<Confirmation> {
    let all: Vec<_> = lines(s)?.collect();
    let footer = all.iter().rposition(|s| !s.is_empty())?;
    if !all[footer].starts_with("Esc to cancel") {
        return None;
    }
    let mut rows = Vec::new();
    let mut title = None;
    for index in (0..footer).rev() {
        let line = all[index];
        if line.is_empty() && rows.is_empty() {
            continue;
        }
        let (marked, rest) = line.strip_prefix("❯ ").map_or((false, line), |r| (true, r));
        match rest
            .split_once(". ")
            .and_then(|(n, label)| Some((n.parse::<u64>().ok()?, label)))
        {
            Some((number, label)) => rows.insert(0, (marked, number, label)),
            None => {
                title = Some(index);
                break;
            }
        }
    }
    let title = title?;
    if rows.is_empty()
        || !all[title].ends_with('?')
        || rows.iter().enumerate().any(|(i, r)| r.1 != i as u64 + 1)
        || rows.iter().filter(|r| r.0).count() != 1
    {
        return None;
    }
    let start = all[..title].iter().rposition(|s| rule(s))?;
    let choices: Vec<_> = rows
        .iter()
        .map(|(_, number, label)| Row {
            number: *number,
            name: (*label).into(),
            detail: String::new(),
            current: false,
            default: false,
        })
        .collect();
    Some(Confirmation {
        title: all[title].into(),
        selected: rows.iter().find(|r| r.0).unwrap().2.into(),
        choices,
        detail: all[start + 1..title]
            .iter()
            .filter(|s| !s.is_empty() && !s.chars().all(|c| c == '╌'))
            .map(|s| s.strip_prefix("│ ").unwrap_or(s))
            .collect::<Vec<_>>()
            .join("\n"),
    })
}
/// The permission panel as a chat card (codex menu::interaction shape; answered by Goal::Choose).
pub fn prompt(screen: &Screen) -> Option<Interaction> {
    let panel = permission(&screen.text)?;
    Some(Interaction {
        key: None,
        turn: None,
        record: None,
        id: format!("prompt:{}", panel.title),
        approval: false,
        blocking: true,
        questions: vec![Question {
            id: "prompt".into(),
            header: panel.title.clone(),
            text: panel.detail,
            secret: false,
            options: panel
                .choices
                .iter()
                .map(|row| Choice {
                    id: row.number.to_string(),
                    label: row.name.clone(),
                    detail: None,
                })
                .collect(),
            multiple: false,
            custom: false,
            blocks: Vec::new(),
        }],
    })
}
/// `name`: the verified registration name. USER DECISION 2026-10-03 (diverges from c1654cc
/// isEmptyComposer): Claude draws it into the top rule after /rename ('──── name ─'); only that
/// exact name is accepted there.
pub fn ready(screen: &Screen, working: bool, name: Option<&str>) -> bool {
    let Some(mut all) = lines(&screen.text).map(Iterator::collect::<Vec<_>>) else {
        return false;
    };
    let prefix = screen
        .text
        .lines()
        .nth(screen.cursor.1 as usize)
        .map(|s| s.chars().take(screen.cursor.0 as usize).collect::<String>());
    if screen.faint_tail && prefix.as_ref().is_some_and(|s| s.trim() == "❯") {
        if let Some(row) = all.get_mut(screen.cursor.1 as usize) {
            *row = "❯";
        }
    }
    let Some(prompt) = all.iter().rposition(|s| s.starts_with('❯')) else {
        return false;
    };
    if prompt == 0 || all[prompt] != "❯" || !all.get(prompt + 1).is_some_and(|s| rule(s)) {
        return false;
    }
    let Some(label) = border(all[prompt - 1]) else {
        return false;
    };
    if !label.is_empty() && name != Some(label) {
        return false;
    }
    let below = &all[prompt + 2..];
    !below.iter().any(|s| rule(s))
        && below.iter().any(|s| {
            if s.contains("esc to interrupt") {
                return working;
            }
            s.contains("for shortcuts")
                || s.contains("for agents")
                || *s == "paste again to expand"
                || s.match_indices("← ").any(|(start, _)| {
                    let rest = &s[start + "← ".len()..];
                    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
                    digits > 0
                        && rest[digits..].strip_prefix(" agent").is_some_and(|tail| {
                            let tail = tail.strip_prefix('s').unwrap_or(tail);
                            tail.is_empty() || tail.starts_with(char::is_whitespace)
                        })
                })
        })
}
// Empty for a plain rule, otherwise the literal session name within the rule.
fn border(s: &str) -> Option<&str> {
    if !s.starts_with('─') || !s.ends_with('─') {
        return None;
    }
    let label = s.trim_matches('─');
    if label.is_empty() {
        return Some(label);
    }
    label
        .strip_prefix(' ')?
        .strip_suffix(' ')
        .filter(|s| !s.contains('─'))
}
fn rule(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c == '─')
}

/// Claude's live status permits input: idle, or mid-turn while steering. Claude Code reports a
/// turn as "busy" (2.1.28x) or "working" (earlier releases).
pub fn input(status: &str, name: Option<&str>, screen: &Screen, mode: Mode) -> bool {
    let steering = mode == Mode::Steer;
    ready(screen, steering, name)
        && (status == "idle" || steering && ["working", "busy"].contains(&status))
}

pub fn interrupt(status: &str, screen: &Screen) -> bool {
    !["idle", "waiting", "unknown"].contains(&status)
        && lines(&screen.text).is_some_and(|lines| {
            lines
                .filter(|line| !line.is_empty())
                .rev()
                .take(4)
                .any(|line| line.to_lowercase().contains("esc to interrupt"))
        })
}

#[derive(Default, PartialEq)]
enum Stage {
    #[default]
    Start,
    Models,
    Target,
    Efforts,
    Restore,
    Apply,
    Ask,
    Enter,
    Verify,
    Exit,
}
#[derive(Default)]
pub struct Walk {
    /// The last semantic keys this walk sent.
    pub inputs: Vec<Input>,
    /// Core's flag for the next screen: the 1 s settle sample (a clamped end) versus a change
    /// or a 40 ms sample. None (direct callers) falls back to "same text as the last screen".
    pub settled: Option<bool>,
    goal: Option<Goal>,
    stage: Stage,
    rows: Vec<Row>,
    ring: Vec<String>,
    visited: Vec<String>,
    direction: usize,
    original: Option<String>,
    active: Option<String>,
    scope: Option<Confirmation>,
    decision: usize,
    pub(crate) cancelled: bool,
    opening: bool,
    previous: Option<View>,
    /// The settled menu when the last arrow key was sent, until its result settles.
    before: Option<View>,
    /// The previous delivered screen text: core re-delivers it unchanged at the settle deadline.
    raw: Option<String>,
    /// A read catalog or effort list, returned once Escape has closed the menu (Stage::Exit).
    result: Option<Menu>,
}
impl Walk {
    /// codex's choose (c1654cc ChatCommands.chooseCommandOption :578-628): Up/Down toward the
    /// chosen option, Enter on it, Escape dismisses; done once the panel left the screen. Claude
    /// redraws its selection later than core's 40 ms samples: after an arrow the next key waits
    /// for the selection to move (or the settle mark), and Enter/Escape are sent once.
    fn choose(
        &mut self,
        title: &str,
        choice: Option<u32>,
        screen: &Screen,
        repeated: bool,
    ) -> Step {
        let Some(panel) = permission(&screen.text).filter(|panel| panel.title == title) else {
            self.goal = None;
            return Step::Done(Menu::default());
        };
        if self.stage == Stage::Verify
            || self
                .scope
                .as_ref()
                .is_some_and(|before| before.selected == panel.selected)
                && !repeated
        {
            return Step::Wait;
        }
        let Some(choice) = choice else {
            self.stage = Stage::Verify;
            return Step::Keys(self.keys(5));
        };
        let Some(target) = panel.choices.get(choice as usize) else {
            return Step::Fail(error(
                "question",
                "The question changed. Check the current question before answering.",
            ));
        };
        let selected = panel
            .choices
            .iter()
            .find(|r| r.name == panel.selected)
            .unwrap();
        let key = match target.number.cmp(&selected.number) {
            std::cmp::Ordering::Equal => {
                self.stage = Stage::Verify;
                4
            }
            order => usize::from(order == std::cmp::Ordering::Greater),
        };
        self.scope = Some(panel);
        Step::Keys(self.keys(key))
    }
    fn keys(&mut self, index: usize) -> Vec<Input> {
        self.inputs = vec![match index {
            0 => Input::Key(Key::Up),
            1 => Input::Key(Key::Down),
            2 => Input::Key(Key::Left),
            3 => Input::Key(Key::Right),
            4 => Input::Key(Key::Enter),
            5 => Input::Key(Key::Escape),
            _ => Input::Text("s".into()),
        }];
        self.inputs.clone()
    }
    fn key(&mut self, index: usize) -> Step {
        if index < 4 {
            self.before = self.previous.clone();
        }
        Step::Keys(self.keys(index))
    }
    fn open(&mut self) -> Step {
        self.inputs = vec![Input::Text("/model".into()), Input::Key(Key::Enter)];
        Step::Keys(self.inputs.clone())
    }
    pub fn answer(&mut self, answers: Vec<(String, Answer)>) -> Result<Sent, Error> {
        self.inputs.clear();
        let scope = self
            .scope
            .as_ref()
            .filter(|_| self.stage == Stage::Ask)
            .ok_or_else(|| error("expired", "Claude's confirmation changed"))?;
        if answers.len() != 1 || answers[0].0 != "confirmation" {
            return Err(error("invalid", "Choose one confirmation answer"));
        }
        self.decision = match &answers[0].1 {
            Answer::Options(v) if v.len() == 1 && v[0] < 2 => v[0],
            Answer::Skip => 1,
            _ => return Err(error("invalid", "Choose Yes or No")),
        };
        self.cancelled = self.decision == 1;
        let selected = scope.choices[self.decision].name == scope.selected;
        self.stage = if selected {
            Stage::Verify
        } else {
            Stage::Enter
        };
        Ok(Sent::Keys(self.keys(if selected {
            4
        } else {
            self.decision
        })))
    }
    pub fn next(
        &mut self,
        session: &str,
        status: &str,
        name: Option<&str>,
        goal: &Goal,
        screen: &Screen,
    ) -> Step {
        self.inputs.clear();
        if self.goal.as_ref() != Some(goal) {
            self.goal = Some(goal.clone());
            self.stage = Stage::Start;
            self.visited.clear();
            self.direction = 0;
            self.cancelled = false;
            self.scope = None;
            self.opening = false;
            self.previous = None;
            self.before = None;
            self.result = None;
        }
        let repeated = self
            .settled
            .take()
            .unwrap_or(self.raw.as_deref() == Some(screen.text.as_str()));
        self.raw = Some(screen.text.clone());
        if let Goal::Choose { title, choice } = goal {
            return self.choose(title, *choice, screen, repeated);
        }
        if matches!(goal, Goal::Send { .. } | Goal::Stop) {
            if self.stage == Stage::Exit {
                self.goal = None;
                return Step::Done(Menu::default());
            }
            if self.stage == Stage::Enter {
                self.stage = Stage::Exit;
                return Step::Submit(self.keys(4));
            }
            let valid = !matches!(goal, Goal::Send { text, .. }
                if text.bytes().any(|b| b < 32 && b != b'\n' && b != b'\t'));
            let redraw = !repeated && lines(&screen.text).is_some_and(|all| {
                let all: Vec<_> = all.collect();
                let bottom = all.iter().rposition(|s| rule(s)).unwrap_or(0);
                let top = all[..bottom].iter().rposition(|s| border(s).is_some())
                    .map_or(0, |row| row + 1);
                !all[top..bottom].iter().any(|s| s.starts_with('❯'))
                    || !(top..bottom).contains(&(screen.cursor.1 as usize))
            });
            return match goal {
                Goal::Stop if interrupt(status, screen) => {
                    self.stage = Stage::Exit;
                    Step::Submit(self.keys(5))
                }
                Goal::Send {
                    text,
                    mode,
                    command,
                } if valid && input(status, name, screen, *mode) =>
                {
                    let mut literal = text.clone();
                    if !command && text.trim_start().starts_with(['/', '!']) {
                        let mut counts = [0usize; 2];
                        let mut longest = [0usize; 2];
                        for character in text.chars() {
                            for (index, marker) in ['`', '~'].iter().enumerate() {
                                counts[index] = if character == *marker {
                                    counts[index] + 1
                                } else {
                                    0
                                };
                                longest[index] = longest[index].max(counts[index]);
                            }
                        }
                        let index = usize::from(longest[0] > longest[1]);
                        let fence = ['`', '~'][index]
                            .to_string()
                            .repeat(3.max(longest[index] + 1));
                        literal = format!(
                            "{fence}\n{text}{}{fence}",
                            if text.ends_with('\n') { "" } else { "\n" }
                        );
                    }
                    self.inputs = vec![Input::Paste(literal)];
                    self.stage = Stage::Enter;
                    Step::Keys(self.inputs.clone())
                }
                Goal::Send { mode: Mode::Prompt, .. }
                    if valid && status == "idle"
                        && (redraw || ready(screen, true, name) && !ready(screen, false, name)) =>
                {
                    // Registration can finish before the native composer redraw reaches us.
                    // A missing prompt marker may be a partial redraw; a visible draft is refused.
                    Step::Wait
                }
                _ => Step::Fail(error(
                    "input",
                    "Claude's current prompt or session does not allow input",
                )),
            };
        }
        match self.stage {
            Stage::Ask => return Step::Wait,
            Stage::Enter => {
                if !confirmation(&screen.text).is_some_and(|now| {
                    self.scope.as_ref().is_some_and(|old| {
                        now.title == old.title
                            && now.choices == old.choices
                            && now.selected == old.choices[self.decision].name
                    })
                }) {
                    return Step::Fail(error(
                        "changed",
                        "Claude's confirmation changed; open Terminal",
                    ));
                }
                self.stage = Stage::Verify;
                return self.key(4);
            }
            Stage::Apply => {
                if let Some(scope) = confirmation(&screen.text) {
                    let q = Question {
                        blocks: Vec::new(),
                        id: "confirmation".into(),
                        header: scope.title.clone(),
                        text: scope.detail.clone(),
                        secret: false,
                        multiple: false,
                        custom: false,
                        options: scope
                            .choices
                            .iter()
                            .map(|r| Choice {
                                id: r.number.to_string(),
                                label: r.name.clone(),
                                detail: None,
                            })
                            .collect(),
                    };
                    self.scope = Some(scope);
                    self.stage = Stage::Ask;
                    return Step::Ask(Interaction {
                        key: None,
                        turn: None,
                        record: None,
                        id: format!("menu:{session}"),
                        approval: false,
                        blocking: true,
                        questions: vec![q],
                    });
                }
                if ready(screen, false, name) {
                    self.stage = Stage::Verify;
                    self.opening = true;
                    return self.open();
                }
                return Step::Wait;
            }
            Stage::Exit => {
                if read(&screen.text).is_some()
                    || confirmation(&screen.text).is_some()
                    || !ready(screen, false, name)
                {
                    return Step::Wait;
                }
                self.goal = None;
                return Step::Done(self.result.take().unwrap_or_else(|| Menu {
                    default: None,
                    result: None,
                    choices: Vec::new(),
                    current: self.active.clone(),
                }));
            }
            _ => {}
        }
        let Some(view) = read(&screen.text) else {
            self.previous = None;
            return if matches!(self.stage, Stage::Start | Stage::Verify)
                && !self.opening
                && ready(screen, false, name)
            {
                self.opening = true;
                self.open()
            } else {
                Step::Wait
            };
        };
        // c1654cc ChatModelPicker.swift:474-499: a menu counts once two samples agree; after an
        // arrow key it must also differ from the menu before the key, unless the unchanged
        // screen comes back at the settle deadline (a clamped end).
        let settled = self.previous.as_ref() == Some(&view)
            && self
                .before
                .as_ref()
                .is_none_or(|before| *before != view || repeated);
        if (matches!(self.stage, Stage::Start | Stage::Verify) || self.before.is_some()) && !settled
        {
            self.previous = Some(view);
            return Step::Wait;
        }
        self.before = None;
        self.opening = false;
        if self.stage == Stage::Start {
            self.active = view
                .choices
                .iter()
                .find(|r| r.current)
                .map(|r| r.name.clone());
            self.stage = if *goal == Goal::Models {
                self.rows.clear();
                Stage::Models
            } else {
                Stage::Target
            };
        }
        for row in &view.choices {
            if !self.rows.iter().any(|r| r.name == row.name) {
                self.rows.push(row.clone())
            }
        }
        // One bounded two-direction walk for clamped/wrapping models and effort.
        if matches!(self.stage, Stage::Models | Stage::Efforts) {
            let models = self.stage == Stage::Models;
            let value = if models {
                Some(view.selected.clone())
            } else {
                view.effort.clone()
            };
            if let Some(value) = value {
                if !models && !self.ring.contains(&value) {
                    if self.direction == 0 {
                        self.ring.insert(0, value.clone())
                    } else {
                        self.ring.push(value.clone())
                    }
                }
                let full = models
                    && view.count.is_some_and(|n| {
                        self.rows.len() == n as usize
                            && (1..=n).all(|i| self.rows.iter().any(|r| r.number == i))
                    });
                if full {
                    self.stage = Stage::Restore
                } else if self.visited.contains(&value)
                    || self.visited.len() == if models { 100 } else { 16 }
                {
                    // e076fd7 loadClaudeChoices: a value revisited after a real move closed a
                    // full wrap; only a clamped end (no move) turns the walk around. Efforts use
                    // the same rule (2.1.283's effort ring wraps; walking it back adds nothing).
                    let wrapped = self.visited.last() != Some(&value);
                    if self.direction == 0 && !wrapped {
                        self.direction = 1;
                        self.visited.clear()
                    } else {
                        self.stage = Stage::Restore
                    }
                }
                if self.stage != Stage::Restore {
                    self.visited.push(value);
                    return self.key(if models {
                        1 - self.direction
                    } else {
                        2 + self.direction
                    });
                }
            } else {
                self.stage = Stage::Restore
            }
        }
        let target = match goal {
            // e076fd7 ChatModelPicker.loadClaudeChoices leaves the highlight where the catalog
            // walk ended; only the effort walk restores (loadClaudeEfforts).
            Goal::Models => view.selected.as_str(),
            Goal::Efforts { model } | Goal::Select { model, .. } => model,
            _ => return Step::Fail(error("invalid", "Not a model goal")),
        };
        if view.selected != target {
            let Some(row) = self.rows.iter().find(|r| r.name == target) else {
                return Step::Fail(error("changed", "Choose a listed Claude model"));
            };
            let selected = view
                .choices
                .iter()
                .find(|r| r.name == view.selected)
                .unwrap();
            return self.key(usize::from(selected.number < row.number));
        }
        let current = self.active.as_deref() == Some(target);
        if self.stage == Stage::Target {
            self.original = view.effort.clone();
            self.visited.clear();
            self.direction = 0;
            if matches!(goal, Goal::Efforts { .. }) {
                self.ring.clear();
                self.stage = Stage::Efforts;
                return self.next(session, status, name, goal, screen);
            }
            self.stage = Stage::Restore;
        }
        let level = match goal {
            Goal::Select { effort, .. } => effort.as_ref(),
            Goal::Efforts { .. } => self.original.as_ref(),
            _ => None,
        };
        if self.stage != Stage::Verify && level != view.effort.as_ref() && level.is_some() {
            let target = level.and_then(|s| self.ring.iter().position(|r| r == s));
            let current = view
                .effort
                .as_ref()
                .and_then(|s| self.ring.iter().position(|r| r == s));
            let (Some(target), Some(current)) = (target, current) else {
                return Step::Fail(error(
                    "changed",
                    "This Claude effort is no longer available",
                ));
            };
            return self.key(2 + usize::from(current < target));
        }
        // The chat picker has no close call, so a read leaves no menu in Terminal: Escape, and
        // Stage::Exit returns the result once the composer is back. Select reopens /model.
        match goal {
            Goal::Models => {
                self.rows.sort_by_key(|r| r.number);
                self.result = Some(
                    View {
                        choices: self.rows.clone(),
                        ..view
                    }
                    .catalog(),
                );
                self.stage = Stage::Exit;
                self.key(5)
            }
            Goal::Efforts { .. } => {
                const RANK: [&str; 9] = [
                    "ultracode",
                    "ultra",
                    "max",
                    "xhigh",
                    "high",
                    "medium",
                    "low",
                    "minimal",
                    "none",
                ];
                let mut values = self.ring.clone();
                values.sort_by_key(|s| RANK.iter().position(|r| r == s).unwrap_or(RANK.len()));
                let empty = values.is_empty();
                let choices = if empty {
                    vec![Choice {
                        id: "default".into(),
                        label: "Default".into(),
                        detail: Some("This model has no adjustable effort".into()),
                    }]
                } else {
                    values
                        .iter()
                        .map(|s| {
                            let mut chars = s.chars();
                            Choice {
                                id: s.clone(),
                                label: chars.next().unwrap().to_uppercase().collect::<String>()
                                    + chars.as_str(),
                                detail: None,
                            }
                        })
                        .collect()
                };
                self.result = Some(Menu {
                    default: empty.then(|| "default".into()),
                    result: None,
                    choices,
                    current: if empty {
                        Some("default".into())
                    } else if current {
                        self.original.clone()
                    } else {
                        None
                    },
                });
                self.stage = Stage::Exit;
                self.key(5)
            }
            Goal::Select { model, effort } if self.stage == Stage::Verify => {
                if !self.cancelled
                    && (view.choices.iter().find(|r| r.current).map(|r| &r.name) != Some(model)
                        || &view.effort != effort)
                {
                    return Step::Fail(error(
                        "changed",
                        "Claude did not confirm the change; check Terminal before retrying",
                    ));
                }
                self.active = view
                    .choices
                    .iter()
                    .find(|r| r.current)
                    .map(|r| crate::menu::model(&r.detail).unwrap_or_else(|| r.name.clone()));
                self.stage = Stage::Exit;
                self.key(5)
            }
            Goal::Select { .. } => {
                self.stage = Stage::Apply;
                self.key(6)
            }
            _ => Step::Fail(error("invalid", "Not a model goal")),
        }
    }
}
