//! Native model/list fields, preserving the existing catalog projection.
use dispatch_helper_core::{
    api::{Choice, Error, State},
    json::{self, Data, Json, Kind, Value},
};
use std::collections::BTreeSet;

pub fn goal(value: Value<'_>) -> std::option::Option<String> {
    let mut fields = vec![
        ("objective", Data::String(value.get("objective")?.string()?)),
        ("status", Data::String(value.get("status")?.string()?)),
        (
            "tokensUsed",
            Data::Signed(value.get("tokensUsed").and_then(Value::signed).unwrap_or(0)),
        ),
        (
            "timeUsedSeconds",
            Data::Signed(
                value
                    .get("timeUsedSeconds")
                    .and_then(Value::signed)
                    .unwrap_or(0),
            ),
        ),
    ];
    if let Some(budget) = value.get("tokenBudget").and_then(Value::signed) {
        fields.push(("tokenBudget", Data::Signed(budget)));
    }
    String::from_utf8(json::write(&Data::Object(fields)).ok()?).ok()
}

/// The thread title: `name` of a read/resumed thread, `threadName` of thread/name/updated; null
/// clears it (c1654cc CodexPatchConnection.swift:374,442).
pub fn title(value: Value<'_>) -> std::option::Option<String> {
    let name = value.get("threadName").or_else(|| value.get("name"));
    name.and_then(Value::string).map(str::to_owned)
}

pub fn settings(value: Value<'_>, state: &mut State) {
    state.mode = value.get("collaborationMode").or_else(|| value.get("collaboration_mode"))
        .and_then(|mode| mode.get("mode"))
        .and_then(Value::string).map(str::to_owned);
    state.model = value
        .get("model")
        .and_then(Value::string)
        .map(str::to_owned);
    state.effort = value
        .get("effort")
        .or_else(|| value.get("reasoning_effort"))
        .and_then(Value::string)
        .map(str::to_owned);
    state.service_tier = value
        .get("serviceTier")
        .and_then(Value::string)
        .map(str::to_owned);
}

