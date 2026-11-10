//! `capture migrate REPLAYS MIGRATIONS [--check] [--dry-run] [--retired DIR] [--jobs N]`: brings the corpus up to the
//! code (docs/replay.md, Migrations). MIGRATIONS holds the ordered migrations (`NNNN-name.json`) and the wire
//! dictionaries of every schema the corpus was recorded with (`wire/<schema>.json`); REPLAYS/MIGRATIONS lists those
//! applied. Each pending one runs in order:
//!
//! - `baseline`: the corpus as it was when migrations began; applied to every corpus without a ledger.
//! - `encode`: every capture written again as the corpus writes captures now (trace::Writer::corpus), its records
//!   unchanged: a storage change only (rsyncable zstd, zstd.rs).
//! - `wire`: every capture of another schema written in this helper's, with the named reviewed `edits` (`convert`).
//! - `rewrite`: in the inputs the app recorded (`open.*` records' arguments) only, each `old` template replaced by its
//!   `new` one, as written and as shell-quoted inside `'…'`. Recorded results are never touched: a rewrite is right only
//!   where the new code would get the same answers, which replay then checks.
//! - `rerecord`: tests whose answers changed: their recordings move out of the corpus (to DIR, `build/retired-replays`
//!   beside REPLAYS by default), so they run live until recorded again.
//! - `resource`: a file the helper bundles (Pi's bridge.js) changed: wherever a capture holds the old copy as a value (in
//!   our frames, a job's bytes, a read's result) it holds the new one, and its SHA-256 the new one's (`resourced`).
//!
//! A migration's `fingerprints` name what the code generates for recorded inputs once it applies (checked by
//! `ReplayMigrationTests` and `the_current_schema_has_its_dictionary_and_migration`).
use super::*;

#[derive(Debug)]
pub(super) struct Migration {
    pub id: String,
    pub kind: Kind,
    /// Read by the tests that hold the code to its migrations.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fingerprints: Vec<(String, String)>,
}

#[derive(Debug)]
pub(super) enum Kind {
    Baseline,
    Encode,
    Wire { edits: Vec<String> },
    Rewrite { ops: Vec<String>, pairs: Vec<(Template, Template)> },
    Rerecord { tests: Vec<String> },
    /// Each bundled file's old and new copy, as the migration keeps them (`resources`, beside its JSON).
    Resource { pairs: Vec<(Vec<u8>, Vec<u8>)> },
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
    swapped_value(bytes, &|tag, value| (tag == 6).then(|| std::str::from_utf8(value).ok().and_then(change)).flatten().map(String::into_bytes))
}

/// A plain value with each text (tag 6) or bytes (tag 11) `change` returns new contents for replaced, or None when
/// nothing changed.
pub(super) fn swapped_value(bytes: &[u8], change: &dyn Fn(u8, &[u8]) -> Option<Vec<u8>>) -> io::Result<Option<Vec<u8>>> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    let changed = copy(bytes, &mut at, &mut out, change)?;
    if at != bytes.len() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing bytes after a plain value"));
    }
    Ok(changed.then_some(out))
}

