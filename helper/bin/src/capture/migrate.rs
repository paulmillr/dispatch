//! `capture migrate REPLAYS MIGRATIONS [--check] [--dry-run] [--retired DIR] [--jobs N]`: brings the corpus up to the
//! code (docs/replay.md, Migrations). MIGRATIONS holds the ordered migrations (`NNNN-name.json`) and the wire
//! dictionaries of every schema the corpus was recorded with (`wire/<schema>.json`); REPLAYS/MIGRATIONS lists those
//! applied. Each pending one runs in order:
//!
//! - `baseline`: the corpus as it was when migrations began; applied to every corpus without a ledger.
//! - `wire`: every capture of another schema written in this helper's, with the named reviewed `edits` (`convert`).
//! - `rewrite`: in the inputs the app recorded (`open.*` records' arguments) only, each `old` template replaced by its
//!   `new` one, as written and as shell-quoted inside `'…'`. Recorded results are never touched: a rewrite is right only
//!   where the new code would get the same answers, which replay then checks.
//! - `rerecord`: tests whose answers changed: their recordings move out of the corpus (to DIR, `build/retired-replays`
//!   beside REPLAYS by default), so they run live until recorded again.
//!
//! A migration's `fingerprints` name what the code generates for recorded inputs once it applies (checked by
//! `ReplayMigrationTests` and `the_current_schema_has_its_dictionary_and_migration`).
use super::*;

#[derive(Debug)]
pub(super) struct Migration {
    pub id: String,
    pub kind: Kind,
    pub fingerprints: Vec<(String, String)>,
}

#[derive(Debug)]
pub(super) enum Kind {
    Baseline,
    Wire { edits: Vec<String> },
    Rewrite { ops: Vec<String>, pairs: Vec<(Template, Template)> },
    Rerecord { tests: Vec<String> },
}

/// Literal text with `{{name}}` slots. A slot matches a run of letters, digits, `.`, `_` and `-` (a digest, a session,
/// a staging folder, a size); a slot named twice must match the same text both times.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Template {
    parts: Vec<Part>,
}

#[derive(Debug, Clone, PartialEq)]
enum Part {
    Text(String),
    Slot(String),
}

impl Template {
    pub fn parse(text: &str) -> io::Result<Self> {
        let mut parts = Vec::new();
        let mut rest = text;
        while let Some(start) = rest.find("{{") {
            let end = rest[start..].find("}}").ok_or_else(|| io::Error::other(format!("unclosed slot in {text:?}")))? + start;
            if start > 0 {
                parts.push(Part::Text(rest[..start].to_owned()));
            }
            let name = &rest[start + 2..end];
            if name.is_empty() || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_') {
                return Err(io::Error::other(format!("bad slot name {name:?}")));
            }
            parts.push(Part::Slot(name.to_owned()));
            rest = &rest[end + 2..];
        }
        if !rest.is_empty() {
            parts.push(Part::Text(rest.to_owned()));
        }
        if !matches!(parts.first(), Some(Part::Text(_))) {
            return Err(io::Error::other(format!("a template starts with text: {text:?}")));
        }
        if parts.windows(2).any(|pair| matches!(pair, [Part::Slot(_), Part::Slot(_)])) {
            return Err(io::Error::other(format!("two slots need text between them: {text:?}")));
        }
        Ok(Self { parts })
    }

    fn slots(&self) -> HashSet<&str> {
        self.parts.iter().filter_map(|part| if let Part::Slot(name) = part { Some(name.as_str()) } else { None }).collect()
    }

    /// The template as it stands inside a shell-quoted argument (`'` written `'"'"'`, as HerdrLaunch.quote does).
    fn quoted(&self) -> Self {
        let parts = self.parts.iter().map(|part| match part {
            Part::Text(text) => Part::Text(text.replace('\'', "'\"'\"'")),
            slot => slot.clone(),
        });
        Self { parts: parts.collect() }
    }

    /// The first match at or after `from`: its range and its slots' values.
    fn find(&self, text: &str, from: usize) -> Option<(Range<usize>, HashMap<String, String>)> {
        let Some(Part::Text(lead)) = self.parts.first() else { return None };
        let mut search = from;
        while let Some(found) = text.get(search..).and_then(|rest| rest.find(lead.as_str())) {
            let start = search + found;
            if let Some((end, slots)) = self.matched(text, start) {
                return Some((start..end, slots));
            }
            search = start + lead.len().max(1);
        }
        None
    }

    fn matched(&self, text: &str, start: usize) -> Option<(usize, HashMap<String, String>)> {
        let (mut at, mut slots) = (start, HashMap::new());
        for part in &self.parts {
            match part {
                Part::Text(literal) => {
                    if !text.get(at..)?.starts_with(literal.as_str()) {
                        return None;
                    }
                    at += literal.len();
                }
                Part::Slot(name) => {
                    let length = text[at..].bytes()
                        .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')).count();
                    if length == 0 {
                        return None;
                    }
                    let value = &text[at..at + length];
                    if slots.get(name).is_some_and(|known: &String| known != value) {
                        return None;
                    }
                    slots.insert(name.clone(), value.to_owned());
                    at += length;
                }
            }
        }
        Some((at, slots))
    }

    fn fill(&self, slots: &HashMap<String, String>) -> String {
        self.parts.iter().map(|part| match part {
            Part::Text(text) => text.as_str(),
            Part::Slot(name) => slots.get(name).map_or("", String::as_str),
        }).collect()
    }
}

