use super::*;

pub(super) fn record(op: &str, args: &Data<'_>, output: &Data<'_>) -> trace::Record {
    trace::Record {
        section: "app".into(),
        clock: 0,
        op: op.into(),
        args: body::encode_plain(args).unwrap(),
        sequence: 0,
        output: body::encode_plain(output).unwrap(),
        error: None,
    }
}

fn fd(fd: u64) -> Data<'static> {
    Data::Object(vec![("fd", Data::Unsigned(fd))])
}

fn frame(id: u64, value: &Data<'_>) -> Vec<u8> {
    wire::packet(wire::Kind::Response, id, &body::encode(value).unwrap()).unwrap()
}

/// The names of the processes the made-up lists hold, in order; a process's pid is 100 + its place here.
const ROWS: [&str; 6] = ["launchd", "zsh", "fakeco-collector", "tmux", "yes", "vpnagent"];

fn pid(name: &str) -> u64 {
    100 + ROWS.iter().position(|row| *row == name).unwrap() as u64
}

pub(super) fn on(section: &str, record: trace::Record) -> trace::Record {
    trace::Record { section: section.into(), ..record }
}

/// `names` as the rows of a list: each with its pid.
fn named(names: &[&'static str]) -> Vec<(u64, &'static str)> {
    names.iter().map(|name| (pid(name), *name)).collect()
}

/// A stats.processes reply listing `rows`, as the helper's plugin sends it (request id 4).
fn reply(rows: &[(u64, &str)]) -> Vec<u8> {
    let rows = rows.iter().map(|(pid, name)| Data::Object(vec![("pid", Data::Unsigned(*pid)), ("start", Data::Null),
        ("name", Data::String(name)), ("cpu", Data::Real(0.5)), ("rss", Data::Unsigned(4096))])).collect();
    frame(4, &Data::Object(vec![("result", Data::Array(vec![Data::Array(rows), Data::Bool(false)]))]))
}

/// A process list of `names` everywhere one is recorded, after the app's request for it: the stats job's completion; the
/// reply the helper writes (a frame per write); a remote bridge reading it and writing it on, cut `bridge` bytes into the
/// reply; the app reading it cut `app` bytes into it, after another frame in the same read. Beside them a lookup of one
/// process (a pid, no rss): no list.
fn lists(rows: &[(u64, &str)], bridge: usize, app: usize) -> Vec<trace::Record> {
    let (reply, other) = (reply(rows), frame(9, &Data::Object(vec![("result", Data::Bool(true))])));
    let request = wire::packet(wire::Kind::Request, 4, &body::encode(&Data::Object(vec![("method", Data::String("stats.processes"))])).unwrap()).unwrap();
    let native = rows.iter().map(|(pid, name)| Data::Object(vec![("pid", Data::Unsigned(*pid)), ("name", Data::String(name)),
        ("cpu", Data::Real(0.5)), ("rss", Data::Unsigned(4096))])).collect();
    let job = Data::Object(vec![("job", Data::String("isolated")), ("name", Data::String("stats.processes")),
        ("value", Data::Object(vec![("local", Data::Bool(true))]))]);
    let done = Data::Object(vec![("kind", Data::String("value")), ("value", Data::Object(vec![("boot", Data::String("b")),
        ("monotonic", Data::Real(1.5)), ("truncated", Data::Bool(false)), ("processes", Data::Array(native))]))]);
    let lookup = Data::Object(vec![("kind", Data::String("process")), ("pid", Data::Unsigned(12)),
        ("executable", Data::Bytes(b"/opt/fakeco/bin/fakeco-collector"))]);
    let io = |op, fd, bytes: &[u8], length: usize| {
        record(op, &Data::Object(vec![("fd", Data::Unsigned(fd)), ("length", Data::Unsigned(length as u64))]), &Data::Bytes(bytes))
    };
    vec![
        on("app/3", record("out.wire", &Data::Bytes(&request), &Data::Null)),
        on("startup", io("read", 18, &request, 65536)),
        on("plugin/1", record("file.done", &Data::Array(vec![Data::Unsigned(1), job]), &done)),
        on("mux/1", record("file.done", &Data::Null, &lookup)),
        on("startup", io("write", 19, &reply, reply.len())),
        on("login.bridge", io("read", 5, &reply[..bridge], 65536)),
        on("login.bridge", io("read", 5, &reply[bridge..], 65536)),
        on("login.bridge", io("write", 1, &reply[..bridge], bridge)),
        on("login.bridge", io("write", 1, &reply[bridge..], reply.len() - bridge)),
        on("app/3", record("in.read", &Data::Null, &Data::Bytes(&[&other[..], &reply[..app]].concat()))),
        on("app/3", record("in.read", &Data::Null, &Data::Bytes(&reply[app..]))),
    ]
}

pub(super) fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("capture-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("in")).unwrap();
    root
}

pub(super) fn write(path: &Path, records: &[trace::Record]) {
    layered(path, trace::Layer::App, records);
}

pub(super) fn layered(path: &Path, layer: trace::Layer, records: &[trace::Record]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let header = trace::Header { layer, wire: wire::VERSION };
    let mut writer = trace::Writer::new(File::create(path).unwrap(), &header).unwrap();
    for record in records {
        writer.push(record).unwrap();
    }
    writer.finish().unwrap();
}

fn read(path: &Path) -> Result<Vec<trace::Record>, String> {
    Ok(trace::read(File::open(path).map_err(|error| error.to_string())?, usize::MAX).map_err(|error| error.to_string())?.1)
}

/// The captures directly in `dir` (replace names them at random), sorted by content.
fn inside(dir: &Path) -> Result<Vec<(String, Vec<trace::Record>)>, String> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(|error| error.to_string())? {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.is_file() {
            files.push((path.file_name().unwrap().to_str().unwrap().to_string(), read(&path)?));
        }
    }
    files.sort_by(|a, b| format!("{:?}", a.1).cmp(&format!("{:?}", b.1)));
    Ok(files)
}