pub fn usage(value: Value<'_>) -> std::option::Option<String> {
    let api = value.get("tokenUsage");
    let info = api.or_else(|| value.get("info"))?;
    let read = |value: std::option::Option<Value<'_>>| {
        value.and_then(Value::signed).filter(|count| *count >= 0)
    };
    let field = |object: std::option::Option<Value<'_>>, native, retained| {
        read(object.and_then(|value| value.get(if api.is_some() { native } else { retained })))
    };
    let total = info.get(if api.is_some() {
        "total"
    } else {
        "total_token_usage"
    });
    let last = info.get(if api.is_some() {
        "last"
    } else {
        "last_token_usage"
    });
    let input = field(total, "inputTokens", "input_tokens");
    let output = field(total, "outputTokens", "output_tokens");
    let tokens = field(last, "totalTokens", "total_tokens");
    let window = field(Some(info), "modelContextWindow", "model_context_window");
    let cost = info
        .get("total_cost_usd")
        .and_then(Value::number)
        .filter(|cost| cost.is_finite() && *cost >= 0.0);
    if [input, output, tokens, window]
        .iter()
        .all(std::option::Option::is_none)
        && cost.is_none()
    {
        return None;
    }
    let counters = |fields: &[(&'static str, std::option::Option<i64>)]| {
        Data::Object(
            fields
                .iter()
                .filter_map(|(name, value)| value.map(|value| (*name, Data::Signed(value))))
                .collect(),
        )
    };
    let mut fields = vec![
        (
            "total_token_usage",
            counters(&[("input_tokens", input), ("output_tokens", output)]),
        ),
        ("last_token_usage", counters(&[("total_tokens", tokens)])),
    ];
    if let Some(window) = window {
        fields.push(("model_context_window", Data::Signed(window)));
    }
    if let Some(cost) = cost {
        fields.push(("total_cost_usd", Data::Real(cost)));
    }
    String::from_utf8(json::write(&Data::Object(vec![("info", Data::Object(fields))])).ok()?).ok()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Option {
    pub choice: Choice,
    pub description: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub choice: Choice,
    pub native: String,
    pub description: String,
    pub default: bool,
    pub hidden: bool,
    pub efforts: Vec<Option>,
    pub effort: String,
    pub tiers: Vec<Option>,
    pub tier: std::option::Option<String>,
    pub inputs: Vec<String>,
    pub personality: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Catalog {
    pub models: Vec<Model>,
    pub cursor: std::option::Option<String>,
}

fn invalid() -> Error {
    Error {
        code: "json",
        message: "Invalid Codex model catalog".into(),
    }
}

fn fields(value: Value<'_>) -> Result<Value<'_>, Error> {
    // Existing native catalog bounds all object keys and array items at 16,384.
    if value.object().ok_or_else(invalid)?.take(16_385).count() > 16_384 {
        return Err(invalid());
    }
    Ok(value)
}

fn text(value: std::option::Option<Value<'_>>) -> Result<std::option::Option<String>, Error> {
    let Some(value) = value.filter(|value| value.kind() != Kind::Null) else {
        return Ok(None);
    };
    Ok(Some(value.string().ok_or_else(invalid)?.into()))
}

fn string(fields: Value<'_>, name: &str) -> Result<String, Error> {
    text(fields.get(name))?.ok_or_else(invalid)
}

fn flag(fields: Value<'_>, name: &str, default: std::option::Option<bool>) -> Result<bool, Error> {
    match fields.get(name) {
        Some(value) => value.boolean().ok_or_else(invalid),
        None => default.ok_or_else(invalid),
    }
}

fn array(value: Value<'_>) -> Result<Vec<Value<'_>>, Error> {
    let values: Vec<_> = value.array().ok_or_else(invalid)?.take(16_385).collect();
    if values.len() > 16_384 {
        return Err(invalid());
    }
    Ok(values)
}

impl Option {
    fn read(
        value: Value<'_>,
        id: &str,
        label: std::option::Option<&str>,
    ) -> Result<Vec<Self>, Error> {
        let mut seen = BTreeSet::new();
        array(value)?
            .into_iter()
            .map(|value| {
                let fields = fields(value)?;
                let id = string(fields, id)?;
                if id.is_empty() || !seen.insert(id.clone()) {
                    return Err(invalid());
                }
                let description = string(fields, "description")?;
                Ok(Self {
                    choice: Choice {
                        label: match label {
                            Some(name) => string(fields, name)?,
                            None => id.clone(),
                        },
                        id,
                        detail: Some(description.clone()),
                    },
                    description,
                })
            })
            .collect()
    }
}

pub fn catalog(bytes: &[u8]) -> Result<Catalog, Error> {
    // Preserve the existing model/list page's 4 MiB input bound.
    if bytes.len() > 4 * 1_048_576 {
        return Err(invalid());
    }
    let document = Json::parse(bytes)?;
    let root = fields(document.root())?;
    let mut seen = BTreeSet::new();
    let models = array(root.get("data").ok_or_else(invalid)?)?
        .into_iter()
        .map(|value| {
            let fields = fields(value)?;
            let description = string(fields, "description")?;
            let model = Model {
                choice: Choice {
                    id: string(fields, "id")?,
                    label: string(fields, "displayName")?,
                    detail: Some(description.clone()),
                },
                native: string(fields, "model")?,
                description,
                default: flag(fields, "isDefault", None)?,
                hidden: flag(fields, "hidden", None)?,
                efforts: Option::read(
                    fields
                        .get("supportedReasoningEfforts")
                        .ok_or_else(invalid)?,
                    "reasoningEffort",
                    None,
                )?,
                effort: string(fields, "defaultReasoningEffort")?,
                tiers: match fields.get("serviceTiers") {
                    Some(value) => Option::read(value, "id", Some("name"))?,
                    None => Vec::new(),
                },
                tier: text(fields.get("defaultServiceTier"))?,
                inputs: match fields.get("inputModalities") {
                    Some(value) => array(value)?
                        .into_iter()
                        .map(|value| text(Some(value))?.ok_or_else(invalid))
                        .collect::<Result<_, _>>()?,
                    None => vec!["text".into(), "image".into()],
                },
                personality: flag(fields, "supportsPersonality", Some(false))?,
            };
            if model.choice.id.is_empty() || model.native.is_empty() || model.effort.is_empty() {
                return Err(invalid());
            }
            if !seen.insert(model.choice.id.clone()) {
                return Err(invalid());
            }
            Ok(model)
        })
        .collect::<Result<_, _>>()?;
    Ok(Catalog {
        models,
        cursor: text(root.get("nextCursor"))?,
    })
}
