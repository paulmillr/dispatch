//! Offline Rust capture scrub; only captured data is selected, never app/test source files.
use dispatch_helper4_core::{
    json::Json,
    system::redact::{Redactor, Rule},
    wire,
};
use std::{
    fs::File,
    io::{self, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

fn main() -> io::Result<()> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|arg| arg == "--replay-batch") {
        if !dispatch_helper4_core::system::replay::batch::run(&args[1..])? {
            return Err(io::Error::other("batch replay failed; see report"));
        }
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--decode") {
        if args.len() != 2 {
            return Err(io::Error::other(
                "usage: capture-redact --decode CAPTURE.jsonl",
            ));
        }
        let input = std::io::BufReader::new(File::open(&args[1])?);
        dispatch_helper4_core::system::redact::decode::read(
            input,
            &mut std::io::BufWriter::new(std::io::stdout().lock()),
        )?;
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--record") {
        if args.len() < 3 {
            return Err(io::Error::other(
                "usage: capture-redact --record CAPTURE.jsonl HELPER [ARGS...]",
            ));
        }
        if Path::new(&args[1]).exists() {
            return Err(io::Error::from(io::ErrorKind::AlreadyExists));
        }
        let status = std::process::Command::new(&args[2])
            .args(&args[3..])
            .env_remove("DISPATCH_REPLAY")
            .env("DISPATCH_CAPTURE", &args[1])
            .status()?;
        if !status.success() {
            return Err(io::Error::other(format!("recorded helper exited {status}")));
        }
        let input = std::io::BufReader::new(File::open(&args[1])?);
        dispatch_helper4_core::system::redact::decode::read(input, &mut std::io::sink())?;
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--replay") {
        if args.len() != 4 {
            return Err(io::Error::other(
                "usage: capture-redact --replay CAPTURE.jsonl HELPER PRIVATE-ROOT",
            ));
        }
        // This single-threaded tool's explicit arguments configure the shared replay entry.
        unsafe {
            std::env::set_var("DISPATCH_REPLAY", &args[1]);
            std::env::set_var("DISPATCH_HELPER_BINARY", &args[2]);
            std::env::set_var("DISPATCH_TEST_ROOT", &args[3]);
        }
        dispatch_helper4_core::system::replay::run();
        return Ok(());
    }
    let dry = args.iter().any(|arg| arg == "--dry-run");
    args.retain(|arg| arg != "--dry-run");
    if args
        .first()
        .is_some_and(|arg| matches!(arg.as_str(), "--scrub" | "--check"))
    {
        let check = args[0] == "--check";
        let required = if check { 2 } else { 3 };
        if args.len() < required || args.len() > required + 1 {
            return Err(io::Error::other(
                "usage: capture-redact --scrub TRACE-IN TRACE-OUT [PRIVATE-LITERALS] | --check TRACE [PRIVATE-LITERALS]",
            ));
        }
        let literals = if let Some(path) = args.get(required) {
            let content = std::fs::read_to_string(path)?;
            let mut literals = Vec::new();
            for line in content
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !line.starts_with('#'))
            {
                if line.starts_with("re:") {
                    return Err(io::Error::other(
                        "private literals must be literal strings, not regular expressions",
                    ));
                }
                literals.push(line.to_owned());
            }
            literals
        } else {
            Vec::new()
        };
        let source = Path::new(&args[1]);
        if source.extension().is_none_or(|ext| ext != "jsonl") {
            return Err(io::Error::other(
                "scrub selects a captured JSONL file; source code and archives are not rewritten",
            ));
        }
        let redactor = Redactor::capture(source, &literals, wire::LIMIT as usize * 8)?;
        if dry {
            println!("would scrub captured data into a new private file; source unchanged");
            return Ok(());
        }
        if check {
            if redactor.private() {
                return Err(io::Error::other("capture contains private data"));
            }
            println!("capture is scrubbed");
        } else {
            let report = redactor.trace(source, Path::new(&args[2]))?;
            println!("scrubbed {} captured rows", report.rows);
        }
        return Ok(());
    }
    // Preserve the existing explicit alias API for coupled native inputs.
    if args.len() < 4 || args.len() % 2 != 0 {
        return Err(io::Error::other(
            "usage: capture-redact BUDGET MAP TRACE-IN TRACE-OUT [COMPANION-IN COMPANION-OUT ...]",
        ));
    }
    let budget = args[0]
        .parse::<usize>()
        .map_err(|_| io::Error::other("invalid scrub budget"))?;
    let mut input = Vec::new();
    File::open(&args[1])?
        .take(budget as u64 + 1)
        .read_to_end(&mut input)?;
    if input.len() > budget {
        return Err(io::Error::other("private map exceeds budget"));
    }
    let json =
        Json::parse(&input).map_err(|_| io::Error::other("invalid private replacement map"))?;
    let rules: Vec<_> = json
        .root()
        .array()
        .ok_or_else(|| io::Error::other("replacement map must be an array"))?
        .map(|value| {
            Ok(Rule {
                from: value
                    .get("from")
                    .and_then(|v| v.string())
                    .ok_or_else(|| io::Error::other("missing original"))?,
                to: value
                    .get("to")
                    .and_then(|v| v.string())
                    .ok_or_else(|| io::Error::other("missing alias"))?,
                binary: value
                    .get("binary")
                    .and_then(|v| v.boolean())
                    .unwrap_or(false),
            })
        })
        .collect::<io::Result<_>>()?;
    let redactor = Redactor::new(&rules, budget)?;
    if dry {
        println!(
            "would scrub capture and selected companions into new private files; originals unchanged"
        );
        return Ok(());
    }
    let report = redactor.trace(Path::new(&args[2]), Path::new(&args[3]))?;
    for pair in args[4..].chunks_exact(2) {
        let mut bytes = Vec::new();
        File::open(&pair[0])?
            .take(budget as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > budget {
            return Err(io::Error::other("companion exceeds scrub budget"));
        }
        let bytes = redactor.bytes(&bytes)?;
        File::options()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&pair[1])?
            .write_all(&bytes)?;
    }
    println!("scrubbed {} captured rows", report.rows);
    Ok(())
}
