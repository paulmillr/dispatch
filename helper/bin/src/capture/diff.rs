//! `capture diff A B`: two captures, or two directories of them, compared on what inspect reads (`Node`): records
//! aligned on their section and op, then their sequence, error and every frame, field and value; a text or bytes value
//! word by word. It knows nothing of what the values mean (ids, times, scrubbed values): it reports every difference,
//! the same change counted once wherever it is. The clock and the wire version are not compared (as `key`).
use super::{captures, decoded, parallel, suffix, Node};
use dispatch_helper_core::system::capture::trace;
use std::{
    collections::HashMap,
    fs::File,
    hash::{DefaultHasher, Hash, Hasher},
    io,
    ops::Range,
    path::{Path, PathBuf},
};

/// The most edits an alignment searches: Myers keeps a row per edit, so its memory and time grow with their square.
/// Beyond it the rest is one change from where the two start to differ.
const EDITS: usize = 1024;

/// How much of a value a change shows: past it the value is cut and its length named (groups stay readable).
const SHOWN: usize = 1000;

/// How much unchanged text a long change shows on each side of where its two sides differ.
const CONTEXT: usize = 40;

/// What changed: the old and the new (None: only on the other side).
type Change = (Option<String>, Option<String>);

/// The same change wherever it is: how often, in how many pairs of captures, and the first place.
#[derive(Debug, PartialEq)]
pub(super) struct Group {
    pub change: Change,
    pub count: usize,
    pub pairs: usize,
    pub first: String,
}

/// Two captures or directories compared: how many pairs of captures, the changes grouped (most frequent first) and the
/// captures that had no counterpart.
#[derive(Debug, PartialEq)]
pub(super) struct Compared {
    pub pairs: usize,
    pub groups: Vec<Group>,
    pub unpaired: Vec<PathBuf>,
}

#[derive(Clone, Copy)]
enum Step {
    Same(usize, usize),
    Removed(usize),
    Added(usize),
}

/// How many items `a` and `b` have in common at their start, and then at their end.
fn ends<K: PartialEq>(a: &[K], b: &[K]) -> (usize, usize) {
    let start = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    (start, a[start..].iter().rev().zip(b[start..].iter().rev()).take_while(|(x, y)| x == y).count())
}

/// The shortest edit script from `a` to `b` (Myers, after their common start and end); None past EDITS edits.
fn script<K: PartialEq>(a: &[K], b: &[K]) -> Option<Vec<Step>> {
    let (start, end) = ends(a, b);
    let (x, y) = (&a[start..a.len() - end], &b[start..b.len() - end]);
    let (n, m) = (x.len() as isize, y.len() as isize);
    let limit = ((n + m) as usize).min(EDITS) as isize;
    // v[k]: how far along `x` the furthest path on diagonal k (i - j) got; one row kept per edit for the way back.
    let at = |k: isize| (k + limit + 1) as usize;
    let (mut v, mut rows) = (vec![0isize; 2 * limit as usize + 3], Vec::new());
    let mut found = None;
    'search: for d in 0..=limit {
        rows.push(v.clone());
        for k in (-d..=d).step_by(2) {
            let mut i = if k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]) { v[at(k + 1)] } else { v[at(k - 1)] + 1 };
            let mut j = i - k;
            while i < n && j < m && x[i as usize] == y[j as usize] {
                (i, j) = (i + 1, j + 1);
            }
            v[at(k)] = i;
            if i >= n && j >= m {
                found = Some(d);
                break 'search;
            }
        }
    }
    let (mut i, mut j, mut steps) = (n, m, Vec::new());
    for d in (1..=found?).rev() {
        let (v, k) = (&rows[d as usize], i - j);
        let down = k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]);
        // From the furthest point of the diagonal before, one edit (down: an item of b, right: one of a), then same
        // items to (i, j).
        let (from_i, from_j) = if down { (v[at(k + 1)], v[at(k + 1)] - k - 1) } else { (v[at(k - 1)], v[at(k - 1)] - k + 1) };
        while i > from_i + isize::from(!down) {
            (i, j) = (i - 1, j - 1);
            steps.push(Step::Same(start + i as usize, start + j as usize));
        }
        steps.push(if down { Step::Added(start + from_j as usize) } else { Step::Removed(start + from_i as usize) });
        (i, j) = (from_i, from_j);
    }
    steps.extend((0..i as usize).rev().map(|back| Step::Same(start + back, start + back - i as usize + j as usize)));
    steps.extend((0..start).rev().map(|same| Step::Same(same, same)));
    steps.reverse();
    steps.extend((0..end).map(|same| Step::Same(a.len() - end + same, b.len() - end + same)));
    Some(steps)
}

