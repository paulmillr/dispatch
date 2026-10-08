//! Codex menu decisions return keys; the multiplexer checks and writes them.
use crate::channel::failure;
use dispatch_helper4_core::api::{
    Answer, Binding, Choice, Error, Goal, Input, Interaction, Key, Menu, Question, Screen, Sent,
    Step,
};

#[derive(Default)]
pub(crate) struct Walk {
    pub turn: Option<Option<String>>,
    pub labels: Vec<(String, String)>,
    pub opening: bool,
    before: Option<String>,
    scope: Option<Interaction>,
    decision: Option<usize>,
    submitted: bool,
}

impl Walk {
    pub fn answer(&mut self, id: &str, answers: &[(String, Answer)]) -> Result<Sent, Error> {
        let scope = self
            .scope
            .as_ref()
            .filter(|scope| scope.id == id)
            .ok_or_else(|| failure("question", "The model confirmation changed."))?;
        let [(key, Answer::Options(choices))] = answers else {
            return Err(failure("question", "Choose one scope."));
        };
        let [choice] = choices.as_slice() else {
            return Err(failure("question", "Choose one scope."));
        };
        if key != "scope" || *choice >= scope.questions[0].options.len() {
            return Err(failure("question", "The model confirmation changed."));
        }
        self.decision = Some(*choice);
        Ok(Sent::Keys(Vec::new()))
    }
}

/// c1654cc ChatNativePrompt (ChatCommands.swift:104-145): an agent prompt screen, numbered
/// choices above its footer, only under a known planning/review/goal/question title.
pub struct Prompt {
    pub title: String,
    pub choices: Vec<(u32, String)>,
    pub selected: u32,
}

/// AgentModelMenu.isFooter (AgentModelMenu.swift:29-31).
fn footer(line: &str) -> bool {
    line.contains("esc to go back") || line.starts_with("enter ") && line.ends_with(" · esc back")
}

/// `^(›\s*)?(\d{1,3})\.\s+(.+)$` on a trimmed line: (selected, number, label).
fn numbered(line: &str) -> Option<(bool, u32, &str)> {
    let marked = line.strip_prefix('›');
    let rest = marked.map_or(line, str::trim_start);
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    let label = rest[digits..].strip_prefix('.')?;
    let trimmed = label.trim_start();
    ((1..=3).contains(&digits) && trimmed.len() < label.len() && !trimmed.is_empty())
        .then(|| (marked.is_some(), rest[..digits].parse().unwrap(), trimmed))
}

/// Foundation's .newlines separators (`components(separatedBy: .newlines)`).
const NEWLINES: [char; 7] = [
    '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
];

/// `components(separatedBy: .newlines)`, each trimmed.
fn rows(text: &str) -> Vec<&str> {
    text.split(NEWLINES).map(str::trim).collect()
}

pub fn prompt(screen: &str) -> Option<Prompt> {
    let lines = rows(screen);
    let end = lines
        .iter()
        .rposition(|line| line.contains("enter to submit answer") || footer(line))?;
    if screen.len() > 65_536 || !lines[end + 1..].iter().all(|line| line.is_empty()) {
        return None;
    }
    let (mut choices, mut selected, mut first) = (Vec::new(), None, None);
    for index in (0..end).rev() {
        match numbered(lines[index]) {
            Some((marked, number, label)) => {
                choices.insert(0, (number, label.to_owned()));
                selected = marked.then_some(number).or(selected);
                first = Some(index);
            }
            None if !choices.is_empty() && !lines[index].is_empty() => break,
            None => {}
        }
    }
    let (selected, first) = (selected?, first?);
    let mut numbers: Vec<u32> = choices.iter().map(|(number, _)| *number).collect();
    numbers.sort_unstable();
    numbers.dedup();
    if numbers.len() != choices.len() || choices.len() > 20 {
        return None;
    }
    // Only known planning/review/goal surfaces may own these buttons.
    let start = (0..first).rev().find(|&index| {
        let line = lines[index];
        line.starts_with("Question ")
            || line.contains("Implement this plan?")
            || line.contains("Would you like to implement")
            || line == "Select a review preset"
            || line.starts_with("Replace goal")
            || line.starts_with("Replace the current goal")
            || line == "Resume paused goal?"
    })?;
    let title = lines[start..first].iter().filter(|line| !line.is_empty());
    Some(Prompt {
        title: title.copied().collect::<Vec<_>>().join("\n"),
        choices,
        selected,
    })
}