/// `text` with every match of each pair's old template replaced by its new one, in order, as written and as quoted:
/// None when nothing matched.
pub(super) fn replaced(text: &str, pairs: &[(Template, Template)]) -> Option<(String, usize)> {
    let (mut text, mut count) = (text.to_owned(), 0);
    for (old, new) in pairs {
        let mut forms = vec![(old.clone(), new.clone())];
        let quoted = (old.quoted(), new.quoted());
        if quoted.0 != old.clone() {
            forms.push(quoted);
        }
        for (old, new) in forms {
            let mut at = 0;
            while let Some((range, slots)) = old.find(&text, at) {
                let filled = new.fill(&slots);
                text.replace_range(range.clone(), &filled);
                at = range.start + filled.len();
                count += 1;
            }
        }
    }
    (count > 0).then_some((text, count))
}

/// A plain value with its text rewritten by `change` (keys stay), or None when nothing changed. Containers count their
/// elements, so only a rewritten text's own length changes.
pub(super) fn rewritten_value(bytes: &[u8], change: &dyn Fn(&str) -> Option<String>) -> io::Result<Option<Vec<u8>>> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    let changed = copy(bytes, &mut at, &mut out, change)?;
    if at != bytes.len() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing bytes after a plain value"));
    }
    Ok(changed.then_some(out))
}

fn copy(bytes: &[u8], at: &mut usize, out: &mut Vec<u8>, change: &dyn Fn(&str) -> Option<String>) -> io::Result<bool> {
    let tag = bytes[take(bytes, at, 1)?];
    out.push(tag);
    let mut changed = false;
    match tag {
        0..=2 => {}
        3..=5 => {
            let start = take(bytes, at, 8)?;
            out.extend_from_slice(&bytes[start..start + 8]);
        }
        6 | 11 => {
            let length = count(bytes, at)?;
            let start = take(bytes, at, length)?;
            let value = &bytes[start..start + length];
            let new = (tag == 6).then(|| std::str::from_utf8(value).ok().and_then(change)).flatten();
            let value = new.as_deref().map_or(value, str::as_bytes);
            changed = new.is_some();
            let length = u32::try_from(value.len()).map_err(|_| io::Error::other("rewritten text too long"))?;
            out.extend_from_slice(&length.to_le_bytes());
            out.extend_from_slice(value);
        }
        7 => {
            let items = count(bytes, at)?;
            out.extend_from_slice(&(items as u32).to_le_bytes());
            for _ in 0..items {
                changed |= copy(bytes, at, out, change)?;
            }
        }
        8 => {
            let items = count(bytes, at)?;
            out.extend_from_slice(&(items as u32).to_le_bytes());
            for _ in 0..items {
                let name = take(bytes, at, 2)?;
                out.extend_from_slice(&bytes[name..name + 2]);
                let length = count(bytes, at)?;
                let start = take(bytes, at, length)?;
                out.extend_from_slice(&(length as u32).to_le_bytes());
                out.extend_from_slice(&bytes[start..start + length]);
                changed |= copy(bytes, at, out, change)?;
            }
        }
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "unknown capture value tag")),
    }
    Ok(changed)
}

/// The migrations in `directory`, in order: every `*.json` but the wire dictionaries.
pub(super) fn load(directory: &Path) -> io::Result<Vec<Migration>> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(directory)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<io::Result<_>>()?;
    files.retain(|path| path.is_file() && path.extension().is_some_and(|extension| extension == "json"));
    files.sort();
    files.iter().map(|path| parse(path)).collect()
}

