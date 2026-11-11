//! `chat.limits.rows`: what a Pi limits extension reports. The extension is the user's, its text is not trusted: only
//! a few short plain rows get through.
use dispatch_helper_core::{
    api::*,
    json::Value,
};

const ROWS: usize = 6;
const TEXT: usize = 48;
const NAME: usize = 64;

/// No control, line-separator or bidi characters, trimmed, at most `TEXT` long.
fn plain(value: Option<Value<'_>>) -> Option<String> {
    let text = value?.string()?;
    let kept = text
        .chars()
        .filter(|c| !c.is_control() && !matches!(*c, '\u{2028}' | '\u{2029}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
        .take(TEXT)
        .collect::<String>();
    Some(kept.trim().to_owned()).filter(|text| !text.is_empty())
}

fn row(value: Value<'_>) -> Option<LimitRow> {
    let used = value.get("used").and_then(Value::number).filter(|n| n.is_finite() && (0.0..=100.0).contains(n)).map(|n| n.round() as u64);
    Some(LimitRow(plain(value.get("label"))?, plain(value.get("detail")).unwrap_or_default(), plain(value.get("value"))?, used))
}

/// An extension's name: what the user agrees to, so one spelling only.
fn name(value: Option<Value<'_>>) -> Option<String> {
    let name = value?.string()?;
    (!name.is_empty() && name.len() <= NAME && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b)))
        .then(|| name.to_owned())
}

/// The bridge's answer; a source with an unusable name counts as none.
pub(crate) fn parsed(root: Value<'_>) -> LimitRows {
    let Some(source) = name(root.get("source")) else {
        return LimitRows(None, Vec::new());
    };
    let rows = root.get("rows").and_then(Value::array).into_iter().flatten().take(ROWS).filter_map(row).collect();
    LimitRows(Some(source), rows)
}

#[cfg(test)]
#[path = "limits.test.rs"]
mod tests;
