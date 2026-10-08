//! Pi command screen rules, moved from the original PiCommandScreen adapter.

fn parts(screen: &str) -> Option<(Vec<&str>, Vec<&str>)> {
    if screen.len() > 65_536 {
        return None;
    }
    let lines: Vec<_> = screen.split('\n').map(str::trim).collect();
    let rules: Vec<_> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| rule(line))
        .map(|(index, _)| index)
        .collect();
    let [.., top, bottom] = rules.as_slice() else {
        return None;
    };
    Some((
        lines[..*top]
            .iter()
            .copied()
            .filter(|line| !line.is_empty() && !rule(line))
            .collect(),
        lines[top + 1..*bottom]
            .iter()
            .copied()
            .filter(|line| !line.is_empty())
            .collect(),
    ))
}

fn rule(line: &str) -> bool {
    !line.is_empty() && line.chars().all(|character| character == '─')
}

pub fn state(screen: &str) -> Option<&'static str> {
    let (above, editor) = parts(screen)?;
    if above
        .iter()
        .rev()
        .take(2)
        .any(|line| line.contains("to interrupt") || line.contains("to cancel)")
            || line.chars().next().is_some_and(|character| ('\u{2800}'..='\u{28ff}').contains(&character))
                && line.contains("Working"))
    {
        return Some("working");
    }
    if editor.is_empty() {
        return Some("idle");
    }
    let selector = editor.iter().any(|line| {
        let lower = line.to_lowercase();
        let counter = line
            .strip_prefix('(')
            .and_then(|line| line.strip_suffix(')'))
            .and_then(|line| line.split_once('/'))
            .is_some_and(|(left, right)| {
                [left, right].iter().all(|digits| {
                    !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
                })
            });
        line.starts_with('→')
            || line.starts_with('›')
            || lower.contains("cancel")
            || lower.contains("navigate")
            || lower.contains("enter to select")
            || lower.contains("enter toggle")
            || counter
    });
    Some(if selector { "selector" } else { "working" })
}

pub fn output(before: &str, screen: &str) -> Option<String> {
    if state(screen) != Some("idle") {
        return None;
    }
    let (previous, _) = parts(before)?;
    let anchor = previous.last()?;
    let (above, _) = parts(screen)?;
    let index = above.iter().rposition(|line| line == anchor)?;
    let added = &above[index + 1..];
    (!added.is_empty()).then(|| added.join("\n"))
}

#[derive(Default)]
pub struct Command {
    before: Option<String>,
}
impl Command {
    pub fn step(
        &mut self,
        text: &str,
        screen: &dispatch_helper4_core::api::Screen,
        settled: bool,
    ) -> dispatch_helper4_core::api::Step {
        use dispatch_helper4_core::api::{Menu, Step};
        if let Some(before) = &self.before {
            if state(&screen.text) == Some("selector") {
                return Step::Fail(crate::bridge::fail(
                    "attention",
                    "Pi needs an answer in Terminal. Your Chat draft is preserved.",
                ));
            }
            if let Some(output) = output(before, &screen.text) {
                return Step::Done(Menu {
                    result: Some((
                        text.trim().into(),
                        output,
                    )),
                    ..Menu::default()
                });
            }
            if settled && state(&screen.text) == Some("idle") && screen.text != *before {
                return Step::Done(Menu::default());
            }
            return Step::Wait;
        }
        if state(&screen.text) != Some("idle") {
            return Step::Wait;
        }
        self.before = Some(screen.text.clone());
        Step::Keys(crate::harness::Pi::input(text))
    }
}