fn parse(path: &Path) -> io::Result<Migration> {
    let bad = |what: &str| io::Error::other(format!("{}: {what}", path.display()));
    let id = path.file_stem().and_then(|stem| stem.to_str()).ok_or_else(|| bad("no name"))?.to_owned();
    let bytes = std::fs::read(path)?;
    let json = Json::parse(&bytes).map_err(|_| bad("not JSON"))?;
    let root = json.root();
    let strings = |key: &str| -> io::Result<Vec<String>> {
        match root.get(key) {
            None => Ok(Vec::new()),
            Some(value) => value.array().ok_or_else(|| bad(&format!("{key} is not a list")))?
                .map(|item| item.string().map(str::to_owned).ok_or_else(|| bad(&format!("{key} holds a non-string"))))
                .collect(),
        }
    };
    root.get("why").and_then(|why| why.string()).filter(|why| !why.trim().is_empty()).ok_or_else(|| bad("no why"))?;
    let fingerprints = match root.get("fingerprints") {
        None => Vec::new(),
        Some(value) => value.object().ok_or_else(|| bad("fingerprints is not an object"))?
            .map(|(name, value)| value.string().map(|hash| (name.to_owned(), hash.to_owned())).ok_or_else(|| bad("a fingerprint is not text")))
            .collect::<io::Result<_>>()?,
    };
    let kind = match root.get("kind").and_then(|kind| kind.string()) {
        Some("baseline") => Kind::Baseline,
        Some("wire") => Kind::Wire { edits: strings("edits")? },
        Some("rewrite") => {
            let ops = strings("ops")?;
            if ops.is_empty() || ops.iter().any(|op| !op.starts_with("open.")) {
                return Err(bad("a rewrite changes recorded inputs only: its ops are open.* records"));
            }
            let pairs = root.get("replace").and_then(|value| value.array()).ok_or_else(|| bad("no replace list"))?
                .map(|pair| {
                    let old = pair.get("old").and_then(|old| old.string()).ok_or_else(|| bad("a replacement without old"))?;
                    let new = pair.get("new").and_then(|new| new.string()).ok_or_else(|| bad("a replacement without new"))?;
                    let (old, new) = (Template::parse(old)?, Template::parse(new)?);
                    if !new.slots().is_subset(&old.slots()) {
                        return Err(bad("new names a slot old does not"));
                    }
                    Ok((old, new))
                })
                .collect::<io::Result<Vec<_>>>()?;
            if pairs.is_empty() {
                return Err(bad("an empty rewrite"));
            }
            Kind::Rewrite { ops, pairs }
        }
        Some("rerecord") => {
            let tests = strings("tests")?;
            if tests.iter().any(|test| test.split('/').count() != 2 || test.contains("..")) {
                return Err(bad("tests are Class/testName"));
            }
            Kind::Rerecord { tests }
        }
        _ => return Err(bad("kind is baseline, wire, rewrite or rerecord")),
    };
    Ok(Migration { id, kind, fingerprints })
}