/// The only capture directly in `dir`.
fn only(dir: &Path) -> Result<Vec<trace::Record>, String> {
    let mut files = inside(dir)?;
    if files.len() != 1 {
        return Err(format!("{} captures in {}", files.len(), dir.display()));
    }
    Ok(files.remove(0).1)
}

/// `name` masked: an `x` for each of its bytes.
fn masked(name: &str) -> &'static str {
    Box::leak("x".repeat(name.len()).into_boxed_str())
}

/// The made-up lists' rows as a scrub leaves them: every row, the names not allowed masked.
fn masked_rows() -> Vec<(u64, &'static str)> {
    named(&ROWS).into_iter().map(|(pid, name)| (pid, if ALLOWED.contains(&name) { name } else { masked(name) })).collect()
}

#[test]
fn removal_masks_the_names_not_allowed_and_keeps_every_row_and_record_as_long() {
    // The same lengths: every record, the bridge's and the app's cuts included, stays as recorded but for the names.
    let old = reply(&named(&ROWS)).len();
    assert_eq!(reply(&masked_rows()).len(), old);
    let removed = removal(lists(&named(&ROWS), old - 5, 30)).map_err(|error| error.to_string());
    assert_eq!(removed, Ok(lists(&masked_rows(), old - 5, 30)));
    assert_eq!(masked_rows().iter().map(|(_, name)| *name).collect::<Vec<_>>(),
               ["xxxxxxx", "zsh", "xxxxxxxxxxxxxxxx", "tmux", "yes", "xxxxxxxx"]);
}

