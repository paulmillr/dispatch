//! `chat.limits` for Codex: the ChatGPT plan's usage windows from the App Server's `account/rateLimits/read`, or,
//! where that cannot answer, the newest `token_count` of the session's rollout. Nothing is written, and only the
//! windows are kept. docs/security.md, Agent chat.
use crate::jobs::{self, Jobs};
use dispatch_helper_core::{
    api::*,
    json::{Json, Kind, Policy, Value},
};
use std::path::PathBuf;

/// How far back a rollout is searched: its newest turn is at the end.
const TAIL: u64 = 1_048_576;

/// The field names of a window: the App Server's, then the rollout's.
const API: [&str; 3] = ["usedPercent", "windowDurationMins", "resetsAt"];
const ROLLOUT: [&str; 3] = ["used_percent", "window_minutes", "resets_at"];

fn window(value: Value<'_>, [used, minutes, resets]: [&str; 3]) -> Option<(u64, LimitWindow)> {
    let used = value.get(used)?.number().filter(|n| n.is_finite() && *n >= 0.0 && *n <= 1000.0)?;
    let minutes = value.get(minutes)?.number().filter(|n| n.is_finite() && *n > 0.0 && *n < 1e9)? as u64;
    let resets = value.get(resets)?.number().filter(|n| n.is_finite() && *n > 0.0 && *n < 1e12)? as u64;
    // By length, never by position: `primary` is the weekly window on a plan with no 5-hour one.
    let name = match minutes {
        300 => "five_hour".to_owned(),
        10080 => "seven_day".to_owned(),
        other => format!("window_{other}"),
    };
    Some((minutes, LimitWindow(name, used.round() as u64, resets)))
}

fn windows(limits: Value<'_>, fields: [&str; 3]) -> Vec<LimitWindow> {
    let mut found = ["primary", "secondary"]
        .into_iter()
        .filter_map(|slot| window(limits.get(slot)?, fields))
        .collect::<Vec<_>>();
    found.sort_by_key(|(minutes, _)| *minutes);
    found.into_iter().map(|(_, window)| window).collect()
}

/// The windows of an `account/rateLimits/read` answer.
pub(crate) fn answered(root: Value<'_>) -> Vec<LimitWindow> {
    root.get("rateLimits").map_or_else(Vec::new, |limits| windows(limits, API))
}

/// The newest windows a rollout's tail records; None when no `token_count` there has any.
fn recorded(bytes: &[u8]) -> Option<Vec<LimitWindow>> {
    const NAME: &[u8] = b"\"rate_limits\"";
    bytes.split(|byte| *byte == b'\n').rev().filter(|line| line.windows(NAME.len()).any(|part| part == NAME)).find_map(|line| {
        let document = Json::parse_with(line, Policy::Foundation).ok()?;
        let root = document.root();
        let payload = root.get("payload")?;
        if root.get("type")?.string() != Some("event_msg") || payload.get("type")?.string() != Some("token_count") {
            return None;
        }
        let limits = payload.get("rate_limits").filter(|value| value.kind() == Kind::Object)?;
        Some(windows(limits, ROLLOUT)).filter(|found| !found.is_empty())
    })
}

/// Whether an answer says the account has no ChatGPT sign-in (an API key): nothing to report, not a failure.
pub(crate) fn signed_out(error: &Error) -> bool {
    error.message.contains("authentication required")
}

fn answer(io: &mut dyn Io, found: Option<Vec<LimitWindow>>, failure: Option<Error>, done: Done<Vec<LimitWindow>>) {
    let result = match (found, failure) {
        (Some(found), _) => Ok(found),
        (None, Some(failure)) => Err(failure),
        (None, None) => Ok(Vec::new()),
    };
    deferred(done)(io, result);
}

/// The App Server could not answer: the rollout's newest windows, else `failure`, else none.
pub(crate) fn from_rollout(
    jobs: &Jobs,
    io: &mut dyn Io,
    transcript: Option<PathBuf>,
    failure: Option<Error>,
    done: Done<Vec<LimitWindow>>,
) {
    let Some(path) = transcript else {
        return answer(io, None, failure, done);
    };
    let (reader, target) = (jobs.clone(), path.clone());
    jobs::submit(
        jobs,
        io,
        Job::Stat { path, follow: true },
        Box::new(move |io, result| {
            let Ok(Output::Metadata(metadata)) = result else {
                return answer(io, None, failure, done);
            };
            let offset = metadata.size.saturating_sub(TAIL);
            jobs::submit(
                &reader,
                io,
                Job::Read { path: target, offset, length: metadata.size - offset },
                Box::new(move |io, result| {
                    let found = match result {
                        Ok(Output::Read { bytes, .. }) => recorded(&bytes),
                        _ => None,
                    };
                    answer(io, found, failure, done);
                }),
            );
        }),
    );
}

#[cfg(test)]
#[path = "limits.test.rs"]
mod tests;