/// ChatNativeGoalStatus (ChatCommands.swift): the latest /goal report, (text, has a goal); only
/// a complete report not followed by later output or another /goal.
pub fn goal(screen: &str) -> Option<(String, bool)> {
    const EMPTY: &str = "No goal is currently set.";
    let lines = rows(screen);
    let empty =
        |line: &str| line == EMPTY || line.starts_with("• Usage: /goal ") && line.ends_with(EMPTY);
    let start = lines
        .iter()
        .rposition(|line| line.starts_with("Status:") || empty(line))?;
    let (end, report) = if empty(lines[start]) {
        (start, (EMPTY.to_owned(), false))
    } else {
        // SSH can deliver the heading and objective before the footer: an incomplete report
        // never clears the live goal.
        let footer = start
            + lines[start..]
                .iter()
                .position(|line| line.starts_with("Commands: /goal"))?;
        if !lines[start..footer]
            .iter()
            .any(|line| line.starts_with("Objective:"))
        {
            return None;
        }
        (footer, (lines[start..footer].join("\n"), true))
    };
    let mut tail = lines[end + 1..].iter().skip_while(|line| line.is_empty());
    let composer = tail.clone().next().is_none_or(|line| line.starts_with('›'));
    (composer && !tail.any(|line| line.contains("/goal"))).then_some(report)
}

/// ChatNativeGoalEditor (ChatCommands.swift): the objective in Codex's goal editor ("" for its
/// placeholder), only while the editor is the last thing on screen.
pub fn editor(screen: &str) -> Option<String> {
    let lines = rows(screen);
    let start = lines
        .iter()
        .rposition(|line| *line == "▌ Edit goal" || *line == "Edit goal")?;
    let end = start + lines[start..].iter().position(|line| footer(line))?;
    if !lines[end + 1..].iter().all(|line| line.is_empty()) {
        return None;
    }
    let marker = if lines[start].starts_with('▌') {
        '▌'
    } else {
        '›'
    };
    let content = lines[start + 1..end]
        .iter()
        .filter_map(|line| line.strip_prefix(marker).map(str::trim))
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    Some(match content.as_str() {
        "Type a goal objective and press Enter" => String::new(),
        _ => content,
    })
}

/// ChatNativeFork.notice: what Codex prints once /fork created the fork.
pub const FORK: &str = "• Fork created. You can continue here.";

/// ChatNativeFork.created: a new fork notice appeared.
pub fn forked(before: &str, screen: &str) -> bool {
    let count = |text| rows(text).iter().filter(|line| **line == FORK).count();
    count(screen) > count(before)
}