/// The script, or past EDITS one run: everything between the common start and end removed and added.
fn aligned<K: PartialEq>(a: &[K], b: &[K]) -> Vec<Step> {
    script(a, b).unwrap_or_else(|| {
        let (start, end) = ends(a, b);
        (0..start).map(|same| Step::Same(same, same))
            .chain((start..a.len() - end).map(Step::Removed))
            .chain((start..b.len() - end).map(Step::Added))
            .chain((0..end).map(|same| Step::Same(a.len() - end + same, b.len() - end + same)))
            .collect()
    })
}

/// Words of a text or bytes value: runs of ASCII letters and digits; one word each: a CSI escape sequence (ESC [, its
/// parameters and final byte: no text inside), ESC and the byte after it (an OSC's text, a title or a URL, is words), a
/// UTF-8 character beyond ASCII (whole when the bytes after its lead byte continue it), any other byte. An escape's
/// final letter or a box line beside a word would otherwise make one change another one at every place.
fn words(bytes: &[u8]) -> Vec<Range<usize>> {
    let (mut out, mut at) = (Vec::new(), 0);
    while at < bytes.len() {
        let rest = &bytes[at..];
        let length = match rest[0] {
            byte if byte.is_ascii_alphanumeric() => rest.iter().take_while(|byte| byte.is_ascii_alphanumeric()).count(),
            0x1b if rest.get(1) == Some(&b'[') => rest[2..].iter().position(|byte| (0x40..=0x7e).contains(byte)).map_or(rest.len(), |end| end + 3),
            0x1b => rest.len().min(2),
            byte => {
                let width = (byte.leading_ones() as usize).clamp(1, 4);
                let whole = width > 1 && rest.len() >= width && rest[1..width].iter().all(|byte| byte & 0xc0 == 0x80);
                if whole { width } else { 1 }
            }
        };
        out.push(at..at + length);
        at += length;
    }
    out
}

/// Where two values' words differ, in bytes: each run of edits is one change, joined across one unchanged byte that is
/// no word (`100.23` -> `7.4` is one change).
fn hunks(a: &[u8], b: &[u8]) -> Vec<(Range<usize>, Range<usize>)> {
    let (x, y) = (words(a), words(b));
    let (xs, ys): (Vec<&[u8]>, Vec<&[u8]>) = (x.iter().map(|word| &a[word.clone()]).collect(), y.iter().map(|word| &b[word.clone()]).collect());
    let joins = |word: &[u8]| word.len() == 1 && !word[0].is_ascii_alphanumeric() && word[0] < 0x80;
    // Runs in words: [old start, old end, new start, new end].
    let (mut runs, mut since, mut last): (Vec<[usize; 4]>, usize, &[u8]) = (Vec::new(), usize::MAX, &[]);
    let (mut i, mut j) = (0, 0);
    for step in aligned(&xs, &ys) {
        if let Step::Same(..) = step {
            (last, i, j, since) = (xs[i], i + 1, j + 1, since.saturating_add(1));
            continue;
        }
        if runs.is_empty() || !(since == 0 || since == 1 && joins(last)) {
            runs.push([i, i, j, j]);
        }
        (i, j) = match step { Step::Removed(_) => (i + 1, j), _ => (i, j + 1) };
        let run = runs.last_mut().unwrap();
        (run[1], run[3], since) = (i, j, 0);
    }
    let bytes = |words: &[Range<usize>], all: usize, start: usize, end: usize| match start < end {
        true => words[start].start..words[end - 1].end,
        false => words.get(start).map_or(all, |word| word.start)..words.get(start).map_or(all, |word| word.start),
    };
    runs.into_iter().map(|[i0, i1, j0, j1]| (bytes(&x, a.len(), i0, i1), bytes(&y, b.len(), j0, j1))).collect()
}

