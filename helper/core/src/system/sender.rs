//! helper2 client.rs: one native hook message, datagram or one interactive stream reply.
use super::{System, hooks::LIMIT};
use crate::{
    api::*,
    json::Data,
    rpc::transport::{Raw, Stream},
    wire::{self, body},
};
use std::{
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// The registered producer selects transport; stdin and stdout contain native bytes only.
/// Every live helper of this account is asked whether it owns the hook's process (B4: helpers
/// of one account share the registry, e.g. an app's helper and one reached over SSH). Among
/// owners the one with the agent bound wins, then the one `endpoint` (the terminal's
/// DISPATCH_HELPER_ENDPOINT) names, then registry order, recorded as ambiguous. Without an
/// owner nothing is sent: the agent keeps its native UI.
pub fn run(io: &mut System, harness: Shared<dyn Harness>, section: &str, endpoint: Option<&Path>) -> io::Result<()> {
    io.section("hook.sender");
    let (input, output) = io.stdio()?;
    let deadline = io.now() + Duration::from_secs(2);
    io.timer(deadline);
    io.interest(input, true, false)?;
    let mut original = Vec::new();
    loop {
        let (_, event) = io.next()?;
        if io.now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        if !matches!(event, Event::Ready {fd,read:true,..} if fd==input) {
            continue;
        }
        let mut bytes = [0; 65536];
        match io.read(input, &mut bytes) {
            Ok(0) => break,
            Ok(count) => {
                if count > (LIMIT as usize).saturating_sub(original.len()) {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                original.extend_from_slice(&bytes[..count]);
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) => {}
            Err(e) => return Err(e),
        }
    }
    io.interest(input, false, false)?;
    let document = Json::parse(&original).map_err(|_| io::ErrorKind::InvalidData)?;
    let interactive = harness
        .borrow_mut()
        .hook(&document)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?
        .interactive;
    let route = owner(io, &registries(section)?, endpoint, deadline)?
        .ok_or(io::ErrorKind::NotFound)?;
    if !interactive {
        check(io, &route, deadline)?;
        match io.datagram(&route.with_extension("d"), &original) {
            Ok(()) => return Ok(()),
            Err(e) => {
                #[cfg(target_os = "linux")]
                const SIZE: i32 = 90;
                #[cfg(target_os = "macos")]
                const SIZE: i32 = 40;
                if super::errno(&e) != Some(SIZE) && e.kind() != io::ErrorKind::WouldBlock {
                    return Err(e);
                }
            }
        }
    }
    // The receiver enforces the native approval/question deadlines. This sender's
    // upper bound covers the longest existing question without inspecting native JSON.
    let deadline = io.now() + Duration::from_secs(if interactive { 180 } else { 30 });
    let kind = if interactive {
        wire::Kind::Request
    } else {
        wire::Kind::Notify
    };
    let body = exchange(io, &route, kind, 0, &original, deadline)?;
    if !interactive && !body.is_empty() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let result = (|| {
        let mut offset = 0;
        loop {
            if !interactive || offset == body.len() {
                break;
            }
            match io.write(output, &body[offset..]) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(count) => offset += count,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    io.interest(output, false, true)?;
                    loop {
                        let (_, event) = io.next()?;
                        if io.now() >= deadline {
                            return Err(io::ErrorKind::TimedOut.into());
                        }
                        if matches!(event,Event::Ready{fd,write:true,..} if fd==output) {
                            break;
                        }
                    }
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    })();
    io.close(input);
    io.close(output);
    result
}

/// Setup is not a native hook. The owner validates the socket peer and retains its
/// live grant; only its completed reply permits the typed agent to start.
pub fn setup(io: &mut System, section: &str, endpoint: Option<&Path>) -> io::Result<()> {
    io.section("setup.sender");
    let deadline = io.now() + Duration::from_secs(12);
    let Some(route) = owner(io, &registries(section)?, endpoint, deadline)? else {
        return Ok(());
    };
    let request = body::encode_plain(&Data::Object(vec![("section", Data::String(section))]))
        .map_err(|_| io::ErrorKind::InvalidData)?;
    let response = exchange(io, &route, wire::Kind::Request, 2, &request, deadline)?;
    let response = body::decode_plain(&response).map_err(|_| io::ErrorKind::InvalidData)?;
    if let Some(error) = response.get("error").and_then(Data::string) {
        return Err(io::Error::other(error));
    }
    response
        .get("enabled")
        .and_then(|v| v.boolean())
        .map(|_| ())
        .ok_or_else(|| io::ErrorKind::InvalidData.into())
}

/// A typed multiplexer holds the foreground shell until its verified owner releases it.
/// Declined commands replace this launcher with the real native program.
pub fn launch(io: &mut System, program: &str, arguments: &[String], endpoint: Option<&Path>) -> io::Result<()> {
    io.section("launch.sender");
    // Earlier captures have no signal subscription. Replay their exact IO unchanged.
    if io.capture.replay.as_ref().map_or(io.capture.enabled(), |replay| {
        replay.peek("launch.sender") == Some("signals")
    }) {
        let fd = io.signals(&[1, 2, 3, 15], true)?;
        io.termination = Some(fd);
        io.interest(fd, true, false)?;
    }
    let deadline = io.now() + Duration::from_secs(12);
    let mut sections = Vec::new();
    for registry in registries("")? {
        if let Ok(Output::List(entries)) = job(io, Job::List { path: registry.clone() }, deadline) {
            sections.extend(entries.into_iter().filter(|(_, kind)| *kind == FileKind::Directory).map(|(name, _)| registry.join(name)));
        }
    }
    if let Some(route) = owner(io, &sections, endpoint, deadline)? {
        let request = body::encode_plain(&Data::Object(vec![("program", Data::String(program))]))
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let response = exchange(io, &route, wire::Kind::Request, 3, &request, deadline)?;
        let response = body::decode_plain(&response).map_err(|_| io::ErrorKind::InvalidData)?;
        if let Some(error) = response.get("error").and_then(Data::string) {
            return Err(io::Error::other(error));
        }
        match response.get("enabled").and_then(Data::boolean) {
            Some(true) => return Ok(()),
            Some(false) => {},
            None => return Err(io::ErrorKind::InvalidData.into()),
        }
    }
    let directory = System::cwd()?;
    let image = System::image()?;
    let path = std::env::var("PATH").unwrap_or_default();
    let input = body::encode_plain(&Data::Object(vec![
        ("program", Data::String(program)),
        ("cwd", Data::from(directory.as_path())),
        ("path", Data::String(&path)),
        ("skip", Data::from(image.as_path())),
    ])).map_err(|_| io::ErrorKind::InvalidData)?;
    let deadline = io.now() + Duration::from_secs(2);
    let bytes = observe(io, "file.program", input, deadline)?;
    let value = body::decode_plain(&bytes).map_err(|_| io::ErrorKind::InvalidData)?;
    let path = value.get("path").and_then(Data::path).ok_or(io::ErrorKind::InvalidData)?;
    {
        let mut command = std::process::Command::new(path);
        command.args(arguments);
        io.replace(command)
    }
}

fn registries(section: &str) -> io::Result<Vec<PathBuf>> {
    let mut paths = vec![super::hooks::registry(section)?];
    // A retained multiplexer may have inherited a different HOME before this SSH
    // login. Its owner still publishes in the account registry (c1654cc client).
    // Explicit test roots must never discover helpers from the real account.
    if std::env::var_os("DISPATCH_TEST_ROOT").is_none() {
        let (_, home) = System::account()?;
        let path = super::hooks::base_in(&home)
            .join("routes")
            .join(section.replace('/', "-"));
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    Ok(paths)
}

fn owner(
    io: &mut System,
    registries: &[PathBuf],
    endpoint: Option<&Path>,
    deadline: Instant,
) -> io::Result<Option<PathBuf>> {
    // The nearest ancestor with a tty selects its terminal's helper. A bound
    // agent wins among multiple owners; then the terminal's named endpoint.
    let mut chain = Vec::new();
    let mut pid = io.pid();
    loop {
        let Ok(Output::Process(process)) = job(io, Job::Process { pid }, deadline) else {
            break;
        };
        chain.push(Data::Array(vec![
            Data::Unsigned(pid.into()),
            Data::Unsigned(process.tty),
        ]));
        if process.parent <= 1 {
            break;
        }
        pid = process.parent;
    }
    let question = body::encode_plain(&Data::Object(vec![("chain", Data::Array(chain))]))
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?;
    let candidates = endpoint.map(|path| (path.to_owned(), true)).into_iter();
    let candidates = candidates.chain(
        routes(io, registries, deadline)
            .into_iter()
            .map(|r| (r, false)),
    );
    let (mut owners, mut asked) = (Vec::new(), Vec::new());
    for (route, named) in candidates {
        let Ok(helper) = check(io, &route, deadline).map(|facts| folder(&facts)) else {
            continue;
        };
        if asked.contains(&helper) {
            continue;
        }
        asked.push(helper);
        let Ok(answer) = exchange(io, &route, wire::Kind::Request, 1, &question, deadline) else {
            continue;
        };
        let answer = body::decode_plain(&answer).map_err(|_| io::ErrorKind::InvalidData)?;
        let fact = |name| answer.get(name).and_then(Data::boolean) == Some(true);
        if fact("owned") {
            owners.push(((!fact("bound"), !named), route));
        }
    }
    owners.sort_by_key(|(rank, _)| *rank);
    let Some((rank, route)) = owners.first() else {
        return Ok(None);
    };
    if owners.get(1).is_some_and(|(next, _)| next == rank) {
        let routes = Data::Array(owners.iter().map(|(_, route)| Data::from(route.as_path())).collect());
        io.record("hook.ambiguous", routes, &Ok(()), Data::Null)?;
    }
    Ok(Some(route.clone()))
}

/// Every live helper's route for `section`, in registry order.
fn routes(io: &mut System, registries: &[PathBuf], deadline: Instant) -> Vec<PathBuf> {
    registries
        .iter()
        .flat_map(|registry| {
            let Ok(Output::List(entries)) = job(
                io,
                Job::List {
                    path: registry.clone(),
                },
                deadline,
            ) else {
                return Vec::new();
            };
            entries
                .into_iter()
                .filter(|(name, _)| !name.starts_with('.'))
                .filter_map(|(name, _)| {
                    let path = registry.join(name);
                    let input = body::encode_plain(&Data::Object(vec![
                        ("path", Data::from(path.as_path())),
                        ("limit", Data::Unsigned(4096)),
                    ]))
                    .ok()?;
                    let file = observe(io, "file.private", input, deadline).ok()?;
                    let file = body::decode_plain(&file).ok()?;
                    Some(file.get("data")?.path()?.to_path_buf())
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

/// The private route's ownership facts (hook.endpoint).
fn check(io: &mut System, route: &Path, deadline: Instant) -> io::Result<Vec<u8>> {
    let observation = body::encode_plain(&Data::Object(vec![("path", Data::from(route))]))
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?;
    observe(io, "hook.endpoint", observation, deadline)
}

/// The helper (its run directory's device and inode) named by hook.endpoint facts.
fn folder(facts: &[u8]) -> Option<(u64, u64)> {
    let facts = body::decode_plain(facts).ok()?;
    let mut stamp = facts.get("stamp")?.array()?;
    Some((stamp.next()?.unsigned()?, stamp.next()?.unsigned()?))
}

/// One packet to a checked route and its complete response body; the route must still be the
/// same one, owned by this account, once connected.
fn exchange(
    io: &mut System,
    route: &Path,
    kind: wire::Kind,
    id: u64,
    message: &[u8],
    deadline: Instant,
) -> io::Result<Vec<u8>> {
    let before = check(io, route, deadline)?;
    let mut stream = Stream::connect(
        io,
        &Address::Unix(route.with_extension("s")),
        Raw,
        LIMIT as usize + 13,
        deadline,
    )?;
    let result = (|| {
        loop {
            let (_, event) = io.next()?;
            if io.now() >= deadline {
                return Err(io::ErrorKind::TimedOut.into());
            }
            let received = stream.event(io, &event)?;
            if received.eof || !received.data.is_empty() {
                return Err(io::ErrorKind::InvalidData.into());
            }
            if stream.ready() {
                break;
            }
        }
        let params = body::encode_plain(&Data::Object(vec![("fd", Data::Signed(stream.input.into()))]))
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?;
        let peer = observe(io, "peer", params, deadline)?;
        let peer = body::decode_plain(&peer).map_err(|_| io::ErrorKind::InvalidData)?;
        let expected = body::decode_plain(&before).map_err(|_| io::ErrorKind::InvalidData)?;
        if peer.get("uid").and_then(Data::unsigned) != expected.get("uid").and_then(Data::unsigned)
            || before != check(io, route, deadline)?
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        stream.send(
            io,
            wire::packet(kind, id, message).map_err(|_| io::ErrorKind::InvalidData)?,
            Some(deadline),
            None,
        )?;
        let mut decoder = wire::Decoder::new(LIMIT);
        let mut header = None;
        let mut body = Vec::new();
        let mut ended = false;
        loop {
            let (_, event) = io.next()?;
            io.callbacks();
            if id != 3 && io.now() >= deadline {
                return Err(io::ErrorKind::TimedOut.into());
            }
            let received = stream.event(io, &event)?;
            for bytes in received.data {
                if ended {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                let consumed = decoder
                    .next(&bytes, |part| match part {
                        wire::Event::Begin(value) => {
                            header = Some(value);
                        }
                        wire::Event::Data(bytes) => body.extend_from_slice(bytes),
                        wire::Event::End => ended = true,
                    })
                    .map_err(|_| io::ErrorKind::InvalidData)?;
                if consumed != bytes.len() {
                    return Err(io::ErrorKind::InvalidData.into());
                }
            }
            if received.eof {
                decoder.finish().map_err(|_| io::ErrorKind::InvalidData)?;
                if !ended
                    || header.is_none_or(|h| {
                        h.kind != wire::Kind::Response || h.id != id || h.len as usize != body.len()
                    })
                {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                // Each caller reads its own kind of answer: our values (ids 1-3) or the
                // agent's own reply bytes (id 0).
                return Ok(body);
            }
        }
    })();
    stream.close(io);
    result
}

/// One job's output within the sender's deadline.
fn job(io: &mut System, job: Job, deadline: Instant) -> io::Result<Output> {
    let work = io.submit(job)?;
    loop {
        if io.now() >= deadline {
            io.cancel(work);
            return Err(io::ErrorKind::TimedOut.into());
        }
        if let (_, Event::Done { work: id, result }) = io.next()? {
            if id != work {
                return Err(io::ErrorKind::InvalidData.into());
            }
            return result;
        }
    }
}

// Finite private endpoint/peer observations share System's worker capture and exact errors.
fn observe(
    io: &mut System,
    name: &'static str,
    input: Vec<u8>,
    deadline: Instant,
) -> io::Result<Vec<u8>> {
    match job(io, Job::Native { name, value: input }, deadline)? {
        Output::Value(value) => Ok(value),
        _ => Err(io::ErrorKind::InvalidData.into()),
    }
}