fn copy(bytes: &[u8], at: &mut usize, out: &mut Vec<u8>, change: &dyn Fn(u8, &[u8]) -> Option<Vec<u8>>) -> io::Result<bool> {
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
            let new = change(tag, value);
            let value = new.as_deref().unwrap_or(value);
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
        Some("encode") => Kind::Encode,
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
        Some("resource") => {
            let base = path.parent().unwrap_or(Path::new("."));
            let pairs = root.get("resources").and_then(|value| value.array()).ok_or_else(|| bad("no resources list"))?
                .map(|pair| {
                    let file = |key: &str| -> io::Result<Vec<u8>> {
                        let name = pair.get(key).and_then(|name| name.string()).ok_or_else(|| bad(&format!("a resource without {key}")))?;
                        if name.starts_with('/') || name.split('/').any(|part| part == "..") {
                            return Err(bad("a resource's copies sit beside its migration"));
                        }
                        std::fs::read(base.join(name)).map_err(|error| bad(&format!("{name}: {error}")))
                    };
                    let (old, new) = (file("old")?, file("new")?);
                    if old.is_empty() || old == new {
                        return Err(bad("a resource's old copy is empty or its new one"));
                    }
                    Ok((old, new))
                })
                .collect::<io::Result<Vec<_>>>()?;
            if pairs.is_empty() {
                return Err(bad("no resources"));
            }
            Kind::Resource { pairs }
        }
        _ => return Err(bad("kind is baseline, encode, wire, rewrite, rerecord or resource")),
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
            Kind::Encode => {
                tally(parallel(&files, jobs, |file| rewrite_file(file, dry, &|_, records| Ok(records.len().max(1)))));
            }
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
            Kind::Resource { pairs } => {
                tally(parallel(&files, jobs, |file| rewrite_file(file, dry, &|header, records| resourced(header, records, pairs))));
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

fn holds(bytes: &[u8], needle: &[u8]) -> bool {
    needle.len() <= bytes.len() && bytes.windows(needle.len()).any(|window| window == needle)
}

/// A recorded executable (Mach-O, universal, ELF): a helper the app uploads embeds its resources, the build's as recorded,
/// which replay never compares with this build's, so a resource migration leaves it as it is.
fn executable(bytes: &[u8]) -> bool {
    [&b"\xcf\xfa\xed\xfe"[..], b"\xca\xfe\xba\xbe", b"\x7fELF"].iter().any(|magic| bytes.starts_with(magic))
}

/// Whether a record's part still holds an old copy in a value that is no recorded executable (walked as a plain value;
/// one that is none counts as holding it).
fn left(part: &[u8], pairs: &[(Vec<u8>, Vec<u8>)]) -> bool {
    if !pairs.iter().any(|(old, _)| holds(part, old)) {
        return false;
    }
    let found = std::cell::Cell::new(false);
    let walked = swapped_value(part, &|tag, value| {
        if !(tag == 11 && executable(value)) && pairs.iter().any(|(old, _)| holds(value, old)) {
            found.set(true);
        }
        None
    });
    walked.is_err() || found.get()
}

/// A file's SHA-256 as the helper writes it (lowercase hex: Pi's installation receipt).
pub(super) fn sha256(bytes: &[u8]) -> Vec<u8> {
    let mut hash = Sha256::new();
    hash.update(bytes);
    hash.finish().iter().map(|byte| format!("{byte:02x}")).collect::<String>().into_bytes()
}

/// `records` holding each pair's new copy where they held its old one (`Kind::Resource`), returning how many values
/// changed: a value of our frames (written again token by token, after checking the frame encodes again as recorded; a
/// streamed value's chunks joined and cut again, its count kept), a plain value (a job's bytes, a read's result), and the
/// old copy's SHA-256 as text anywhere (same length). An old copy left anywhere else (inside a larger value, bytes no
/// frame of ours carries) fails the capture, which is then recorded again. Recorded executables stay as they are.
pub(super) fn resourced(header: &mut trace::Header, records: &mut [trace::Record], pairs: &[(Vec<u8>, Vec<u8>)]) -> io::Result<usize> {
    let old = |bytes: &[u8]| pairs.iter().any(|(old, _)| holds(bytes, old));
    let digests: Vec<(Vec<u8>, Vec<u8>)> = pairs.iter().map(|(old, new)| (sha256(old), sha256(new))).collect();
    let digested = |bytes: &[u8]| digests.iter().any(|(old, _)| holds(bytes, old));
    if !records.iter().any(|record| [&record.args, &record.output].iter().any(|part| old(part) || digested(part))) {
        return Ok(0);
    }
    if header.wire != wire::VERSION {
        return Err(io::Error::other("recorded in another wire generation: a wire migration converts it first"));
    }
    let names = body::Names { schema: body::SCHEMA, symbols: body::SYMBOLS, records: body::RECORDS };
    let mut changes = 0;
    restream(records, &[0, 1], &mut |joined| framed(joined, &names, pairs, &mut changes))?;
    for record in records.iter_mut() {
        for part in [&mut record.args, &mut record.output] {
            if !old(part) || matches!(body::decode_plain(part), Ok(Data::Bytes(_))) {
                continue;
            }
            let counted = std::cell::Cell::new(0);
            let change = |tag: u8, value: &[u8]| (tag == 6 || tag == 11).then(|| pairs.iter().find(|(old, _)| old == value)).flatten()
                .filter(|(_, new)| tag == 11 || std::str::from_utf8(new).is_ok())
                .map(|(_, new)| { counted.set(counted.get() + 1); new.clone() });
            if let Some(value) = swapped_value(part, &change)? {
                *part = value;
                changes += counted.get();
            }
        }
    }
    for record in records.iter_mut() {
        for part in [&mut record.args, &mut record.output] {
            for (old, new) in &digests {
                let mut at = 0;
                while let Some(found) = part.get(at..).and_then(|rest| rest.windows(old.len()).position(|window| window == old)) {
                    part[at + found..at + found + old.len()].copy_from_slice(new);
                    at += found + old.len();
                    changes += 1;
                }
            }
        }
    }
    if let Some(index) = records.iter().position(|record| left(&record.args, pairs) || left(&record.output, pairs)) {
        return Err(io::Error::other(format!("record {index} ({}) holds an old resource inside another value", records[index].op)));
    }
    Ok(changes)
}

/// The changes to one stream of our frames that make each value holding an old copy hold the new one (`resourced`).
fn framed(joined: &[u8], names: &body::Names, pairs: &[(Vec<u8>, Vec<u8>)], changes: &mut usize) -> io::Result<Vec<(Range<usize>, Vec<u8>)>> {
    let invalid = |error: wire::Error| io::Error::other(format!("{error:?}"));
    let old = |bytes: &[u8]| pairs.iter().any(|(old, _)| holds(bytes, old));
    let (mut at, mut edits, mut chunks) = (0, Vec::new(), HashMap::<u64, Vec<Range<usize>>>::new());
    while let Some(head) = joined.get(at..at + 13) {
        let header = wire::Header::decode(head.try_into().unwrap(), wire::LIMIT).map_err(invalid)?;
        let end = at + 13 + header.len as usize;
        let Some(frame) = joined.get(at + 13..end) else { break };
        match header.kind {
            wire::Kind::Chunk => chunks.entry(header.id).or_default().push(at..end),
            wire::Kind::Cancel => {}
            _ if !frame.starts_with(&names.schema) => {}
            _ => {
                let streamed = body::decode_as(frame, names).ok()
                    .and_then(|value| value.get("stream").and_then(|stream| stream.get("encoding")).and_then(Data::string).map(str::to_owned));
                match (streamed.as_deref(), chunks.remove(&header.id)) {
                    (Some("value"), Some(ranges)) => {
                        let inner: Vec<u8> = ranges.iter().flat_map(|range| joined[range.start + 21..range.end].iter().copied()).collect();
                        if old(&inner) {
                            let (swapped_inner, count) = swapped(&inner, names, pairs)?;
                            let pieces: Vec<&[u8]> = swapped_inner.chunks(wire::CHUNK).collect();
                            if pieces.len() != ranges.len() {
                                return Err(io::Error::other("the new copy needs another number of chunks: record the test again"));
                            }
                            for (sequence, (range, piece)) in ranges.iter().zip(&pieces).enumerate() {
                                let body = [&(sequence as u64).to_le_bytes()[..], piece].concat();
                                edits.push((range.clone(), wire::packet(wire::Kind::Chunk, header.id, &body).map_err(invalid)?));
                            }
                            // The end frame counts the stream's bytes.
                            let mut end_value = tokens(frame, names)?;
                            if let Token::Object { keys, values, .. } = &mut end_value {
                                for ((key, _), value) in keys.iter().zip(values.iter_mut()) {
                                    if *key == "stream" && let Token::Object { keys, values, .. } = value {
                                        for ((key, _), value) in keys.iter().zip(values.iter_mut()) {
                                            if *key == "bytes" {
                                                *value = Token::Scalar([&[3u8][..], &(swapped_inner.len() as u64).to_le_bytes()].concat());
                                            }
                                        }
                                    }
                                }
                            }
                            let mut out = body::SCHEMA.to_vec();
                            written(&end_value, false, names, &mut out);
                            edits.push((at..end, wire::packet(header.kind, header.id, &out).map_err(invalid)?));
                            *changes += count;
                        }
                    }
                    _ if old(frame) => {
                        let (value, count) = swapped(frame, names, pairs)?;
                        edits.push((at..end, wire::packet(header.kind, header.id, &value).map_err(invalid)?));
                        *changes += count;
                    }
                    _ => {}
                }
            }
        }
        at = end;
    }
    edits.sort_by_key(|(range, _)| range.start);
    Ok(edits)
}

/// A wire body with each value that is an old copy (text or bytes) the new one, and how many there were. The body must
/// encode again token by token as recorded, so nothing else in it changes.
fn swapped<'a>(bytes: &'a [u8], names: &body::Names, pairs: &'a [(Vec<u8>, Vec<u8>)]) -> io::Result<(Vec<u8>, usize)> {
    let mut value = tokens(bytes, names)?;
    let mut again = body::SCHEMA.to_vec();
    written(&value, false, names, &mut again);
    if again != bytes {
        return Err(io::Error::other("a frame holding an old resource does not encode again as recorded"));
    }
    fn swap<'a>(token: &mut Token<'a>, pairs: &'a [(Vec<u8>, Vec<u8>)]) -> usize {
        match token {
            Token::Scalar(bytes) if bytes.first() == Some(&11) => match pairs.iter().find(|(old, _)| bytes.get(5..) == Some(&old[..])) {
                Some((_, new)) => {
                    *bytes = [&[11u8][..], &(new.len() as u32).to_le_bytes(), new].concat();
                    1
                }
                None => 0,
            },
            Token::Text { text, symbol: false } => match pairs.iter().find(|(old, _)| text.as_bytes() == &old[..]).and_then(|(_, new)| std::str::from_utf8(new).ok()) {
                Some(new) => {
                    *text = new;
                    1
                }
                None => 0,
            },
            Token::Array(items) => items.iter_mut().map(|item| swap(item, pairs)).sum(),
            Token::Object { values, .. } => values.iter_mut().map(|value| swap(value, pairs)).sum(),
            _ => 0,
        }
    }
    let count = swap(&mut value, pairs);
    let mut out = body::SCHEMA.to_vec();
    written(&value, false, names, &mut out);
    Ok((out, count))
}

#[cfg(test)]
#[path = "migrate.test.rs"]
mod tests;