/// ChatNativeReport.text (ChatCommands.swift): the report of /pwd, /recap, /ps or /mcp, once a
/// new copy is the last item above the idle composer.
pub fn report(command: &str, before: &str, screen: &str) -> Option<String> {
    let heading = |line: &str| match command {
        "/pwd" => line.starts_with("• Current working directory:"),
        "/recap" => line.starts_with("↳ Recap:"),
        "/ps" => line == "Background terminals",
        "/mcp" => line.ends_with("MCP Tools"),
        "/goal clear" => line == "• Goal cleared",
        "/goal" => line.starts_with("Status:") || line.ends_with("No goal is currently set."),
        _ => false,
    };
    let raw: Vec<_> = screen.split(NEWLINES).collect();
    let current: Vec<_> = raw.iter().map(|line| line.trim()).collect();
    let count = |lines: &[&str]| lines.iter().filter(|line| heading(line)).count();
    if screen.len() > 65_536 || count(&current) <= count(&rows(before)) {
        return None;
    }
    let composer = current.iter().rposition(|line| line.starts_with('›'))?;
    let start = current[..composer].iter().rposition(|line| heading(line))?;
    let after = &current[composer + 1..];
    if after.iter().filter(|line| !line.is_empty()).count() > 2
        || after.iter().any(|line| line.contains("esc to interrupt"))
    {
        return None;
    }
    let mut body = &current[start..composer];
    // Lists hold indented "•" items; single reports end at the next item.
    let list = matches!(command, "/ps" | "/mcp");
    if body[1..].iter().any(|line| {
        line.starts_with('■')
            || line.starts_with('›')
            || line.contains("esc to interrupt")
            || !list && (line.starts_with('•') || line.starts_with('↳'))
    }) {
        return None;
    }
    if list {
        let end = raw[start + 1..composer].iter().position(|line| {
            !line.trim().is_empty() && !line.starts_with(char::is_whitespace)
        });
        if let Some(end) = end { body = &body[..end + 1]; }
    }
    while body.last() == Some(&"") {
        body = &body[..body.len() - 1];
    }
    if list && body.len() == 1 {
        return None;
    }
    let after = |text: &str, prefix: &str| text[prefix.len()..].trim().to_owned();
    Some(match command {
        "/goal" => goal(screen)?.0,
        "/goal clear" => "Goal cleared.".into(),
        // A long path wraps onto indented continuation lines.
        "/pwd" => after(&body.concat(), "• Current working directory:"),
        "/recap" => {
            let lines = body.iter().filter(|line| !line.is_empty());
            let next = lines.clone().position(|line| line.starts_with("Next:"));
            let (summary, next): (Vec<_>, Vec<_>) = lines
                .enumerate()
                .partition(|(index, _)| next.is_none_or(|next| *index < next));
            let summary = summary
                .into_iter()
                .map(|(_, line)| *line)
                .collect::<Vec<_>>();
            let text = after(&summary.join(" "), "↳ Recap:");
            match next.is_empty() {
                true => text,
                false => {
                    let next = next.into_iter().map(|(_, line)| *line).collect::<Vec<_>>();
                    text + "\n\n" + &next.join(" ")
                }
            }
        }
        _ => {
            let items = body[1..].iter().skip_while(|line| line.is_empty());
            items.copied().collect::<Vec<_>>().join("\n")
        }
    })
}

/// ChatNativeShellResult.output (ChatCommands.swift): the output of `command` from its completed
/// "You ran"/"Ran" block above the restored idle composer.
pub fn shell(command: &str, before: &str, screen: &str) -> Option<String> {
    if screen == before || screen.len() > 65_536 || command.contains('\n') {
        return None;
    }
    let lines = rows(screen);
    let prompt = rows(before)
        .into_iter()
        .rev()
        .find(|line| line.starts_with('›'))?;
    let composer = lines.iter().rposition(|line| *line == prompt)?;
    let headings = [format!("• You ran {command}"), format!("• Ran {command}")];
    let start = lines[..composer]
        .iter()
        .rposition(|line| headings.iter().any(|heading| heading == line))?;
    let separator = start
        + 1
        + lines[start + 1..composer].iter().position(|line| {
            line.chars().count() >= 3 && line.chars().all(|character| character == '─')
        })?;
    let after = &lines[composer + 1..];
    if !lines[separator + 1..composer]
        .iter()
        .all(|line| line.is_empty())
        || after.iter().filter(|line| !line.is_empty()).count() > 2
        || after
            .iter()
            .any(|line| line.contains("esc to interrupt") || line.contains("confirm"))
    {
        return None;
    }
    let mut body: Vec<&str> = lines[start + 1..separator]
        .iter()
        .copied()
        .skip_while(|line| line.is_empty())
        .collect();
    let first = body.first()?.strip_prefix('└')?.trim();
    body[0] = first;
    while body.last() == Some(&"") {
        body.pop();
    }
    Some(body.join("\n"))
}

