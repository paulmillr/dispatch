//! UI request schemas, checked on the decoded binary request.
use super::invalid;
use crate::{api::Error, json::Data};

#[derive(Clone, Copy)]
pub(super) enum Rule {
    Any,
    Text,
    Boolean,
    Unsigned,
    Signed,
    Decimal,
    Bytes,
    Stamp,
    Array(&'static Rule),
    Object(&'static [(&'static str, Rule)]),
    Nullable(&'static Rule),
}

pub(super) const GRID: &[(&str, Rule)] = &[
    ("rows", Rule::Unsigned),
    ("columns", Rule::Unsigned),
    ("cell_width", Rule::Unsigned),
    ("cell_height", Rule::Unsigned),
];
pub(super) const CURSOR: &[(&str, Rule)] = &[("column", Rule::Unsigned), ("row", Rule::Unsigned)];
pub(super) const BINDING: &[(&str, Rule)] = &[
    ("session", Rule::Text),
    ("pid", Rule::Unsigned),
    ("start", Rule::Array(&Rule::Unsigned)),
];
pub(super) const PLACE: &[(&str, Rule)] = &[
    ("kind", Rule::Text),
    ("parent", Rule::Unsigned),
    ("before", Rule::Unsigned),
    ("label", Rule::Text),
    ("workspace", Rule::Unsigned),
    ("target", Rule::Unsigned),
    ("axis", Rule::Text),
    ("ratio", Rule::Decimal),
];
pub(super) const TRANSCRIPT: &[(&str, Rule)] = &[
    ("key", Rule::Text),
    ("path", Rule::Text),
    ("session", Rule::Text),
    ("earlier", Rule::Nullable(&Rule::Text)),
];
pub(super) const REVISION: &[(&str, Rule)] = &[
    ("kind", Rule::Text),
    ("size", Rule::Unsigned),
    ("device", Rule::Unsigned),
    ("inode", Rule::Unsigned),
    ("modified_ns", Rule::Stamp),
    ("changed_ns", Rule::Stamp),
];

pub(super) fn validate(value: &Data<'_>, rule: Rule, name: &str) -> Result<(), Error> {
    // The binary reader already refuses duplicate keys.
    let mut pending = vec![(value, rule, name)];
    loop {
        let Some((value, mut rule, name)) = pending.pop() else {
            return Ok(());
        };
        if let Rule::Nullable(inner) = rule {
            if matches!(value, Data::Null) {
                continue;
            }
            rule = *inner;
        }
        let valid = match rule {
            Rule::Text => value.string().is_some(),
            Rule::Boolean => value.boolean().is_some(),
            Rule::Unsigned => value.unsigned().is_some(),
            Rule::Signed => value.signed().is_some(),
            Rule::Decimal => value.number().is_some(),
            Rule::Bytes => value.bytes().is_some(),
            Rule::Stamp => {
                value.string().is_some_and(|s| s.parse::<i128>().is_ok()) || value.signed().is_some()
                    || value.unsigned().is_some()
            }
            Rule::Array(item) => {
                pending.extend(value.array().ok_or_else(|| invalid(name))?.map(|value| (value, *item, name)));
                true
            }
            Rule::Object(_) | Rule::Any => {
                if let Some(values) = value.object() {
                    for (key, value) in values {
                        let item = if let Rule::Object(fields) = rule {
                            fields.iter().find(|(name, _)| *name == key).map(|(_, rule)| *rule).ok_or_else(|| invalid(key))?
                        } else {
                            Rule::Any
                        };
                        pending.push((value, item, key));
                    }
                    true
                } else if matches!(rule, Rule::Any) {
                    if let Some(values) = value.array() {
                        pending.extend(values.map(|value| (value, Rule::Any, name)));
                    }
                    true
                } else {
                    false
                }
            }
            Rule::Nullable(_) => unreachable!("nullable schema is unwrapped above"),
        };
        if !valid {
            return Err(invalid(name));
        }
    }
}
