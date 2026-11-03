// Compile directly with rustc: use the production startup generator unchanged.
#[path = "../../helper/core/src/system/startup.rs"]
mod startup;

fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    let integration = startup::Integration::typed(&[("codex".into(), "codex".into())]);
    let path = if args.get(5).is_some() { None } else { Some(args[3].as_ref()) };
    let (mut command, files) = startup::prepare(
        args[1].as_ref(), args[2].as_ref(), path,
        args[4].as_ref(), None, Some(&integration), &|name| std::env::var_os(name),
    );
    std::fs::create_dir_all(&args[3]).unwrap();
    for (name, bytes) in files {
        std::fs::write(std::path::Path::new(&args[3]).join(name), bytes).unwrap();
    }
    // Interactive startup without needing to borrow the user's terminal.
    // Bash's generated command already contains -i; its stdin carries the probe.
    if std::path::Path::new(&args[1]).file_name().unwrap() != "bash" {
        command.arg("-i");
    }
    std::process::exit(command.status().unwrap().code().unwrap_or(1));
}