/// The prompt as one chat question whose options are its visible choices (core C-PROMPTS).
/// c1654cc ChatNativeStatus (ChatCommands.swift:148-177): the latest native /status block,
/// boxed (Codex 0.158 and older) or unbordered (0.159), with its session, thread name and text.
pub struct Status {
    pub session: String,
    pub name: Option<String>,
    pub mode: Option<String>,
    pub text: String,
}

pub fn status(screen: &str) -> Option<Status> {
    let lines: Vec<&str> = screen.split(NEWLINES).collect();
    let border = |character: char| character.is_whitespace() || character == '│';
    let stripped: Vec<&str> = lines.iter().map(|line| line.trim_matches(border)).collect();
    let start = stripped
        .iter()
        .rposition(|line| line.starts_with("Model:"))?;
    let end = if lines[start].contains('│') {
        start + lines[start..].iter().position(|line| line.contains('╰'))?
    } else {
        let next = stripped[start..]
            .iter()
            .position(|line| line.starts_with(['›', '•', '■']));
        next.map_or(lines.len(), |offset| start + offset)
    };
    // An echoed command below an old status box is not its response.
    if lines
        .iter()
        .skip(end + 1)
        .any(|line| line.contains("/status"))
    {
        return None;
    }
    let mut content = stripped[start..end].to_vec();
    while content.last() == Some(&"") {
        content.pop();
    }
    let field = |key: &str| {
        let line = content.iter().find(|line| {
            line.strip_prefix(key)
                .is_some_and(|rest| rest.starts_with(':'))
        })?;
        Some(line[key.len() + 1..].trim().to_owned())
    };
    let session = field("Session").filter(|id| crate::hooks::uuid(id))?;
    field("Permissions")?;
    Some(Status {
        session,
        name: field("Thread name"),
        mode: field("Collaboration mode").map(|mode| mode.to_lowercase()),
        text: content.join("\n"),
    })
}

pub fn interaction(screen: &Screen) -> Option<Interaction> {
    let prompt = prompt(&screen.text)?;
    let options = prompt.choices.iter().map(|(number, label)| Choice {
        id: number.to_string(),
        label: label.clone(),
        detail: None,
    });
    Some(Interaction {
        key: None,
        turn: None,
        record: None,
        id: format!("prompt:{}", prompt.title),
        approval: false,
        blocking: true,
        questions: vec![Question {
            id: "prompt".into(),
            header: prompt.title.lines().next().unwrap_or_default().into(),
            text: prompt.title.clone(),
            secret: false,
            options: options.collect(),
            multiple: false,
            custom: false,
            blocks: Vec::new(),
        }],
    })
}

/// ChatCommands.chooseCommandOption (:578-628): Up/Down to the chosen option (an index into the
/// published options), then Enter; Escape dismisses. Once the prompt left the screen (answered or
/// dismissed, the old wait for a changed screen) the walk is done.
fn choose(title: &str, choice: Option<u32>, screen: &Screen) -> Step {
    let Some(current) = prompt(&screen.text).filter(|current| current.title == title) else {
        return Step::Done(Menu {
            default: None,
            result: None,
            choices: Vec::new(),
            current: None,
        });
    };
    let Some(choice) = choice else {
        return Step::Keys(vec![Input::Key(Key::Escape)]);
    };
    let Some(&(target, _)) = current.choices.get(choice as usize) else {
        let message = "The question changed. Check the current question before answering.";
        return Step::Fail(failure("question", message));
    };
    let key = match target.cmp(&current.selected) {
        std::cmp::Ordering::Equal => Key::Enter,
        std::cmp::Ordering::Greater => Key::Down,
        std::cmp::Ordering::Less => Key::Up,
    };
    Step::Keys(vec![Input::Key(key)])
}