/// Text cut at SHOWN bytes (on a character); `length` past SHOWN is named after it.
fn cut(text: &str, length: usize) -> String {
    let mut end = text.len().min(SHOWN);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    if length > SHOWN { format!("{} ... ({length} bytes)", &text[..end]) } else { text[..end].into() }
}

/// Part of a value as inspect shows text: quoted when UTF-8, otherwise as hex; cut at SHOWN bytes.
fn quoted(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => format!("{:?}", cut(text, 0)),
        Err(_) => format!("hex({})", bytes[..bytes.len().min(SHOWN)].iter().map(|byte| format!("{byte:02x}")).collect::<String>()),
    }
}

/// A change of a value for reading. Longer than SHOWN (one long word, a base64 blob), both sides are shown around where
/// they differ (CONTEXT unchanged bytes each side, `... ` when cut before) and their length named: from its start the
/// difference could lie past the cut, and different changes would look the same.
fn shown(old: &[u8], new: &[u8]) -> Change {
    if old.len().max(new.len()) <= SHOWN {
        return (Some(quoted(old)), Some(quoted(new)));
    }
    let (start, end) = ends(old, new);
    let side = |bytes: &[u8]| {
        let (mut from, mut to) = (start.saturating_sub(CONTEXT), bytes.len() - end.saturating_sub(CONTEXT));
        if let Ok(text) = std::str::from_utf8(bytes) {
            while !text.is_char_boundary(from) {
                from -= 1;
            }
            while !text.is_char_boundary(to) {
                to += 1;
            }
        }
        Some(format!("{}{} ... ({} bytes)", if from > 0 { "... " } else { "" }, quoted(&bytes[from..to]), bytes.len()))
    };
    (side(old), side(new))
}

/// A whole node or record line as a change shows it: as inspect prints it, cut past SHOWN bytes.
fn whole(text: String) -> String {
    cut(&text, text.len())
}

/// What aligns two items: the variant, a frame's first word without digits (its kind) and its method, a value's field
/// names.
fn shape(node: &Node) -> u64 {
    let mut hash = DefaultHasher::new();
    std::mem::discriminant(node).hash(&mut hash);
    match node {
        Node::Fields(fields) => fields.iter().for_each(|(name, _)| name.hash(&mut hash)),
        Node::Frame(parts) => parts.iter().take(2).for_each(|part| {
            if let Node::Word(word) = part {
                word.chars().filter(|letter| !letter.is_ascii_digit()).collect::<String>().hash(&mut hash);
            }
        }),
        _ => {}
    }
    hash.finish()
}

/// Two item lists aligned on their shapes; each item's place is `path[index]` (the index on its own side).
fn listed(a: &[Node], b: &[Node], path: &str, out: &mut Vec<(Change, String)>) {
    let (x, y): (Vec<u64>, Vec<u64>) = (a.iter().map(shape).collect(), b.iter().map(shape).collect());
    for step in aligned(&x, &y) {
        match step {
            Step::Same(i, j) => nodes(&a[i], &b[j], &format!("{path}[{i}]"), out),
            Step::Removed(i) => out.push(((Some(whole(a[i].to_string())), None), format!("{path}[{i}]"))),
            Step::Added(j) => out.push(((None, Some(whole(b[j].to_string()))), format!("{path}[{j}]"))),
        }
    }
}

