//! projects.recent: the folders agents worked in on this host, newest first, from their own
//! session stores (Claude Code projects, Codex rollouts, Pi sessions). Reads only: the first
//! line of a bounded number of session files and their modification times.
use crate::json::{Data, Json};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

/// Session files read per agent; a session header is in its first HEADER bytes.
const FILES: usize = 400;
const HEADER: u64 = 64 * 1024;

#[derive(Default)]
struct Project {
    time_ms: i64,
    agents: Vec<&'static str>,
}

fn modified(path: &Path) -> Option<i64> {
    let time = fs::metadata(path).ok()?.modified().ok()?;
    i64::try_from(time.duration_since(UNIX_EPOCH).ok()?.as_millis()).ok()
}

/// Regular `*.jsonl` files directly under `directory`, newest first, at most `limit`.
fn sessions(directory: &Path, limit: usize) -> Vec<(i64, PathBuf)> {
    let mut files: Vec<_> = fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .take(10_000)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
        .filter_map(|path| Some((modified(&path)?, path)))
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.truncate(limit);
    files
}

fn directories(directory: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<_> = fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .take(10_000)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    entries.sort();
    entries
}

/// The first `cwd` of a session file: a top-level "cwd" (Claude, Pi) or "payload.cwd" (Codex
/// session_meta), within the first lines of the file.
fn cwd(path: &Path) -> Option<PathBuf> {
    let mut bytes = Vec::new();
    crate::system::file::open(path).ok()?.take(HEADER).read_to_end(&mut bytes).ok()?;
    for line in bytes.split(|byte| *byte == b'\n').take(16) {
        let Ok(json) = Json::parse(line) else { continue };
        let root = json.root();
        let value = root
            .get("cwd")
            .or_else(|| root.get("payload").and_then(|payload| payload.get("cwd")))
            .and_then(|value| value.string());
        if let Some(value) = value.filter(|value| value.starts_with('/') && value.len() <= 4096 && !value.contains('\0')) {
            return Some(PathBuf::from(value));
        }
    }
    None
}

fn add(projects: &mut BTreeMap<PathBuf, Project>, agent: &'static str, files: Vec<(i64, PathBuf)>) {
    for (time, file) in files {
        let Some(folder) = cwd(&file) else { continue };
        let project = projects.entry(folder).or_default();
        project.time_ms = project.time_ms.max(time);
        if !project.agents.contains(&agent) {
            project.agents.push(agent);
        }
    }
}

/// `{claude, codex, pi}`: the agents' config roots (null: skip); `limit`: rows returned.
pub(super) fn collect(input: &Data<'_>) -> io::Result<Vec<u8>> {
    let root = |name| input.get(name).and_then(Data::path).map(Path::to_path_buf);
    let limit = input.get("limit").and_then(Data::unsigned).unwrap_or(30).clamp(1, 200) as usize;
    let mut projects = BTreeMap::new();
    if let Some(claude) = root("claude") {
        // One folder per project; its newest conversation names the folder and the time.
        let mut files: Vec<_> = directories(&claude.join("projects"))
            .iter()
            .filter_map(|folder| sessions(folder, 1).pop())
            .collect();
        files.sort_by(|a, b| b.0.cmp(&a.0));
        files.truncate(FILES);
        add(&mut projects, "claude", files);
    }
    if let Some(pi) = root("pi") {
        let mut files: Vec<_> = directories(&pi.join("sessions"))
            .iter()
            .filter_map(|folder| sessions(folder, 1).pop())
            .collect();
        files.sort_by(|a, b| b.0.cmp(&a.0));
        files.truncate(FILES);
        add(&mut projects, "pi", files);
    }
    if let Some(codex) = root("codex") {
        // sessions/YYYY/MM/DD/rollout-*.jsonl: the newest days first, FILES rollouts at most.
        let mut files = Vec::new();
        'walk: for year in directories(&codex.join("sessions")).into_iter().rev() {
            for month in directories(&year).into_iter().rev() {
                for day in directories(&month).into_iter().rev() {
                    files.extend(sessions(&day, FILES - files.len()));
                    if files.len() >= FILES {
                        break 'walk;
                    }
                }
            }
        }
        add(&mut projects, "codex", files);
    }
    let mut rows: Vec<_> = projects.into_iter().collect();
    rows.sort_by(|a, b| b.1.time_ms.cmp(&a.1.time_ms).then_with(|| a.0.cmp(&b.0)));
    rows.truncate(limit);
    let rows: Vec<_> = rows
        .iter()
        .filter_map(|(path, project)| {
            Some(Data::Object(vec![
                // Folders come from JSON strings: UTF-8, sent as text like every wire path.
                ("path", Data::String(path.to_str()?)),
                ("time_ms", Data::Signed(project.time_ms)),
                ("agents", Data::Array(project.agents.iter().map(|agent| Data::String(*agent)).collect())),
                ("exists", Data::Bool(path.is_dir())),
            ]))
        })
        .collect();
    crate::wire::body::encode_plain(&Data::Array(rows)).map_err(|_| super::invalid())
}

#[cfg(test)]
#[path = "projects.test.rs"]
mod tests;