pub(crate) fn command(text: &str) -> Option<&'static str> {
    match text {
        "/goal" | "/goal clear" => Some("Goal"),
        "/status" => Some("Session status"),
        "/pwd" => Some("Working directory"),
        "/recap" => Some("Conversation recap"),
        "/mcp" => Some("MCP tools"),
        "/ps" => Some("Background terminals"),
        "/fork" => Some("Fork"),
        "/clear" | "/new" => Some("New conversation"),
        _ => None,
    }
}

pub(crate) fn step(binding: &Binding, goal: &Goal, screen: &Screen, walk: &mut Walk) -> Step {
    if let Goal::Choose { title, choice } = goal {
        return choose(title, *choice, screen);
    }
    if screen.text.len() > 65_536 {
        return Step::Fail(failure("menu", "The Codex menu is too large."));
    }
    // An explicit settings request captures its baseline before accepting a completion.
    // A menu observation without a request can still recognize an already completed selection.
    let opening = std::mem::take(&mut walk.opening);
    if opening {
        walk.before = Some(screen.text.clone());
    }
    let lines: Vec<_> = screen.text.lines().map(str::trim).collect();
    let title = lines.iter().rposition(|line| {
        *line == "Select Model"
            || *line == "Select Model and Effort"
            || line.starts_with("Select Reasoning Level for ")
            || *line == "Advanced Reasoning"
            || *line == "Apply reasoning change"
    });
    let Some(title) = title else {
        if (walk.submitted || walk.before.is_none())
            && let Goal::Select { model, effort } = goal
        {
            let expected = match effort {
                Some(effort) => format!("{model} {effort}"),
                None => model.clone(),
            };
            let reported = lines
                .iter()
                .rev()
                .find_map(|line| line.split_once("Model changed to ").map(|(_, value)| value))
                .is_some_and(|line| {
                    line.split(" for ").next().unwrap_or(line) == expected
                        && walk.before.as_ref().is_none_or(|before| {
                            screen.text.matches(line).count() > before.matches(line).count()
                        })
                });
            let label = walk
                .labels
                .iter()
                .find(|(id, _)| id == model)
                .map_or(model, |(_, label)| label);
            // Plan-only overrides update the footer without a history notice.
            let scoped = walk.submitted
                && walk.decision.is_some()
                && effort.as_ref().is_some_and(|effort| {
                    lines
                        .iter()
                        .any(|line| line.starts_with(&format!("{label} {effort} ·")))
                });
            if reported || scoped {
                return Step::Done(Menu {
                    default: None,
                    result: None,
                    choices: Vec::new(),
                    current: Some(model.clone()),
                });
            }
        }
        return match goal {
            Goal::Stop => Step::Keys(vec![Input::Key(Key::Escape)]),
            Goal::Send { .. } => Step::Fail(failure("menu", "Use the Codex send operation.")),
            _ if walk.before.is_some() && !opening => Step::Wait,
            _ => {
                walk.before = Some(screen.text.clone());
                Step::Keys(vec![Input::Paste("/model".into()), Input::Key(Key::Enter)])
            }
        };
    };
    walk.before.get_or_insert_with(|| screen.text.clone());
    if !lines[title + 1..].iter().any(|line| {
        line.contains("esc to go back")
            || line.starts_with("enter ") && line.ends_with(" · esc back")
    }) {
        return Step::Wait;
    }
    let mut choices = Vec::new();
    let mut current = None;
    for line in lines[title + 1..].iter().take(160) {
        let selected = line.starts_with('›');
        let line = line.trim_start_matches('›').trim_start();
        let Some((number, value)) = line.split_once(". ") else {
            continue;
        };
        if number.is_empty()
            || number.len() > 3
            || !number.bytes().all(|byte| byte.is_ascii_digit())
        {
            continue;
        }
        let end = value
            .char_indices()
            .find_map(|(index, character)| {
                (character.is_whitespace()
                    && value[index..]
                        .chars()
                        .nth(1)
                        .is_some_and(char::is_whitespace))
                .then_some(index)
            })
            .unwrap_or(value.len());
        let label = value[..end]
            .replace(" (current)", "")
            .replace(" (default)", "");
        if label.is_empty()
            || label.chars().count() >= 150
            || choices.iter().any(|choice: &Choice| choice.id == label)
        {
            return Step::Fail(failure("menu", "Invalid Codex model choices."));
        }
        if selected {
            current = Some(label.clone());
        }
        choices.push(Choice {
            id: label.clone(),
            label,
            detail: Some(value[end..].trim().into()),
        });
    }
    if choices.is_empty() || choices.len() > 100 || current.is_none() {
        return Step::Wait;
    }
    let menu = Menu {
        default: None,
        choices,
        current,
        result: None,
    };
    if lines[title] == "Apply reasoning change" {
        let interaction = Interaction {
            key: None,
            id: format!("menu:{}", binding.session),
            turn: None,
            record: None,
            approval: false,
            blocking: true,
            questions: vec![Question {
                id: "scope".into(),
                header: lines[title].into(),
                text: lines[title].into(),
                options: menu.choices.clone(),
                secret: false,
                multiple: false,
                custom: false,
                blocks: Vec::new(),
            }],
        };
        let Some(target) = walk.decision else {
            walk.submitted = false;
            walk.scope = Some(interaction.clone());
            return Step::Ask(interaction);
        };
        if walk.scope.as_ref() != Some(&interaction) {
            return Step::Fail(failure("question", "The model confirmation changed."));
        }
        if walk.submitted {
            return Step::Wait;
        }
        let selected = menu
            .choices
            .iter()
            .position(|choice| Some(&choice.id) == menu.current.as_ref())
            .unwrap();
        let key = match target.cmp(&selected) {
            std::cmp::Ordering::Equal => {
                walk.submitted = true;
                Key::Enter
            }
            std::cmp::Ordering::Greater => Key::Down,
            std::cmp::Ordering::Less => Key::Up,
        };
        return Step::Keys(vec![Input::Key(key)]);
    }
    match goal {
        Goal::Models if lines[title].starts_with("Select Model") => Step::Done(menu),
        Goal::Efforts { model }
            if lines[title] == format!("Select Reasoning Level for {model}") =>
        {
            Step::Done(menu)
        }
        Goal::Select { model, .. } | Goal::Efforts { model } => {
            let reasoning = lines[title].starts_with("Select Reasoning")
                || lines[title] == "Advanced Reasoning";
            let desired = if reasoning {
                match goal {
                    Goal::Select { effort, .. } => effort.as_deref().unwrap_or("medium"),
                    _ => return Step::Done(menu),
                }
            } else {
                model
            };
            let label = walk
                .labels
                .iter()
                .find(|(id, _)| id == desired)
                .map(|(_, label)| label);
            let target = menu
                .choices
                .iter()
                .position(|choice| {
                    choice.id.eq_ignore_ascii_case(desired)
                        || label.is_some_and(|label| &choice.id == label)
                        || desired == "xhigh" && choice.id == "Extra high"
                })
                .or_else(|| {
                    menu.choices.iter().position(|choice| {
                        if reasoning {
                            choice.id.starts_with("More reasoning")
                        } else {
                            choice.id == "All models"
                        }
                    })
                });
            let selected = menu
                .choices
                .iter()
                .position(|choice| Some(&choice.id) == menu.current.as_ref())
                .unwrap();
            let Some(target) = target else {
                return Step::Fail(failure("menu", "The selected Codex option is unavailable."));
            };
            let key = match target.cmp(&selected) {
                std::cmp::Ordering::Equal => {
                    if menu.choices[target].id != "All models"
                        && !menu.choices[target].id.starts_with("More reasoning")
                    {
                        walk.submitted = true;
                    }
                    Key::Enter
                }
                std::cmp::Ordering::Greater => Key::Down,
                std::cmp::Ordering::Less => Key::Up,
            };
            Step::Keys(vec![Input::Key(key)])
        }
        _ => Step::Fail(failure("menu", "Unexpected Codex menu.")),
    }
}