/// Where `a` and `b` differ at `path`: per run of differing words in a value, per field or item only on one side; a
/// node that became another kind (bytes that no longer decode as frames) shown whole on both sides.
fn nodes(a: &Node, b: &Node, path: &str, out: &mut Vec<(Change, String)>) {
    if a == b {
        return;
    }
    match (a, b) {
        (Node::List(x), Node::List(y)) | (Node::Frames(x), Node::Frames(y)) => listed(x, y, path, out),
        (Node::Frame(x), Node::Frame(y)) => {
            // A part's place: the frame's words before it ("request 1 files.read").
            let (p, q): (Vec<u64>, Vec<u64>) = (x.iter().map(shape).collect(), y.iter().map(shape).collect());
            for step in aligned(&p, &q) {
                let place = |index: usize, parts: &[Node]| {
                    let before: Vec<String> = parts[..index].iter().filter(|part| matches!(part, Node::Word(_))).map(Node::to_string).collect();
                    if before.is_empty() { path.to_string() } else { format!("{path} {}", before.join(" ")) }
                };
                match step {
                    Step::Same(i, j) => nodes(&x[i], &y[j], &place(i, x), out),
                    Step::Removed(i) => out.push(((Some(whole(x[i].to_string())), None), place(i, x))),
                    Step::Added(j) => out.push(((None, Some(whole(y[j].to_string()))), place(j, y))),
                }
            }
        }
        (Node::Fields(x), Node::Fields(y)) => {
            for (name, value) in x {
                match y.iter().find(|(other, _)| other == name) {
                    Some((_, other)) => nodes(value, other, &format!("{path}.{name}"), out),
                    None => out.push(((Some(whole(format!("{name}: {value}"))), None), path.into())),
                }
            }
            for (name, value) in y.iter().filter(|(name, _)| !x.iter().any(|(other, _)| other == name)) {
                out.push(((None, Some(whole(format!("{name}: {value}")))), path.into()));
            }
        }
        (Node::Word(x), Node::Word(y)) | (Node::Text(x), Node::Text(y)) => leaf(x.as_bytes(), y.as_bytes(), path, out),
        (Node::Bytes(x), Node::Bytes(y)) => leaf(x, y, path, out),
        _ => out.push(((Some(whole(a.to_string())), Some(whole(b.to_string()))), path.into())),
    }
}

fn leaf(a: &[u8], b: &[u8], path: &str, out: &mut Vec<(Change, String)>) {
    out.extend(hunks(a, b).into_iter().map(|(old, new)| (shown(&a[old], &b[new]), path.to_string())));
}

/// A capture as pairing and alignment read it: its layer, and per record what aligns it (its section without digits:
/// lifetimes are numbered per run, the section itself is compared; and its op) and a hash of all it holds (section, op,
/// args, sequence, output, error: equal records of two captures pair them).
struct Outline {
    layer: trace::Layer,
    keys: Vec<u64>,
    contents: Vec<u64>,
}

fn outline(file: &Path) -> io::Result<Outline> {
    let (mut reader, header) = trace::Reader::new(File::open(file)?, usize::MAX)?;
    let (mut keys, mut contents) = (Vec::new(), Vec::new());
    for _ in 0.. {
        let Some(record) = reader.next()? else { break };
        let hashed = |value: &dyn Fn(&mut DefaultHasher)| {
            let mut hash = DefaultHasher::new();
            value(&mut hash);
            hash.finish()
        };
        keys.push(hashed(&|hash| (record.section.chars().filter(|letter| !letter.is_ascii_digit()).collect::<String>(), &record.op).hash(hash)));
        contents.push(hashed(&|hash| (&record.section, &record.op, &record.args, record.sequence, &record.output, record.error).hash(hash)));
    }
    Ok(Outline { layer: header.layer, keys, contents })
}

/// A capture read on, each record with what inspect decodes of it.
struct Side {
    reader: trace::Reader<File>,
    streams: HashMap<String, super::Wire>,
}

impl Side {
    fn open(file: &Path) -> io::Result<Self> {
        Ok(Self { reader: trace::Reader::new(File::open(file)?, usize::MAX)?.0, streams: HashMap::new() })
    }