/// The ids REPLAYS/MIGRATIONS lists; without one, the baselines.
fn applied(replays: &Path, migrations: &[Migration]) -> io::Result<Vec<String>> {
    match std::fs::read_to_string(replays.join("MIGRATIONS")) {
        Ok(text) => Ok(text.lines().map(str::trim).filter(|line| !line.is_empty()).map(str::to_owned).collect()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(migrations.iter()
            .filter(|migration| matches!(migration.kind, Kind::Baseline)).map(|migration| migration.id.clone()).collect()),
        Err(error) => Err(error),
    }
}

/// What one capture's migration did: whether it was written again, and how many texts or frames it changed.
#[derive(Default)]
struct Done {
    written: bool,
    changes: usize,
}

/// `file` rewritten in place (a sibling written whole, then renamed over it) when `change` changed its records.
fn rewrite_file(file: &Path, dry: bool, change: &dyn Fn(&mut trace::Header, &mut [trace::Record]) -> io::Result<usize>) -> io::Result<Done> {
    let (mut header, mut records) = trace::read(File::open(file)?, usize::MAX)?;
    let changes = change(&mut header, &mut records)?;
    if changes == 0 || dry {
        return Ok(Done { written: false, changes });
    }
    let name = file.file_name().and_then(|name| name.to_str()).unwrap_or("capture");
    let temporary = file.with_file_name(format!(".{name}.migrating-{}", std::process::id()));
    let result = (|| {
        let mut writer = trace::Writer::corpus(File::options().write(true).create_new(true).mode(0o600).open(&temporary)?, &header)?;
        for record in &records {
            writer.push(record)?;
        }
        writer.finish()?;
        std::fs::rename(&temporary, file)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.map(|()| Done { written: true, changes })
}

pub(super) fn run(mut args: Vec<String>) -> io::Result<()> {
    let jobs = jobs(&mut args)?;
    let check = flag(&mut args, "--check");
    let dry = flag(&mut args, "--dry-run");
    let retired = option(&mut args, "--retired")?;
    let [replays, directory] = &args[..] else { return Err(io::Error::other(USAGE)) };
    let (replays, directory) = (Path::new(replays), Path::new(directory));
    let migrations = load(directory)?;
    let mut ledger = applied(replays, &migrations)?;
    let pending: Vec<&Migration> = migrations.iter().filter(|migration| !ledger.contains(&migration.id)).collect();
    if check || pending.is_empty() {
        for migration in &pending {
            println!("pending\t{}", migration.id);
        }
        if check && !pending.is_empty() {
            return Err(io::Error::other(format!("{} replay migrations are pending: capture migrate {} {}", pending.len(),
                                                replays.display(), directory.display())));
        }
        println!("{} migrations, {} applied", migrations.len(), migrations.len() - pending.len());
        return Ok(());
    }
    let retired = retired.map_or_else(|| replays.parent().unwrap_or(replays).join("build/retired-replays"), PathBuf::from);
    for migration in pending {
        let files = captures(replays)?;
        let (mut written, mut changes, mut failed) = (0, 0, 0);
        let mut tally = |results: Vec<io::Result<Done>>| {
            for (file, result) in files.iter().zip(results) {
                match result {
                    Ok(done) => {
                        written += usize::from(done.written);
                        changes += done.changes;
                    }
                    Err(error) => {
                        failed += 1;
                        println!("error\t{}\t{}\t{error}", migration.id, file.display());
                    }
                }
            }
        };
        match &migration.kind {
            Kind::Baseline => {}
            Kind::Wire { edits } => {
                let mut names = HashMap::new();
                for entry in std::fs::read_dir(directory.join("wire"))? {
                    let path = entry?.path();
                    if path.extension().is_some_and(|extension| extension == "json") {
                        let (version, dictionary) = dictionary(&path)?;
                        names.insert(version, dictionary);
                    }
                }
                tally(parallel(&files, jobs, |file| -> io::Result<Done> {
                    let (_, header) = trace::Reader::new(File::open(file)?, usize::MAX)?;
                    if header.wire == wire::VERSION && edits.is_empty() {
                        return Ok(Done::default());
                    }
                    if dry {
                        return Ok(Done { written: false, changes: 1 });
                    }
                    let name = file.file_name().and_then(|name| name.to_str()).unwrap_or("capture");
                    let temporary = file.with_file_name(format!(".{name}.migrating-{}", std::process::id()));
                    let converted = convert(file, &temporary, &names, edits);
                    match converted {
                        Ok(tally) if tally.rechunk + tally.undecoded + tally.left == 0 => {
                            std::fs::rename(&temporary, file)?;
                            Ok(Done { written: true, changes: tally.frames + tally.edited })
                        }
                        Ok(tally) => {
                            let _ = std::fs::remove_file(&temporary);
                            Err(io::Error::other(format!("partly converted: {tally:?}")))
                        }
                        Err(error) => {
                            let _ = std::fs::remove_file(&temporary);
                            Err(error)
                        }
                    }
                }));
            }
            Kind::Rewrite { ops, pairs } => {
                tally(parallel(&files, jobs, |file| rewrite_file(file, dry, &|_, records| {
                    let mut changes = 0;
                    for record in records.iter_mut().filter(|record| ops.contains(&record.op)) {
                        let counted = std::cell::Cell::new(0);
                        let change = |text: &str| replaced(text, pairs).map(|(text, count)| {
                            counted.set(counted.get() + count);
                            text
                        });
                        if let Some(args) = rewritten_value(&record.args, &change)? {
                            record.args = args;
                            changes += counted.get();
                        }
                    }
                    Ok(changes)
                })));
            }
            Kind::Rerecord { tests } => {
                for test in tests {
                    let source = replays.join(test);
                    if !source.is_dir() {
                        println!("rerecord\t{}\t{test}\tno recording", migration.id);
                        continue;
                    }
                    println!("rerecord\t{}\t{test}", migration.id);
                    if !dry {
                        // A copy of the corpus migrated before keeps its retired recordings: this one goes beside them.
                        let target = (1..).map(|n| retired.join(if n == 1 { migration.id.clone() } else { format!("{}-{n}", migration.id) }).join(test))
                            .find(|target| !target.exists()).unwrap();
                        std::fs::create_dir_all(target.parent().unwrap())?;
                        std::fs::rename(&source, &target)?;
                    }
                    written += 1;
                }
            }
        }
        println!("migration\t{}\t{} captures written, {changes} changes, {failed} failed{}", migration.id, written,
                 if dry { " (dry run)" } else { "" });
        if failed > 0 {
            return Err(io::Error::other(format!("migration {} failed on {failed} captures; nothing after it ran", migration.id)));
        }
        if !dry {
            ledger.push(migration.id.clone());
            let mut text = ledger.join("\n");
            text.push('\n');
            std::fs::write(replays.join("MIGRATIONS"), text)?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "migrate.test.rs"]
mod tests;