#[test]
fn removal_keeps_a_process_named_like_one_of_our_words() {
    // The helper sends `route` (a macOS process, and one of our words) as its number: masked where it read it, it would
    // write text, longer than recorded.
    assert!(body::symbol("route").is_some());
    let list = |name: &str| body::encode_plain(&Data::Array(vec![Data::Object(vec![("pid", Data::Unsigned(1)),
        ("name", Data::String(name)), ("rss", Data::Unsigned(4096))])])).unwrap();
    let done = |name: &str| vec![on("plugin/1", record("file.done", &Data::Null, &Data::Null))]
        .into_iter().map(|record| trace::Record { output: list(name), ..record }).collect::<Vec<_>>();
    assert_eq!(removal(done("route")).map_err(|error| error.to_string()), Ok(done("route")));
    assert_eq!(removal(done("loginwindow")).map_err(|error| error.to_string()), Ok(done("xxxxxxxxxxx")));
}

#[test]
fn removal_masks_a_list_that_comes_in_chunks() {
    // A list over 64 KiB, as the helper sends it (chunks of raw bytes, then its final frame), written in two writes
    // that cut a chunk: each keeps its length, the names are masked where the chunks carry them.
    let reply = |rows: &[(u64, &str)]| -> Vec<u8> {
        let list = rows.iter().map(|(pid, name)| Data::Object(vec![("pid", Data::Unsigned(*pid)), ("start", Data::Null),
            ("name", Data::String(name)), ("cpu", Data::Real(0.5)), ("rss", Data::Unsigned(4096))])).collect();
        let body = body::encode(&Data::Object(vec![("result", Data::Array(vec![Data::Array(list), Data::Bool(false)]))])).unwrap();
        wire::Message::value(wire::Kind::Response, 4, body[body::SCHEMA.len()..].to_vec()).flatten().collect()
    };
    let many = |rows: Vec<(u64, &'static str)>| (0..800).flat_map(|round| rows.iter().map(move |(pid, name)| (pid + round * 1000, *name)))
        .collect::<Vec<_>>();
    let (original, masked) = (reply(&many(named(&ROWS))), reply(&many(masked_rows())));
    assert!(original.len() > 2 * wire::CHUNK && original.len() == masked.len());
    let write = |bytes: &[u8]| on("startup", record("write", &Data::Object(vec![("fd", Data::Unsigned(19)),
        ("length", Data::Unsigned(bytes.len() as u64))]), &Data::Bytes(bytes)));
    let written = |bytes: &[u8]| vec![write(&bytes[..70_000]), write(&bytes[70_000..])];
    assert_ne!(original, masked);
    assert_eq!(removal(written(&original)).map_err(|error| error.to_string()), Ok(written(&masked)));
}

#[test]
fn replace_masks_process_names_before_the_needles() {
    let root = scratch("rows");
    let journal = |rows: &[(u64, &str)], fakeco: &str| -> Vec<trace::Record> {
        lists(rows, 40, 30).into_iter().filter(|record| record.section == "app/3" || record.section == "mux/1")
            .map(|record| trace::Record { output: bytes_replaced(&record.output, b"fakeco", fakeco.as_bytes()), ..record })
            .collect()
    };
    write(&root.join("in/T/a/x.rpl.zst"), &journal(&named(&ROWS), "fakeco"));
    std::fs::write(root.join("needles.txt"), "fakeco\n").unwrap();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    let replaced = run(&["replace", &path("in"), &path("out"), "--needles", &path("needles.txt")].map(Into::into))
        .map_err(|error| error.to_string()).and_then(|_| only(&root.join("out/T/a")));
    std::fs::remove_dir_all(&root).unwrap();
    // The process name holding the needle is masked whole first; the needle changes the lookup.
    let fakeco = String::from_utf8(replacements(&[(b"fakeco".to_vec(), None)]).unwrap().0.remove(0)).unwrap();
    assert_eq!(replaced, Ok(journal(&masked_rows(), &fakeco)));
}

/// `bytes` with every `from` replaced by `to` (of its length).
fn bytes_replaced(bytes: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    for at in 0..out.len().saturating_sub(from.len() - 1) {
        if out[at..at + from.len()] == *from {
            out[at..at + from.len()].copy_from_slice(to);
        }
    }
    out
}

#[test]
fn grep_lists_every_whole_token_holding_a_needle_or_its_replacement() {
    let root = scratch("tokens");
    let list = vec![(b"fakeco".to_vec(), None), (b"/home/someone".to_vec(), Some(b"/home/anybody".to_vec()))];
    let (replaced, _) = replacements(&list).unwrap();
    let mask = String::from_utf8(replaced[0].clone()).unwrap();
    let file = root.join("in/a.rpl.zst");
    write(&file, &[
        record("in.result", &Data::Null, &Data::String(&format!("{mask}-collector reads /home/anybody/notes and {mask}"))),
        record("read", &fd(3), &Data::Bytes(&frame(4, &Data::Object(vec![("result", Data::String(&format!("user@{mask}.example")))])))),
        record("read", &fd(4), &Data::Bytes(format!("prompt {mask}:~$ fakeco").as_bytes())),
    ]);
    let needles: Vec<Vec<u8>> = list.iter().map(|(needle, _)| needle.clone()).collect();
    let around = Matcher::new([&needles[..], &replaced[..]].concat());
    let found = search(&file, &Matcher::new(needles), &around, &[]).map(|found| found.tokens).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    let first = |record: usize| format!("{}:{record}", file.display());
    assert_eq!(found, Ok(BTreeMap::from([
        ((0, "fakeco".to_string()), (1, first(2))),
        ((0, mask.clone()), (2, first(0))),
        ((0, format!("{mask}-collector")), (1, first(0))),
        ((0, format!("user@{mask}.example")), (1, first(1))),
        ((1, "/home/anybody".to_string()), (1, first(0))),
    ])));
}

/// A made-up client side of a websocket (the helper to Codex app-server), `fakeco` only inside masked frames: the upgrade
/// request, a text frame cut across two writes inside `fakeco`, a second frame whole in the second write.
fn socket(fakeco: &str) -> Vec<trace::Record> {
    use dispatch_helper_core::rpc::websocket::frame;
    let upgrade = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
    let text = format!(r#"{{"method":"thread/start","params":{{"cwd":"/home/{fakeco}/work"}}}}"#);
    let first = frame(1, text.as_bytes(), [0x5a, 0x13, 0xc7, 0x8e], 1 << 20).unwrap();
    let second = frame(1, format!(r#"{{"text":"{fakeco}"}}"#).as_bytes(), [0x01, 0xfe, 0x22, 0x9b], 1 << 20).unwrap();
    let cut = 6 + text.find("/home/").unwrap() + 9;
    vec![
        record("write", &fd(5), &Data::Bytes(upgrade.as_bytes())),
        record("write", &fd(5), &Data::Bytes(&first[..cut])),
        record("write", &fd(5), &Data::Bytes(&[&first[cut..], &second[..]].concat())),
    ]
}

#[test]
fn grep_and_replace_read_inside_masked_websocket_frames() {
    let root = scratch("socket");
    let file = root.join("in/a.rpl.zst");
    write(&file, &socket("fakeco"));
    std::fs::write(root.join("needles.txt"), "fakeco\n").unwrap();
    let matcher = Matcher::new(vec![b"fakeco".to_vec()]);
    let found = search(&file, &matcher, &matcher, &[]).map(|found| found.places).map_err(|error| error.to_string());
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    let args = ["replace", &path("in"), &path("out"), "--needles", &path("needles.txt")];
    let replaced = run(&args.map(Into::into)).map_err(|error| error.to_string()).and_then(|_| only(&root.join("out")));
    std::fs::remove_dir_all(&root).unwrap();
    let first = format!("{}:2", file.display());
    assert_eq!(found, Ok(BTreeMap::from([
        ((0, "app write output -> websocket (masked)".to_string()), (1, first.clone())),
        ((0, "app write output -> websocket (masked) (wrapped)".to_string()), (1, first)),
    ])));
    // The payloads hold the replacement; frame headers and keys stay.
    let fakeco = String::from_utf8(replacements(&[(b"fakeco".to_vec(), None)]).unwrap().0.remove(0)).unwrap();
    assert_eq!(replaced, Ok(socket(&fakeco)));
}

#[test]
fn grep_reports_a_needle_the_screen_shows_drawn_from_its_end_back() {
    let root = scratch("backwards");
    let file = root.join("in/a.rpl.zst");
    // The terminal draws "cd" at column 3, a long line below, then jumps back and draws "ab": the screen shows "abcd",
    // its first cell written long after its last.
    let bytes = [&b"\x1b[1;3Hcd\x1b[5;1H"[..], &[b'x'; 200], b"\x1b[1;1Hab"].concat();
    write(&file, &[record("read", &fd(3), &Data::Bytes(&bytes))]);
    let matcher = Matcher::new(vec![b"abcd".to_vec()]);
    let found = std::panic::catch_unwind(|| search(&file, &matcher, &matcher, &[]).map(|found| found.places).map_err(|error| error.to_string()));
    std::fs::remove_dir_all(&root).unwrap();
    // Reported around both ends, in recorded order.
    let output = body::encode_plain(&Data::Bytes(&bytes)).unwrap();
    let at = |text: &[u8]| output.windows(text.len()).position(|window| window == text).unwrap();
    let first = around(&file, 0, &output, at(b"cd") + 1..at(b"ab") + 2);
    assert_eq!(found.ok(), Some(Ok(BTreeMap::from([((0, "app read output (screen)".to_string()), (1, first))]))));
}

/// What grep finds of `needle` in a capture of `records`: each place and how many times (where first is for reading).
fn places(name: &str, records: &[trace::Record], needle: &[u8]) -> Result<BTreeMap<String, usize>, String> {
    let root = scratch(name);
    let file = root.join("in/a.rpl.zst");
    write(&file, records);
    let matcher = Matcher::new(vec![needle.to_vec()]);
    let found = search(&file, &matcher, &matcher, &[]).map_err(|error| error.to_string());
    std::fs::remove_dir_all(&root).unwrap();
    Ok(found?.places.into_iter().map(|((_, place), (count, _))| (place, count)).collect())
}

#[test]
fn grep_reads_each_terminal_at_the_size_its_recording_names() {
    // Sizes: a helper's pty (spawn), an app's pty (in.size), a terminal of ours (terminals.attach), a herdr frame, the
    // helper's own terminal (tty.start, its stdio). On a terminal of 3 rows "x0y" drawn on the last row goes up a row with a line feed; the program then draws "robin"
    // on that row (over the x) and jumps over the 0 to draw "7" (over the y): the screen shows "robin07", its 0 a byte
    // of other text. A screen of no size never scrolled there: only the recorded size shows the word.
    let bytes = b"\x1b[3;5Hx0y\r\n\x1b[2;1Hrobin\x1b[2;7H7";
    let size = |rows: &'static str, columns: &'static str| Data::Object(vec![(rows, Data::Unsigned(3)), (columns, Data::Unsigned(20))]);
    let frame = |kind, value: Data<'_>| wire::packet(kind, 9, &body::encode(&value).unwrap()).unwrap();
    let attach = frame(wire::Kind::Request, Data::Object(vec![("method", Data::String("terminals.attach")),
        ("params", Data::Object(vec![("terminal", Data::Unsigned(7)), ("size", size("rows", "columns"))]))]));
    let output = frame(wire::Kind::Notify, Data::Object(vec![("method", Data::String("terminal.output")),
        ("params", Data::Object(vec![("terminal", Data::Unsigned(7)), ("bytes", Data::Bytes(bytes))]))]));
    let herdr = format!(r#"{{"type":"terminal.frame","seq":1,"width":20,"height":3,"full":true,"encoding":"ansi","bytes":"{}"}}"#,
        dispatch_helper_herdr::native::encode(bytes)) + "\n";
    let cases = [
        ("pty", vec![
            on("mux/1", record("spawn", &Data::Object(vec![("pty", size("rows", "columns"))]),
                &Data::Object(vec![("input", Data::Unsigned(3)), ("output", Data::Unsigned(3))]))),
            on("mux/1", record("read", &fd(3), &Data::Bytes(bytes))),
        ], "mux read output (screen, shared)"),
        ("app", vec![
            on("app/10", record("in.size", &Data::Null, &size("rows", "columns"))),
            on("app/10", record("in.output", &Data::Null, &Data::Bytes(bytes))),
        ], "app in.output output (screen, shared)"),
        ("frames", vec![
            on("app/12", record("out.wire", &Data::Bytes(&attach), &Data::Null)),
            on("app/12", record("in.read", &Data::Null, &Data::Bytes(&output))),
        ], "app in.read output -> notify terminal.output.params.bytes (terminal 7) (screen, shared)"),
        ("herdr", vec![on("mux/1", record("read", &fd(4), &Data::Bytes(herdr.as_bytes())))],
            "mux read output -> herdr terminal.frame bytes (base64) (screen, shared)"),
        ("tty", vec![
            on("startup", record("tty.start", &Data::Null, &size("rows", "columns"))),
            on("startup", record("stdio", &Data::Null, &Data::Object(vec![("read", Data::Unsigned(23)), ("write", Data::Unsigned(24))]))),
            on("startup", record("write", &fd(24), &Data::Bytes(bytes))),
        ], "startup write output (screen, shared)"),
    ];
    let found: Vec<_> = cases.iter().map(|(name, records, _)| (*name, places(name, records, b"robin07"))).collect();
    let want: Vec<_> = cases.iter().map(|(name, _, place)| (*name, Ok(BTreeMap::from([(place.to_string(), 1)])))).collect();
    assert_eq!(found, want);
}

#[test]
fn only_terminals_have_screens_and_grep_lists_those_of_no_size() {
    // A plain stream with escape sequences and no size, our frames carrying a terminal's output (no size named) and a
    // text that is no terminal's (an escape in a host name): the plain stream and the terminal are drawn on screens of
    // no size, and listed; a stream of our frames and a text of no terminal have no screen.
    let frame = |kind, value: Data<'_>| wire::packet(kind, 9, &body::encode(&value).unwrap()).unwrap();
    let output = frame(wire::Kind::Notify, Data::Object(vec![("method", Data::String("terminal.output")),
        ("params", Data::Object(vec![("terminal", Data::Unsigned(7)), ("bytes", Data::Bytes(b"\x1b[1;1Hok"))]))]));
    let text = frame(wire::Kind::Response, Data::Object(vec![("result", Data::Object(vec![("hostname", Data::String("a\u{1b}[1mb"))]))]));
    let root = scratch("terminals");
    let file = root.join("in/a.rpl.zst");
    write(&file, &[
        on("app/3", record("in.output", &Data::Null, &Data::Bytes(b"\x1b[2;1Hplain"))),
        on("app/4", record("in.read", &Data::Null, &Data::Bytes(&[&output[..], &text[..]].concat()))),
    ]);
    let matcher = Matcher::new(vec![b"absent".to_vec()]);
    let found = search(&file, &matcher, &matcher, &[]).map(|found| found.sizeless.into_iter().map(|(name, (count, _))| (name, count)).collect::<Vec<_>>());
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(found.map_err(|error| error.to_string()), Ok(vec![
        ("app in.output output".to_string(), 1),
        ("notify terminal.output.params.bytes (terminal #)".to_string(), 1),
    ]));
}

#[test]
fn replace_names_every_output_file_at_random() {
    let root = scratch("names");
    // Named as store names them: by their content's key.
    for (dir, records) in [("in/T/a", lists(&named(&ROWS), 40, 30)), ("in/T/a", lists(&named(&ROWS), 40, 30)[..2].to_vec()), ("in/T/b", socket("fakeco"))] {
        let file = root.join(dir).join("new.rpl.zst");
        write(&file, &records);
        std::fs::rename(&file, root.join(dir).join(format!("{}.rpl.zst", key(&file).unwrap()))).unwrap();
    }
    std::fs::write(root.join("needles.txt"), "fakeco\n").unwrap();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    // Per file: its directory, name, content and content key.
    let files = |top: &str| -> Result<Vec<(&str, String, Vec<trace::Record>, String)>, String> {
        let mut files = Vec::new();
        for dir in ["T/a", "T/b"] {
            for (name, records) in inside(&root.join(top).join(dir))? {
                let key = key(&root.join(top).join(dir).join(&name)).map_err(|error| error.to_string())?;
                files.push((dir, name, records, key));
            }
        }
        Ok(files)
    };
    let inputs = files("in");
    let outputs = ["one", "two"].map(|out| -> Result<_, String> {
        run(&["replace", &path("in"), &path(out), "--needles", &path("needles.txt")].map(Into::into)).map_err(|error| error.to_string())?;
        // Written as the corpus keeps captures: zstd over the long window (the frame header's window descriptor,
        // after the magic and the descriptor byte: 2^27), where a live capture keeps level 1's own.
        for file in captures(&root.join(out)).map_err(|error| error.to_string())? {
            let head = std::fs::read(&file).map_err(|error| error.to_string())?[..6].to_vec();
            if head[..4] != [0x28, 0xb5, 0x2f, 0xfd] || (head[5] >> 3) + 10 != 27 {
                return Err(format!("{} is not the corpus's zstd", file.display()));
            }
        }
        files(out)
    });
    std::fs::remove_dir_all(&root).unwrap();
    let (inputs, [one, two]) = (inputs.unwrap(), outputs.map(Result::unwrap));
    let random = |name: &str| name.len() == 64 + ".rpl.zst".len() && name.ends_with(".rpl.zst")
        && name[..64].bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    let shape = |files: &[(&str, String, Vec<trace::Record>, String)]| {
        files.iter().map(|(dir, name, records, _)| (dir.to_string(), random(name), records.clone())).collect::<Vec<_>>()
    };
    // The same directories and contents in both runs, every name random.
    let expected: Vec<_> = shape(&one).into_iter().map(|(dir, _, records)| (dir, true, records)).collect();
    assert_eq!((shape(&one), shape(&two), one.iter().map(|file| file.0).collect::<Vec<_>>()), (expected.clone(), expected, vec!["T/a", "T/a", "T/b"]));
    // Nothing of a name comes from content: not the input's name (its key), not the output's key, not the other run's.
    let taken: Vec<String> = inputs.iter().flat_map(|file| [file.1.clone(), format!("{}.rpl.zst", file.3)])
        .chain(one.iter().map(|file| format!("{}.rpl.zst", file.3))).chain(two.iter().map(|file| file.1.clone())).collect();
    assert_eq!(one.iter().filter(|file| taken.contains(&file.1)).count(), 0);
}

#[test]
fn store_takes_a_staged_test_directory_as_it_is() {
    let root = scratch("store");
    let stage = root.join("in");
    // The runner's map of test classes to their files, the cases' outcomes, a journal per case where the case wrote it.
    std::fs::write(stage.join("tests.json"), r#"{"Example": "ExampleTests"}"#).unwrap();
    std::fs::write(stage.join("cases.jsonl"), [("testA", "passed"), ("testB", "failed")].map(|(test, outcome)| {
        format!("{{\"case\":\"DispatchTests/Example/{test}\",\"event\":\"end\",\"outcome\":\"{outcome}\"}}\n")
    }).concat()).unwrap();
    let journal = |test: &str| vec![record("in.result", &Data::Null, &Data::String(test))];
    for test in ["testA", "testB"] {
        write(&stage.join("ExampleTests").join(test).join("c0ffee.rpl.zst"), &journal(test));
    }
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    let stored = run(&["store", &path("in"), &path("replays")].map(Into::into)).map_err(|error| error.to_string()).and_then(|_| {
        let files = captures(&root.join("replays")).map_err(|error| error.to_string())?;
        files.iter().map(|file| Ok((file.strip_prefix(root.join("replays")).unwrap().parent().unwrap().to_owned(), read(file)?))).collect()
    });
    std::fs::remove_dir_all(&root).unwrap();
    // The passed case only, under its file and name.
    assert_eq!(stored, Ok(vec![(PathBuf::from("ExampleTests/testA"), journal("testA"))]));
}

#[test]
fn check_links_a_relay_whatever_the_order_of_its_files() {
    let root = scratch("relay");
    // The app talks to a remote helper through ssh: a relay (`connect`) reads the app's bytes on its stdio and writes them
    // to the helper's socket, and back. The app's end agrees with the relay's stdio and with the helper's accept alike.
    let (up, down) = (b"request".as_slice(), b"reply".as_slice());
    let io = |section: &str, op: &str, fd: u64, bytes: &[u8]| on(section, record(op, &self::fd(fd), &Data::Bytes(bytes)));
    let fact = |op: &str, value: Data<'_>| on("startup", record(op, &Data::Null, &value));
    let app = vec![on("app/1", record("out.wire", &Data::Bytes(up), &Data::Null)), on("app/1", record("in.read", &Data::Null, &Data::Bytes(down)))];
    let relay = vec![
        fact("pid", Data::Unsigned(500)),
        fact("stdio", Data::Object(vec![("read", Data::Signed(0)), ("write", Data::Signed(1))])),
        on("login.bridge", record("connect", &Data::String("/sock"), &Data::Signed(5))),
        io("login.bridge", "read", 0, up), io("login.bridge", "write", 5, up), io("login.bridge", "read", 5, down), io("login.bridge", "write", 1, down),
    ];
    let helper = vec![fact("pid", Data::Unsigned(600)), on("ui", record("accept", &Data::Signed(3), &Data::Signed(7))),
                      io("ui", "read", 7, up), io("ui", "write", 7, down)];
    write(&root.join("in/app.rpl.zst"), &app);
    layered(&root.join("in/relay.rpl.zst"), trace::Layer::Native, &relay);
    layered(&root.join("in/helper.rpl.zst"), trace::Layer::Native, &helper);
    let file = |name: &str| root.join("in").join(name);
    let orders = [["app", "relay", "helper"], ["app", "helper", "relay"], ["helper", "relay", "app"], ["relay", "helper", "app"]].map(|order| {
        let checked = check(&order.map(|name| file(&format!("{name}.rpl.zst"))), &mut io::sink()).map_err(|error| error.to_string());
        checked.map(|checked| (checked.different, checked.unlinked))
    });
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(orders, [(); 4].map(|_| Ok((false, Vec::<PathBuf>::new()))));
}

#[test]
fn write_parent_names_no_parent_in_every_recorded_write_and_leaves_other_jobs() {
    let write = |parent: bool| {
        let mut fields = vec![("job", Data::String("write")), ("path", Data::Bytes(b"/h/.zshenv")), ("mode", Data::Unsigned(0o600))];
        if parent {
            fields.extend([("parent_device", Data::Null), ("parent_inode", Data::Null)]);
        }
        Data::Object(fields)
    };
    let read = || Data::Object(vec![("job", Data::String("read")), ("path", Data::Bytes(b"/h/.zshenv"))]);
    let written = Data::Object(vec![("kind", Data::String("written"))]);
    let records = |parent: bool| vec![
        record("submit", &write(parent), &Data::Unsigned(3)),
        record("file.done", &Data::Array(vec![Data::Unsigned(0), write(parent)]), &written),
        record("submit", &read(), &Data::Unsigned(4)),
        record("file.done", &Data::Array(vec![Data::Unsigned(1), read()]), &written),
    ];
    let (mut converted, mut tally) = (records(false), Converted::default());
    amended(&mut converted, &["write-parent".into()], &mut tally).unwrap();
    assert_eq!(converted, records(true));
    assert_eq!(tally.edited, 2);
    amended(&mut converted, &["write-parent".into()], &mut tally).unwrap();
    assert_eq!((converted, tally.edited), (records(true), 2), "a converted capture stays as it is");
    let mut untouched = records(false);
    amended(&mut untouched, &[], &mut tally).unwrap();
    assert_eq!(untouched, records(false), "only when asked");
}