    fn next(&mut self) -> io::Result<(trace::Record, [Vec<Node>; 2])> {
        let record = self.reader.next()?.ok_or_else(|| io::Error::other("capture ended before its records"))?;
        let items = decoded(&record, &mut self.streams);
        Ok((record, items))
    }
}

/// A record on one line, as inspect prints it without number and time.
fn line(record: &trace::Record, [asked, back]: &[Vec<Node>; 2]) -> String {
    let items: String = asked.iter().map(|item| format!(" {item}")).chain(back.iter().map(|item| format!(" -> {item}"))).collect();
    whole(format!("{} {}{items}{}", record.section, record.op, suffix(record)))
}

/// The changes from capture `a` to capture `b`, each with its place: both files and record numbers, section and op,
/// then where inside the record.
fn two(a: &Path, b: &Path, x: &Outline, y: &Outline) -> io::Result<Vec<(Change, String)>> {
    if x.layer != y.layer {
        return Err(io::Error::other(format!("{} and {}: layers differ ({:?} and {:?})", a.display(), b.display(), x.layer, y.layer)));
    }
    let (mut left, mut right, mut out) = (Side::open(a)?, Side::open(b)?, Vec::new());
    let place = |i: String, j: String, record: &trace::Record| format!("{}:{i} {}:{j} {} {}", a.display(), b.display(), record.section, record.op);
    for step in aligned(&x.keys, &y.keys) {
        match step {
            Step::Same(i, j) => {
                let ((old, [asked, back]), (new, [answer, given])) = (left.next()?, right.next()?);
                let here = place(i.to_string(), j.to_string(), &old);
                nodes(&Node::Word(old.section.clone()), &Node::Word(new.section.clone()), &format!("{here} section"), &mut out);
                nodes(&Node::Word(suffix(&old)), &Node::Word(suffix(&new)), &here, &mut out);
                listed(&asked, &answer, &format!("{here} args"), &mut out);
                listed(&back, &given, &format!("{here} output"), &mut out);
            }
            Step::Removed(i) => {
                let (record, items) = left.next()?;
                out.push(((Some(line(&record, &items)), None), place(i.to_string(), "-".into(), &record)));
            }
            Step::Added(j) => {
                let (record, items) = right.next()?;
                out.push(((None, Some(line(&record, &items))), place("-".into(), j.to_string(), &record)));
            }
        }
    }
    Ok(out)
}

/// Two captures to compare, each with its outline.
type Pair = [(PathBuf, Outline); 2];

/// How many items two lists have in common, as multisets.
fn common(x: &[u64], y: &[u64]) -> usize {
    let mut counts: HashMap<u64, usize> = HashMap::new();
    x.iter().for_each(|item| *counts.entry(*item).or_default() += 1);
    y.iter().filter(|item| counts.get_mut(*item).is_some_and(|count| count.checked_sub(1).map(|left| *count = left).is_some())).count()
}

/// Captures of two directories paired per test (the directory they are in; names are random after a scrub): of the same
/// layer, the most equal records first, then the most (section, op) in common; none in common: unpaired.
fn paired(a: &Path, b: &Path, jobs: usize) -> io::Result<(Vec<Pair>, Vec<PathBuf>)> {
    let mut tests: HashMap<PathBuf, [Vec<(PathBuf, Outline)>; 2]> = HashMap::new();
    for (side, root) in [a, b].into_iter().enumerate() {
        let files = captures(root)?;
        for (file, outlined) in files.iter().zip(parallel(&files, jobs, |file| outline(file))) {
            let test = file.parent().unwrap_or(root).strip_prefix(root).unwrap_or(Path::new("")).to_path_buf();
            tests.entry(test).or_default()[side].push((file.clone(), outlined?));
        }
    }
    let (mut pairs, mut unpaired) = (Vec::new(), Vec::new());
    let mut names: Vec<_> = tests.into_iter().collect();
    names.sort_by(|x, y| x.0.cmp(&y.0));
    for (_, [mut left, mut right]) in names {
        left.sort_by(|x, y| x.0.cmp(&y.0));
        right.sort_by(|x, y| x.0.cmp(&y.0));
        let mut scores: Vec<((usize, usize), usize, usize)> = left.iter().enumerate().flat_map(|(i, (_, x))| right.iter().enumerate()
            .filter(move |(_, (_, y))| x.layer == y.layer)
            .map(move |(j, (_, y))| ((common(&x.contents, &y.contents), common(&x.keys, &y.keys)), i, j)))
            .filter(|((_, keys), ..)| *keys > 0).collect();
        scores.sort_by_key(|(score, i, j)| (std::cmp::Reverse(*score), *i, *j));
        let (mut taken, mut chosen) = ((vec![false; left.len()], vec![false; right.len()]), Vec::new());
        for (_, i, j) in scores {
            if !taken.0[i] && !taken.1[j] {
                (taken.0[i], taken.1[j]) = (true, true);
                chosen.push((i, j));
            }
        }
        let (mut lefts, mut rights): (Vec<Option<_>>, Vec<Option<_>>) = (left.into_iter().map(Some).collect(), right.into_iter().map(Some).collect());
        chosen.sort();
        for (i, j) in chosen {
            pairs.push([lefts[i].take().unwrap(), rights[j].take().unwrap()]);
        }
        unpaired.extend(lefts.into_iter().chain(rights).flatten().map(|(file, _)| file));
    }
    unpaired.sort();
    Ok((pairs, unpaired))
}

/// Two captures, or two directories of them (paired per test), compared; `jobs` pairs at once.
pub(super) fn compare(a: &Path, b: &Path, jobs: usize) -> io::Result<Compared> {
    let (pairs, unpaired) = if a.is_dir() && b.is_dir() {
        paired(a, b, jobs)?
    } else {
        (vec![[(a.to_path_buf(), outline(a)?), (b.to_path_buf(), outline(b)?)]], Vec::new())
    };
    let mut groups: HashMap<Change, (usize, usize, String)> = HashMap::new();
    for changes in parallel(&pairs, jobs, |[x, y]| two(&x.0, &y.0, &x.1, &y.1)) {
        let mut seen = std::collections::HashSet::new();
        for (change, place) in changes? {
            let group = groups.entry(change.clone()).or_insert((0, 0, place));
            group.0 += 1;
            if seen.insert(change) {
                group.1 += 1;
            }
        }
    }
    let mut groups: Vec<Group> = groups.into_iter().map(|(change, (count, pairs, first))| Group { change, count, pairs, first }).collect();
    groups.sort_by(|x, y| (std::cmp::Reverse(x.count), &x.change).cmp(&(std::cmp::Reverse(y.count), &y.change)));
    Ok(Compared { pairs: pairs.len(), groups, unpaired })
}

/// The comparison for reading: a total line, then `limit` groups (`count in N pairs: old -> new`, `+ new` / `- old` for
/// one side, and the first place), then the captures without a counterpart.
pub(super) fn print(compared: &Compared, limit: usize, out: &mut dyn io::Write) -> io::Result<()> {
    let count: usize = compared.groups.iter().map(|group| group.count).sum();
    writeln!(out, "{} capture pairs, {count} changes in {} groups, {} captures unpaired", compared.pairs, compared.groups.len(), compared.unpaired.len())?;
    for group in compared.groups.iter().take(limit) {
        let change = match &group.change {
            (Some(old), Some(new)) => format!("{old} -> {new}"),
            (Some(old), None) => format!("- {old}"),
            (None, Some(new)) => format!("+ {new}"),
            (None, None) => String::new(),
        };
        writeln!(out, "{} in {} pairs: {change}\n    first: {}", group.count, group.pairs, group.first)?;
    }
    if compared.groups.len() > limit {
        writeln!(out, "... {} more groups: raise --limit", compared.groups.len() - limit)?;
    }
    for file in &compared.unpaired {
        writeln!(out, "unpaired: {}", file.display())?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "diff.test.rs"]
mod tests;
