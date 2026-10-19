use super::*;
use crate::harness::{Tree, both, drive, system};
use std::time::SystemTime;

/// A repository made with the real git: `main` with two commits (the second renames a file, changes one and
/// adds a binary one, tagged `v1`), `feature` with its own commit off the first, and a working tree with a
/// staged change and rename, an unstaged change, an untracked file and an ignored folder.
struct Repo {
    tree: Tree,
    root: PathBuf,
    home: PathBuf,
    first: String,
    second: String,
    side: String,
}

impl Repo {
    fn new(name: &str) -> Self {
        let tree = Tree::new(name);
        let root = tree.root.join("repo");
        let home = tree.root.join("home");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let mut repo = Self {
            tree,
            root,
            home,
            first: String::new(),
            second: String::new(),
            side: String::new(),
        };
        repo.git(&["init", "-q"]);
        repo.write("a.txt", b"one\n");
        repo.write("b.txt", b"bee\n");
        repo.write("old.txt", b"moved\nlines\n");
        repo.write(".gitignore", b"build/\n");
        repo.git(&["add", "."]);
        repo.commit("one", 1_700_000_000);
        repo.first = repo.head();
        repo.git(&["checkout", "-q", "-b", "feature"]);
        repo.write("side.txt", b"side\n");
        repo.git(&["add", "side.txt"]);
        repo.commit("side", 1_700_000_100);
        repo.side = repo.head();
        repo.git(&["checkout", "-q", "main"]);
        repo.write("a.txt", b"one\ntwo\n");
        repo.git(&["mv", "old.txt", "new.txt"]);
        repo.write("bin.dat", b"\0\x01\x02binary\0");
        repo.git(&["add", "."]);
        repo.commit("two\n\nThe body.", 1_700_000_200);
        repo.second = repo.head();
        repo.git(&["tag", "v1"]);
        // The working tree.
        repo.write("a.txt", b"one\ntwo\nthree\n");
        repo.git(&["add", "a.txt"]);
        repo.git(&["mv", "b.txt", "c.txt"]);
        repo.write("new.txt", b"moved\nlines\nchanged\n");
        repo.write("untracked.txt", b"new\n");
        repo.write("build/out.o", b"\0");
        repo
    }

    fn write(&self, name: &str, bytes: &[u8]) {
        let path = self.root.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }

    fn setup(&self) -> std::process::Command {
        let mut command = std::process::Command::new("git");
        command
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &self.home)
            .env("LANG", "C")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .current_dir(&self.root)
            .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
            .args(["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"])
            .args(["-c", "init.defaultBranch=main"]);
        command
    }

    fn git(&self, args: &[&str]) -> String {
        let output = self.setup().args(args).output().unwrap();
        assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8(output.stdout).unwrap()
    }

    fn commit(&self, message: &str, at: u64) {
        let date = format!("@{at} +0000");
        let output = self
            .setup()
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_DATE", &date)
            .args(["commit", "-q", "-m", message])
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    }

    fn head(&self) -> String {
        self.git(&["rev-parse", "HEAD"]).trim().to_owned()
    }

    /// What the plugin's git sees: no user or system configuration of this machine's account.
    fn environment(&self) -> Vec<(OsString, OsString)> {
        vec![
            ("PATH".into(), std::env::var_os("PATH").unwrap_or_default()),
            ("HOME".into(), self.home.clone().into()),
            ("LANG".into(), "C".into()),
            ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
        ]
    }

    /// The SSH (checked) and the local plugin, both running git in this repository's environment.
    fn plugins(&self) -> [Files; 2] {
        both().map(|mut files| {
            files.git.environment = Some(self.environment());
            files
        })
    }
}

fn run(files: &mut Files, path: &Path, args: &[&str], limit: u64) -> Result<Git, Error> {
    let path = path.to_path_buf();
    let args: Vec<String> = args.iter().map(|&arg| arg.to_owned()).collect();
    drive(&mut system(), files, move |files, io, done| {
        files.git(io, &path, &args, limit, done)
    })
}

/// A successful run's output.
fn ok(files: &mut Files, path: &Path, args: &[&str]) -> String {
    let git = run(files, path, args, 0).unwrap();
    assert_eq!((git.status, git.truncated), (0, false), "{args:?}: {}", git.output);
    git.output
}

const LOG: &str = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x1e";

/// `log` records split at %x1e, each split at %x1f.
fn records(output: &str) -> Vec<Vec<String>> {
    output
        .split('\x1e')
        .map(|record| record.trim_start_matches('\n'))
        .filter(|record| !record.is_empty())
        .map(|record| record.split('\x1f').map(str::to_owned).collect())
        .collect()
}

#[test]
fn each_allowed_command_answers_what_git_says() {
    let repo = Repo::new("git-commands");
    let root = &repo.root;
    let top = std::fs::canonicalize(root).unwrap();
    for mut files in repo.plugins() {
        let files = &mut files;
        assert_eq!(ok(files, root, &["rev-parse", "--show-toplevel"]), format!("{}\n", top.display()));
        assert_eq!(ok(files, root, &["rev-parse", "--abbrev-ref", "HEAD"]), "main\n");
        assert_eq!(ok(files, root, &["rev-parse", "--verify", "v1"]), format!("{}\n", repo.second));
        assert!(repo.second.starts_with(ok(files, root, &["rev-parse", "--short", "HEAD"]).trim()));

        let status = ok(files, root, &["status", "--porcelain=v2", "--branch", "-z", "--ignored"]);
        let fields: Vec<&str> = status.split('\0').collect();
        assert!(fields.contains(&"# branch.head main"), "{fields:?}");
        assert!(fields.contains(&format!("# branch.oid {}", repo.second).as_str()));
        let record = |prefix: &str, name: &str| {
            fields.iter().any(|field| field.starts_with(prefix) && field.ends_with(&format!(" {name}")))
        };
        assert!(record("1 M. ", "a.txt"), "{fields:?}");
        assert!(record("1 .M ", "new.txt"), "{fields:?}");
        // A rename's original path is the next field.
        let renamed = fields.iter().position(|field| field.starts_with("2 R. ") && field.ends_with(" c.txt"));
        assert_eq!(renamed.map(|at| fields[at + 1]), Some("b.txt"), "{fields:?}");
        assert!(fields.contains(&"? untracked.txt"));
        assert!(fields.contains(&"! build/"));

        assert_eq!(ok(files, root, &["diff", "--numstat", "-z"]), "1\t0\tnew.txt\0");
        let staged = ok(files, root, &["diff", "--cached", "--numstat", "-z"]);
        assert!(staged.contains("1\t0\ta.txt\0"), "{staged:?}");
        assert!(staged.contains("\0b.txt\0c.txt\0"), "{staged:?}");
        let patch = ok(files, root, &["diff", "--", "new.txt"]);
        assert!(patch.starts_with("diff --git a/new.txt b/new.txt\n"), "{patch}");
        assert!(patch.contains("\n+changed\n"), "{patch}");
        assert!(ok(files, root, &["diff", "-U0", "--staged", "HEAD", "--", "a.txt"]).contains("@@ -2,0 +3 @@"));

        let log = records(&ok(files, root, &["log", "-n", "200", LOG, "--date=unix"]));
        assert_eq!(log.len(), 2, "{log:?}");
        let head = &log[0];
        assert_eq!((&head[0], &head[1], head[2].as_str()), (&repo.second, &repo.first, "Test"));
        assert_eq!((head[3].as_str(), head[4].as_str(), head[6].as_str()), ("test@example.com", "1700000200", "two"));
        assert!(head[5].contains("HEAD -> main") && head[5].contains("tag: v1"), "{}", head[5]);
        assert_eq!(head[7].trim(), "The body.");
        assert_eq!(log[1][1], "");
        let all = records(&ok(files, root, &["log", "--all", "-n", "200", LOG, "--date=unix"]));
        let hashes: Vec<&str> = all.iter().map(|record| record[0].as_str()).collect();
        assert_eq!(hashes, [repo.second.as_str(), repo.side.as_str(), repo.first.as_str()]);
        let found = ok(files, root, &["log", "--grep=TWO", "--regexp-ignore-case", "--all", "--format=%s"]);
        assert_eq!(found, "two\n");
        assert_eq!(ok(files, root, &["log", "--author=nobody", "-F", "--format=%s"]), "");
        assert_eq!(ok(files, root, &["log", "--max-count=1", "--skip=1", "--format=%s", "--", "a.txt"]), "one\n");

        let detail = ok(files, root, &["show", "--numstat", "-z", "--format=%H%x1f%s%x1e", &repo.second]);
        assert!(detail.starts_with(&format!("{}\x1ftwo\x1e", repo.second)), "{detail:?}");
        assert!(detail.contains("-\t-\tbin.dat\0"), "{detail:?}");
        assert!(detail.contains("1\t0\ta.txt\0"), "{detail:?}");
        assert!(detail.contains("\0old.txt\0new.txt\0"), "{detail:?}");
        // The letters numstat lacks: an added binary, a rename with its score.
        let letters = ok(files, root, &["show", "--name-status", "-z", "--format=%H%x1e", &repo.second]);
        assert!(letters.starts_with(&format!("{}\x1e", repo.second)), "{letters:?}");
        assert!(letters.contains("\nM\0a.txt\0"), "{letters:?}");
        assert!(letters.contains("\0A\0bin.dat\0"), "{letters:?}");
        assert!(letters.contains("\0R100\0old.txt\0new.txt\0"), "{letters:?}");
        let between = ok(files, root, &["diff", "--name-status", "-z", &repo.first, &repo.second]);
        assert!(between.contains("A\0bin.dat\0") && between.contains("R100\0old.txt\0new.txt\0"), "{between:?}");
        assert_eq!(ok(files, root, &["diff", "--cached", "--name-status", "-z"]), "M\0a.txt\0R100\0b.txt\0c.txt\0");
        let file = ok(files, root, &["show", &repo.second, "--", "a.txt"]);
        assert!(file.contains("diff --git a/a.txt b/a.txt\n") && file.contains("\n+two\n"), "{file}");
        assert!(!file.contains("bin.dat"));
        assert_eq!(ok(files, root, &["show", "-s", "--format=%s", &repo.first[..12]]), "one\n");

        let refs = ok(
            files,
            root,
            &["for-each-ref", "--format=%(refname)%09%(objectname)%09%(HEAD)", "refs/heads", "refs/remotes", "refs/tags"],
        );
        assert_eq!(
            refs,
            format!(
                "refs/heads/feature\t{}\t \nrefs/heads/main\t{}\t*\nrefs/tags/v1\t{}\t \n",
                repo.side, repo.second, repo.second
            )
        );
        let newest = ok(files, root, &["for-each-ref", "--sort=-committerdate", "--count=1", "--format=%(refname)", "refs/heads"]);
        assert_eq!(newest, "refs/heads/main\n");
        let pointing = ok(files, root, &["for-each-ref", &format!("--points-at={}", repo.side), "--format=%(refname)"]);
        assert_eq!(pointing, "refs/heads/feature\n");
    }
}

#[test]
fn anything_off_the_list_is_refused_by_name() {
    let repo = Repo::new("git-refusals");
    let root = &repo.root;
    // Each with the argument the refusal names.
    let refused: &[(&[&str], &str)] = &[
        (&["push"], "push"),
        (&["commit", "-m", "x"], "commit"),
        (&["stash"], "stash"),
        (&["checkout", "feature"], "checkout"),
        (&["config", "user.name"], "config"),
        (&["diff", "--output=x"], "--output=x"),
        (&["diff", "--binary"], "--binary"),
        (&["diff", "--ext-diff"], "--ext-diff"),
        (&["diff", "--textconv"], "--textconv"),
        (&["diff", "--no-index", "/etc/hosts", "/etc/hosts"], "--no-index"),
        (&["log", "-c", "x=y"], "-c"),
        (&["status", "-c", "x=y"], "-c"),
        (&["log", "--git-dir=/tmp"], "--git-dir=/tmp"),
        (&["status", "--work-tree=/tmp"], "--work-tree=/tmp"),
        (&["log", "--exec-path=/tmp"], "--exec-path=/tmp"),
        (&["log", "--frobnicate"], "--frobnicate"),
        (&["log", "-p"], "-p"),
        (&["log", "--show-signature"], "--show-signature"),
        (&["log", "-n", "1001"], "1001"),
        (&["log", "--max-count=5000"], "--max-count=5000"),
        (&["log", "-n"], "-n"),
        (&["log", "--format=%H %G?"], "%G?"),
        (&["show", "--pretty=%GS", "HEAD"], "%GS"),
        (&["for-each-ref", "--format=%(signature)"], "%(signature)"),
        (&["log", "main..feature"], "main..feature"),
        (&["log", "HEAD~1"], "HEAD~1"),
        (&["show", "HEAD:a.txt"], "HEAD:a.txt"),
        (&["status", "a.txt"], "a.txt"),
        (&["rev-parse", "--git-dir"], "--git-dir"),
        (&["rev-parse", "--", "a.txt"], "--"),
        (&["for-each-ref", "refs/notes"], "refs/notes"),
        (&["diff", "a\0b"], "diff"),
    ];
    for mut files in repo.plugins() {
        for (args, named) in refused {
            let error = run(&mut files, root, args, 0).unwrap_err();
            assert_eq!(error.code, "invalid_request", "{args:?}");
            assert!(error.message.contains(named), "{args:?}: {}", error.message);
        }
        // Not a request git ever sees.
        for (path, args) in [(Path::new("repo"), &["status"][..]), (root.as_path(), &[][..])] {
            assert_eq!(run(&mut files, path, args, 0).unwrap_err().code, "invalid_request");
        }
        // Paths after `--` are taken as given, even ones that look like options.
        assert_eq!(ok(&mut files, root, &["diff", "--", "--output=x"]), "");
        assert!(!root.join("x").exists() && !root.join("--output=x").exists());
    }
}

#[test]
fn reading_takes_no_lock_and_leaves_the_index_as_it_was() {
    let repo = Repo::new("git-locks");
    let root = &repo.root;
    let index = root.join(".git/index");
    // A tracked file whose content matches the index but whose time does not: a git that may write refreshes
    // the index's stat data for it.
    let file = std::fs::File::options().write(true).open(root.join("c.txt")).unwrap();
    file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000)).unwrap();
    drop(file);
    let before = std::fs::metadata(&index).unwrap().modified().unwrap();
    for mut files in repo.plugins() {
        for args in [
            &["status", "--porcelain=v2", "--branch", "-z", "--ignored"][..],
            &["diff", "--numstat", "-z"],
            &["diff", "--cached", "--numstat", "-z"],
            &["diff", "--", "c.txt"],
        ] {
            ok(&mut files, root, args);
            assert!(!root.join(".git/index.lock").exists(), "{args:?}");
            assert_eq!(std::fs::metadata(&index).unwrap().modified().unwrap(), before, "{args:?}");
        }
    }
    // The case is real: a git allowed to write does rewrite the index here.
    repo.git(&["status", "--porcelain"]);
    assert_ne!(std::fs::metadata(&index).unwrap().modified().unwrap(), before);
}

#[test]
fn output_past_the_bound_ends_at_its_last_record() {
    let repo = Repo::new("git-bound");
    let root = &repo.root;
    for mut files in repo.plugins() {
        let all = ok(&mut files, root, &["log", "--all", "--format=%H%x1f%s%x1e"]);
        assert_eq!(all.split('\x1e').count(), 4, "{all:?}");
        let second = all.match_indices('\x1e').nth(1).unwrap().0 + 1;
        // Two records and part of the third fit.
        let cut = run(&mut files, root, &["log", "--all", "--format=%H%x1f%s%x1e"], second as u64 + 5).unwrap();
        assert_eq!((cut.status, cut.truncated), (0, true));
        assert_eq!(cut.output, all[..second]);
        // Exactly the whole output is not past the bound.
        let whole = run(&mut files, root, &["log", "--all", "--format=%H%x1f%s%x1e"], all.len() as u64).unwrap();
        assert_eq!((whole.output.len(), whole.truncated), (all.len(), false));
        // NUL-terminated records with -z, lines otherwise.
        let status = run(&mut files, root, &["status", "--porcelain=v2", "-z"], 150).unwrap();
        assert!(status.truncated && status.output.ends_with('\0') && status.output.len() <= 150, "{status:?}");
        let patch = run(&mut files, root, &["diff", "--", "new.txt"], 40).unwrap();
        assert!(patch.truncated && patch.output == "diff --git a/new.txt b/new.txt\n", "{patch:?}");
        // A bound above the cap is the cap.
        assert!(!run(&mut files, root, &["log", "--all", "--format=%H"], u64::MAX).unwrap().truncated);
    }
    // Invalid UTF-8 counts as the text it becomes: U+FFFD is three bytes.
    assert_eq!(bounded(b"\xff\xff\n\xff\xff\n", 9, b'\n', false), ("\u{fffd}\u{fffd}\n".to_owned(), true));
    assert_eq!(bounded(b"\xff\n", 4, b'\n', false), ("\u{fffd}\n".to_owned(), false));
    assert_eq!(bounded(b"no end", 3, b'\n', false), (String::new(), true));
}

#[test]
fn a_git_that_runs_past_the_deadline_is_stopped() {
    let repo = Repo::new("git-deadline");
    let bin = repo.tree.file("bin/git", b"#!/bin/sh\nsleep 30 &\nwait\n");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut path = OsString::from(bin.parent().unwrap());
    path.push(":/bin:/usr/bin");
    for mut files in both() {
        files.git = Settings {
            environment: Some(vec![("PATH".into(), path.clone())]),
            deadline: Duration::from_secs(1),
        };
        let started = std::time::Instant::now();
        let git = run(&mut files, &repo.root, &["status", "--porcelain=v2", "-z"], 0).unwrap();
        assert_eq!(
            git,
            Git {
                status: -1,
                output: "git took longer than 1 s".into(),
                truncated: false
            }
        );
        assert!(started.elapsed() < Duration::from_secs(10));
    }
    assert_eq!(Settings::default().deadline, Duration::from_secs(20));
}

#[test]
fn a_host_without_git_says_so() {
    let repo = Repo::new("git-missing");
    let empty = repo.tree.root.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    for mut files in both() {
        files.git.environment = Some(vec![("PATH".into(), empty.clone().into())]);
        let error = run(&mut files, &repo.root, &["rev-parse", "--show-toplevel"], 0).unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("unsupported", "git is not installed on this host"));
    }
}

#[test]
fn git_runs_nothing_the_environment_or_repository_names() {
    let repo = Repo::new("git-scrub");
    let marker = repo.tree.root.join("ran");
    let script = repo.tree.file("tool.sh", format!("#!/bin/sh\ntouch '{}'\n", marker.display()).as_bytes());
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let script = script.to_str().unwrap().to_owned();
    // The repository's own configuration names the same program: an external diff, a diff driver with
    // textconv, fsmonitor, a pager.
    repo.git(&["config", "diff.external", &script]);
    repo.git(&["config", "diff.tool.command", &script]);
    repo.git(&["config", "diff.tool.textconv", &script]);
    repo.git(&["config", "core.fsmonitor", &script]);
    repo.git(&["config", "core.pager", &script]);
    repo.write(".git/info/attributes", b"* diff=tool\n");
    let mut environment = repo.environment();
    for (name, value) in [
        ("GIT_EXTERNAL_DIFF", script.as_str()),
        ("GIT_PAGER", script.as_str()),
        ("PAGER", script.as_str()),
        ("GIT_DIR", "/nonexistent"),
        ("GIT_WORK_TREE", "/nonexistent"),
        ("GIT_CONFIG_PARAMETERS", "'core.fsmonitor'='/bin/false'"),
        ("GIT_CONFIG_COUNT", "1"),
        ("GIT_CONFIG_KEY_0", "diff.external"),
        ("GIT_CONFIG_VALUE_0", script.as_str()),
        ("GIT_SSH_COMMAND", script.as_str()),
        ("GIT_PROXY_COMMAND", script.as_str()),
    ] {
        environment.push((name.into(), value.into()));
    }
    for mut files in both() {
        files.git.environment = Some(environment.clone());
        let files = &mut files;
        let patch = ok(files, &repo.root, &["diff", "--", "new.txt"]);
        assert!(patch.contains("\n+changed\n"), "{patch}");
        assert!(ok(files, &repo.root, &["show", &repo.second]).contains("diff --git a/a.txt b/a.txt"));
        assert_eq!(ok(files, &repo.root, &["log", "-n", "1", "--format=%s"]), "two\n");
        assert!(ok(files, &repo.root, &["status", "--porcelain=v2", "-z"]).contains(" new.txt\0"));
        assert!(!marker.exists());
    }
    // The case is real: the shell's git, in that environment, runs it.
    let mut shell = repo.setup();
    shell.env("GIT_EXTERNAL_DIFF", &script).args(["diff", "--", "new.txt"]).output().unwrap();
    assert!(marker.exists());
}

#[test]
fn a_folder_outside_any_repository_answers_with_gits_failure() {
    let repo = Repo::new("git-outside");
    // Not the test temp root: cargo puts that in helper/target, inside this checkout.
    let outside = Tree::under(Path::new("/tmp"), "git-outside");
    let outside = &outside.root;
    for mut files in repo.plugins() {
        let git = run(&mut files, outside, &["rev-parse", "--show-toplevel"], 0).unwrap();
        assert_eq!((git.status, git.truncated), (128, false));
        assert!(git.output.contains("not a git repository"), "{}", git.output);
        let missing = run(&mut files, &outside.join("missing"), &["status", "--porcelain=v2"], 0).unwrap();
        assert_eq!(missing.status, 128, "{}", missing.output);
    }
}

/// An executable script under the test tree.
fn script(repo: &Repo, name: &str, body: &str) -> String {
    let path = repo.tree.file(name, format!("#!/bin/sh\n{body}").as_bytes());
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_str().unwrap().to_owned()
}

/// Makes `name`'s stat data disagree with the index while its content agrees: git hashes it again to compare.
fn stat_dirty(repo: &Repo, name: &str) {
    let file = std::fs::File::options().write(true).open(repo.root.join(name)).unwrap();
    file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000)).unwrap();
}

#[test]
fn named_formats_and_signature_checks_never_run_gpg() {
    let repo = Repo::new("git-gpg");
    let root = &repo.root;
    let marker = repo.tree.root.join("gpg-ran");
    let gpg = script(&repo, "gpg.sh", &format!("touch '{}'\nexit 1\n", marker.display()));
    // HEAD again, with a signature header: anything that checks it runs gpg.program.
    let raw = repo.git(&["cat-file", "commit", "HEAD"]);
    let (headers, message) = raw.split_once("\n\n").unwrap();
    let signed = format!(
        "{headers}\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEEAAAA\n \
         -----END PGP SIGNATURE-----\n\n{message}"
    );
    let path = repo.tree.file("signed-commit", signed.as_bytes());
    let hash = repo.git(&["hash-object", "-w", "-t", "commit", path.to_str().unwrap()]).trim().to_owned();
    repo.git(&["update-ref", "refs/heads/main", &hash]);
    repo.git(&["config", "pretty.x", "format:%G?"]);
    repo.git(&["config", "format.pretty", "format:%G?"]);
    for key in ["gpg.program", "gpg.openpgp.program", "gpg.ssh.program", "gpg.x509.program"] {
        repo.git(&["config", key, &gpg]);
    }
    for mut files in repo.plugins() {
        let files = &mut files;
        for args in [
            &["log", "--format=x", "-n", "1"][..],
            &["log", "--pretty=x", "-n", "1"],
            &["show", "--format=x", "-s", &hash],
            &["log", "--format=%+G?", "-n", "1"],
            &["log", "--format=%-G?", "-n", "1"],
            &["log", "--format=% GS", "-n", "1"],
            &["for-each-ref", "--format=%(*signature)", "refs/tags"],
            &["for-each-ref", "--format=%(signature:key)", "refs/tags"],
            &["for-each-ref", "--sort=signature:grade", "refs/tags"],
        ] {
            let error = run(files, root, args, 0).unwrap_err();
            assert_eq!(error.code, "invalid_request", "{args:?}");
            assert!(error.message.contains(args[1]), "{args:?}: {}", error.message);
        }
        // The raw format names the signature without checking it.
        let raw = ok(files, root, &["log", "--pretty=raw", "-n", "1"]);
        assert!(raw.contains("\ngpgsig -----BEGIN PGP SIGNATURE-----"), "{raw}");
        // No format: the built-in default, never `format.pretty`.
        let log = ok(files, root, &["log", "-n", "1"]);
        assert!(log.starts_with(&format!("commit {hash}")), "{log}");
        let show = ok(files, root, &["show", "-s", &hash]);
        assert!(show.starts_with(&format!("commit {hash}")) && show.contains("    two"), "{show}");
        // Formats git takes as formats, the app's empty one among them.
        assert_eq!(ok(files, root, &["log", "-n", "1", "--format=format:x"]), "x");
        assert_eq!(ok(files, root, &["log", "-n", "1", "--format=tformat:%s"]), "two\n");
        assert_eq!(ok(files, root, &["show", "--format=", "--stat", &hash, "--", "a.txt"]).lines().count(), 2);
        assert!(!marker.exists());
    }
    // The case is real: the shell's git checks the signature for the configured format.
    repo.git(&["log", "-n", "1"]);
    assert!(marker.exists());
}

#[test]
fn a_repositorys_filters_never_run() {
    let repo = Repo::new("git-filters");
    let root = &repo.root;
    let marker = repo.tree.root.join("filter-ran");
    let filter = script(&repo, "filter.sh", &format!("touch '{}'\ncat\n", marker.display()));
    repo.git(&["config", "filter.evil.clean", &filter]);
    repo.git(&["config", "filter.evil.process", &filter]);
    repo.git(&["config", "filter.evil.required", "true"]);
    // A name with a dot in it, from the repository's config too.
    repo.git(&["config", "filter.dotted.name.clean", &filter]);
    repo.write(".git/info/attributes", b"*.txt filter=evil\nc.txt filter=dotted.name\n");
    stat_dirty(&repo, "c.txt");
    stat_dirty(&repo, "a.txt");
    let reads: &[&[&str]] = &[
        &["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"],
        &["diff", "--numstat", "-z"],
        &["diff", "--cached", "--numstat", "-z"],
        &["diff", "-U3", "--", "new.txt"],
    ];
    for mut files in repo.plugins() {
        let files = &mut files;
        for args in reads {
            ok(files, root, args);
        }
        let status = ok(files, root, reads[0]);
        assert!(status.contains(" new.txt\0") && status.contains("? untracked.txt\0"), "{status:?}");
        // The second time round bin.dat is stat-dirty too, which a diff that may not refresh the index lists as
        // a binary change (`-\t-`).
        assert!(ok(files, root, &["diff", "--numstat", "-z"]).ends_with("1\t0\tnew.txt\0"));
        assert!(!marker.exists());
        // A filter configured after the helper first read the repository's: the changed config file is read
        // again.
        repo.git(&["config", "filter.later.clean", &filter]);
        repo.write(".git/info/attributes", b"*.txt filter=evil\nc.txt filter=dotted.name\n*.dat filter=later\n");
        stat_dirty(&repo, "bin.dat");
        ok(files, root, reads[0]);
        assert!(!marker.exists());
        repo.git(&["config", "--remove-section", "filter.later"]);
    }
    // The case is real: the shell's git runs the filter for a stat-dirty file (and fails, the stand-in not
    // speaking the process protocol).
    repo.setup().args(["status", "--porcelain"]).output().unwrap();
    assert!(marker.exists());
}

#[test]
fn filters_are_reloaded_when_other_config_scopes_or_conditions_change() {
    let repo = Repo::new("git-filter-scopes");
    let marker = repo.tree.root.join("filter-ran");
    let filter = script(&repo, "filter.sh", &format!("touch '{}'\ncat\n", marker.display()));
    repo.write(".git/info/attributes", b"*.txt filter=late\n");
    stat_dirty(&repo, "a.txt");

    // This include is inactive on main, so the first request sees no `late` filter. Switching HEAD changes which
    // config Git reads without changing .git/config itself.
    let included = repo.tree.file(
        "conditional.gitconfig",
        format!("[filter \"late\"]\n\tclean = {filter}\n\trequired = true\n").as_bytes(),
    );
    repo.git(&[
        "config",
        "includeIf.onbranch:feature.path",
        included.to_str().unwrap(),
    ]);
    for mut files in repo.plugins() {
        ok(&mut files, &repo.root, &["status", "--porcelain=v2", "-z"]);
        assert!(!marker.exists());
        repo.git(&["symbolic-ref", "HEAD", "refs/heads/feature"]);
        ok(&mut files, &repo.root, &["status", "--porcelain=v2", "-z"]);
        assert!(!marker.exists());
        repo.git(&["symbolic-ref", "HEAD", "refs/heads/main"]);

        // The user's config is another independent scope; changing it must not reuse a repository-only cache.
        std::fs::write(
            repo.home.join(".gitconfig"),
            format!("[filter \"late\"]\n\tclean = {filter}\n\trequired = true\n"),
        )
        .unwrap();
        ok(&mut files, &repo.root, &["status", "--porcelain=v2", "-z"]);
        assert!(!marker.exists());
        std::fs::remove_file(repo.home.join(".gitconfig")).unwrap();
    }
}

#[test]
fn git_lookup_never_uses_a_relative_path_or_home() {
    let settings = Settings {
        environment: Some(vec![
            ("PATH".into(), ".:/tmp/bin::relative:/usr/bin".into()),
            ("HOME".into(), "relative-home".into()),
        ]),
        ..Settings::default()
    };
    let sanitized = command(&settings, Path::new("/tmp"), &[], &[], &["status"]);
    assert!(Path::new(sanitized.get_program()).is_absolute());
    let environment: std::collections::BTreeMap<_, _> = sanitized
        .get_envs()
        .filter_map(|(name, value)| value.map(|value| (name.to_owned(), value.to_owned())))
        .collect();
    let path = environment.get(std::ffi::OsStr::new("PATH")).unwrap();
    assert!(std::env::split_paths(path).all(|part| part.is_absolute()));
    assert_eq!(std::env::split_paths(path).next().unwrap(), Path::new(sanitized.get_program()).parent().unwrap());
    assert!(!environment.contains_key(std::ffi::OsStr::new("HOME")));

    // A protected immediate bin directory is not trusted through a group/world-writable ancestor.
    let tree = Tree::new("git-path-ancestor");
    let fake = tree.file("writable/protected/bin/git", b"#!/bin/sh\nexit 0\n");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::set_permissions(fake.parent().unwrap(), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::set_permissions(tree.root.join("writable"), std::fs::Permissions::from_mode(0o777)).unwrap();
    let settings = Settings {
        environment: Some(vec![("PATH".into(), format!("{}:/usr/bin:/bin", fake.parent().unwrap().display()).into())]),
        ..Settings::default()
    };
    let unsafe_command = command(&settings, Path::new("/tmp"), &[], &[], &["status"]);
    assert_ne!(Path::new(unsafe_command.get_program()), std::fs::canonicalize(fake).unwrap());
}

#[test]
fn a_submodules_filters_never_run_and_it_shows_by_its_commit() {
    let repo = Repo::new("git-submodule");
    let root = &repo.root;
    let module = repo.tree.root.join("module");
    std::fs::create_dir_all(&module).unwrap();
    let mut init = repo.setup();
    init.current_dir(&module).args(["init", "-q"]);
    assert!(init.status().unwrap().success());
    std::fs::write(module.join("f.txt"), b"x\n").unwrap();
    let mut commit = repo.setup();
    commit.current_dir(&module).args(["commit", "-q", "--allow-empty", "-m", "m"]);
    let mut add = repo.setup();
    add.current_dir(&module).args(["add", "f.txt"]);
    assert!(add.status().unwrap().success() && commit.status().unwrap().success());
    let source = module.to_str().unwrap();
    repo.git(&["-c", "protocol.file.allow=always", "submodule", "add", "-q", source, "sub"]);
    repo.commit("sub", 1_700_000_400);
    // The submodule's own configuration names a filter and asks to be compared whole, the superproject's too.
    let marker = repo.tree.root.join("filter-ran");
    let filter = script(&repo, "filter.sh", &format!("touch '{}'\ncat\n", marker.display()));
    repo.git(&["--git-dir=.git/modules/sub", "config", "filter.evil.clean", &filter]);
    repo.write(".git/modules/sub/info/attributes", b"* filter=evil\n");
    repo.git(&["config", "submodule.sub.ignore", "none"]);
    stat_dirty(&repo, "sub/f.txt");
    for mut files in repo.plugins() {
        let files = &mut files;
        let status = ok(files, root, &["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]);
        assert!(!status.contains(" sub\0"), "{status:?}");
        ok(files, root, &["diff", "--numstat", "-z"]);
        ok(files, root, &["diff", "-U3", "--", "sub"]);
        assert!(!marker.exists());
    }
    // The case is real: the shell's git looks inside and runs the submodule's filter.
    repo.git(&["status", "--porcelain"]);
    assert!(marker.exists());
    std::fs::remove_file(&marker).unwrap();
    // A submodule whose checked-out commit moved still shows.
    let mut moved = repo.setup();
    moved.current_dir(root.join("sub")).args(["commit", "-q", "--allow-empty", "-m", "moved"]);
    assert!(moved.status().unwrap().success());
    // The shell's commit may have run the filter itself.
    std::fs::remove_file(&marker).ok();
    stat_dirty(&repo, "sub/f.txt");
    for mut files in repo.plugins() {
        let status = ok(&mut files, root, &["status", "--porcelain=v2", "-z"]);
        let record = status.split('\0').find(|record| record.ends_with(" sub"));
        assert!(record.is_some_and(|record| record.starts_with("1 .M SC.. 160000 ")), "{status:?}");
        assert!(!marker.exists());
    }
}

#[test]
fn a_filter_name_git_cannot_be_told_to_skip_stops_the_command() {
    let repo = Repo::new("git-filter-name");
    let marker = repo.tree.root.join("filter-ran");
    let filter = script(&repo, "filter.sh", &format!("touch '{}'\ncat\n", marker.display()));
    std::fs::OpenOptions::new()
        .append(true)
        .open(repo.root.join(".git/config"))
        .and_then(|mut file| {
            use std::io::Write;
            writeln!(file, "[filter \"a=b\"]\n\tclean = {filter}")
        })
        .unwrap();
    repo.write(".git/info/attributes", b"* filter=a=b\n");
    stat_dirty(&repo, "c.txt");
    for mut files in repo.plugins() {
        let error = run(&mut files, &repo.root, &["status", "--porcelain=v2", "-z"], 0).unwrap_err();
        assert_eq!(error.code, "unsupported", "{}", error.message);
        assert!(error.message.contains("a=b"), "{}", error.message);
        assert!(!marker.exists());
    }
}

#[test]
fn paths_stay_relative_and_inside() {
    let repo = Repo::new("git-paths");
    let root = &repo.root;
    for mut files in repo.plugins() {
        let files = &mut files;
        for (args, named) in [
            (&["diff", "--", "/etc/hosts", "a.txt"][..], "/etc/hosts"),
            (&["diff", "--", "a.txt", "../outside"], "../outside"),
            (&["diff", "--cached", "--", "a/../../x"], "a/../../x"),
            (&["status", "--porcelain=v2", "--", ".."], ".."),
            (&["log", "--format=%H", "--", "/"], "/"),
            (&["show", &repo.second, "--", "x/.."], "x/.."),
        ] {
            let error = run(files, root, args, 0).unwrap_err();
            assert_eq!(error.code, "invalid_request", "{args:?}");
            assert!(error.message.ends_with(&format!("the path {named}")), "{args:?}: {}", error.message);
        }
        // Dots that are part of a name are a name.
        assert_eq!(ok(files, root, &["diff", "--", "a..b.txt", "..x", "./a.txt"]), "");
        assert!(ok(files, root, &["diff", "-U3", "--", "new.txt", "old.txt"]).contains("+changed"));
    }
}

#[test]
fn git_speaks_english_whatever_the_helpers_locale() {
    let repo = Repo::new("git-locale");
    // A stand-in git that says where it is (not a repository) and then prints its environment.
    let bin = script(&repo, "bin/git", "case \"$*\" in *rev-parse\\ --git-path*) exit 128;; esac\nenv\n");
    let mut path = OsString::from(Path::new(&bin).parent().unwrap());
    path.push(":/bin:/usr/bin");
    for mut files in both() {
        files.git.environment = Some(vec![
            ("PATH".into(), path.clone()),
            ("HOME".into(), repo.home.clone().into()),
            ("USER".into(), "someone".into()),
            ("LANG".into(), "de_DE.UTF-8".into()),
            ("LC_ALL".into(), "de_DE.UTF-8".into()),
            ("LC_MESSAGES".into(), "de_DE.UTF-8".into()),
            ("LANGUAGE".into(), "de".into()),
            ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
        ]);
        let output = ok(&mut files, &repo.root, &["rev-parse", "--show-toplevel"]);
        let mut names: Vec<&str> =
            output.lines().filter_map(|line| line.split_once('=')).map(|(name, _)| name).collect();
        names.retain(|name| !matches!(*name, "PWD" | "SHLVL" | "_" | "OLDPWD" | "__CF_USER_TEXT_ENCODING"));
        names.sort_unstable();
        assert_eq!(
            names,
            [
                "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_SYSTEM", "GIT_NO_LAZY_FETCH",
                "GIT_OPTIONAL_LOCKS", "GIT_PAGER", "GIT_TERMINAL_PROMPT", "HOME", "LC_ALL", "PATH", "USER"
            ],
            "{output}"
        );
        assert!(output.lines().any(|line| line == "LC_ALL=C"), "{output}");
    }
}

#[test]
fn the_users_own_configuration_does_not_change_what_the_app_parses() {
    let repo = Repo::new("git-user-config");
    let root = &repo.root;
    repo.git(&["tag", "-a", "v2", "-m", "annotated", &repo.first]);
    let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x1e";
    let parent = repo.first.clone();
    let second = repo.second.clone();
    let commands: Vec<Vec<&str>> = vec![
        vec!["rev-parse", "--show-toplevel"],
        vec!["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"],
        vec!["diff", "--numstat", "-z"],
        vec!["diff", "--cached", "--numstat", "-z"],
        vec!["diff", "-U3", "--", "new.txt"],
        vec!["diff", "--cached", "-U3", "--", "c.txt", "b.txt"],
        vec!["diff", "--cached", "--stat", "--", "a.txt"],
        vec!["log", "-n", "200", "--skip=0", format, "--date=unix", "--all"],
        vec!["log", "-n", "200", "--skip=0", format, "--date=unix", "--grep=two", "--regexp-ignore-case"],
        vec!["log", "-n", "200", format, "--date=unix", "--author=test", "--regexp-ignore-case", "--fixed-strings"],
        vec!["show", "--numstat", "-z", format, &second],
        vec!["show", "--name-status", "-z", format, &second],
        vec!["show", "--format=", "-U3", &second, "--", "a.txt"],
        vec!["show", "--stat", "--format=", &second, "--", "a.txt"],
        vec!["diff", "-U3", &parent, &second, "--", "a.txt"],
        vec!["for-each-ref", "--format=%(refname)%09%(objectname)%09%(HEAD)", "refs/heads", "refs/remotes"],
        vec!["for-each-ref", "--format=%(refname)%09%(objectname)%09%(*objectname)", "refs/tags"],
    ];
    for mut files in repo.plugins() {
        let files = &mut files;
        let before: Vec<String> = commands.iter().map(|args| ok(files, root, args)).collect();
        assert!(before[7].contains("HEAD -> main, tag: v1"), "{}", before[7]);
        assert!(before[4].starts_with("diff --git a/new.txt b/new.txt\n"), "{}", before[4]);
        std::fs::write(
            repo.home.join(".gitconfig"),
            "[log]\n\tdecorate = full\n\tabbrevCommit = true\n[diff]\n\tmnemonicPrefix = true\n\tnoprefix = true\n\
             \trelative = true\n\tsubmodule = log\n\tsrcPrefix = x/\n\tdstPrefix = y/\n[color]\n\tdiff = always\n\
             \tui = always\n[core]\n\tquotepath = true\n[format]\n\tpretty = fuller\n",
        )
        .unwrap();
        for (args, before) in commands.iter().zip(&before) {
            assert_eq!(&ok(files, root, args), before, "{args:?}");
        }
        std::fs::remove_file(repo.home.join(".gitconfig")).unwrap();
    }
}

#[test]
fn records_can_end_with_a_nul_no_message_holds() {
    let repo = Repo::new("git-record-end");
    let root = &repo.root;
    assert_eq!(allowed(&["log".into(), "--format=%H%x1f%s%x1e".into()]), Ok(0x1e));
    assert_eq!(allowed(&["log".into(), "--format=%H%x1f%b%x1e%x00".into()]), Ok(0));
    assert_eq!(allowed(&["show".into(), "--format=%H%X00".into(), repo.first.clone()]), Ok(0));
    // A message that forges the 0x1E end and a field: only the NUL ends a record.
    repo.commit("forged\x1e\x1fsubject", 1_700_000_300);
    let format = "--format=%H%x1f%s%x00";
    for mut files in repo.plugins() {
        let all = ok(&mut files, root, &["log", format]);
        let records: Vec<&str> = all.split('\0').map(|record| record.trim_start_matches('\n')).collect();
        assert_eq!(records.len(), 4, "{all:?}");
        assert!(records[0].ends_with("\x1fforged\x1e\x1fsubject"), "{all:?}");
        let first = all.find('\0').unwrap() + 1;
        let cut = run(&mut files, root, &["log", format], first as u64 + 30).unwrap();
        assert_eq!((cut.output.as_str(), cut.truncated), (&all[..first], true));
    }
}

#[test]
fn for_each_ref_resolves_annotated_tags_to_their_commit() {
    let repo = Repo::new("git-peeled");
    repo.git(&["tag", "-a", "v2", "-m", "annotated", &repo.first]);
    let tag = repo.git(&["rev-parse", "v2"]).trim().to_owned();
    for mut files in repo.plugins() {
        let refs = ok(
            &mut files,
            &repo.root,
            &["for-each-ref", "--format=%(refname)%09%(objecttype)%09%(objectname)%09%(*objectname)", "refs/tags"],
        );
        assert_eq!(
            refs,
            format!("refs/tags/v1\tcommit\t{}\t\nrefs/tags/v2\ttag\t{tag}\t{}\n", repo.second, repo.first)
        );
    }
}

#[test]
fn a_status_past_the_bound_ends_at_a_whole_record() {
    let repo = Repo::new("git-status-bound");
    let root = &repo.root;
    let folder = root.join("many");
    std::fs::create_dir_all(&folder).unwrap();
    for index in 0..20_000 {
        std::fs::write(folder.join(format!("untracked-file-{index:05}.txt")), b"").unwrap();
    }
    let args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"];
    for mut files in repo.plugins() {
        let whole = ok(&mut files, root, &args);
        assert!(whole.len() > 600_000, "{}", whole.len());
        let limit = 64 << 10;
        let cut = run(&mut files, root, &args, limit).unwrap();
        assert_eq!((cut.status, cut.truncated), (0, true));
        assert!(cut.output.len() <= limit as usize && cut.output.len() > limit as usize - 100);
        assert!(cut.output.ends_with('\0') && whole.starts_with(&cut.output));
        let untracked = cut.output.split_terminator('\0').filter_map(|record| record.strip_prefix("? many/"));
        assert!(untracked.clone().count() > 1_000);
        assert!(untracked.clone().all(|name| folder.join(name).is_file()));
    }
}

#[test]
fn a_signature_check_runs_only_the_programs_the_helper_trusts() {
    let repo = Repo::new("git-verify");
    let root = &repo.root;
    let marker = repo.tree.root.join("repository-gpg-ran");
    let evil = script(&repo, "evil.sh", &format!("touch '{}'\nexit 0\n", marker.display()));
    let raw = repo.git(&["cat-file", "commit", "HEAD"]);
    let (headers, message) = raw.split_once("\n\n").unwrap();
    let signed = format!(
        "{headers}\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEEAAAA\n \
         -----END PGP SIGNATURE-----\n\n{message}"
    );
    let path = repo.tree.file("signed-commit", signed.as_bytes());
    let hash = repo.git(&["hash-object", "-w", "-t", "commit", path.to_str().unwrap()]).trim().to_owned();
    // The repository names its own programs and signers: none of them may count.
    for key in ["gpg.program", "gpg.openpgp.program", "gpg.ssh.program"] {
        repo.git(&["config", key, &evil]);
    }
    repo.git(&["config", "gpg.minTrustLevel", "ultimate"]);
    // The gpg the helper finds on PATH answers for the check; git passes it `--status-fd=1`.
    let bin = repo.tree.root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let gpg = script(&repo, "bin/gpg", "echo '[GNUPG:] NEWSIG'\necho '[GNUPG:] GOODSIG 0123456789ABCDEF Test <test@example.com>'\n\
         echo '[GNUPG:] VALIDSIG 00112233445566778899AABBCCDDEEFF00112233 2026-01-01 0 4 0 1 10 00'\nexit 0\n");
    assert!(gpg.ends_with("bin/gpg"));
    let mut path_value = OsString::from(&bin);
    path_value.push(":");
    path_value.push(std::env::var_os("PATH").unwrap_or_default());
    for mut files in repo.plugins() {
        let mut environment = repo.environment();
        environment.retain(|(name, _)| name != "PATH");
        environment.push(("PATH".into(), path_value.clone()));
        files.git.environment = Some(environment);
        let files = &mut files;
        let git = run(files, root, &["verify-commit", "--raw", &hash], 0).unwrap();
        assert_eq!(git.status, 0, "{}", git.output);
        assert!(git.output.contains("GOODSIG 0123456789ABCDEF Test <test@example.com>"), "{}", git.output);
        assert!(!marker.exists(), "the repository's gpg ran");
        for args in [&["verify-commit", "--verbose", &hash][..], &["verify-commit", "--raw", "HEAD"]] {
            assert_eq!(run(files, root, args, 0).unwrap_err().code, "invalid_request", "{args:?}");
        }
    }
    // A repository's signers file would vouch for its own key: only the user's, else none.
    let config = signing(&OsString::from("/nonexistent-path"), None).join(" ");
    assert!(config.contains("gpg.ssh.allowedSignersFile=/dev/null"), "{config}");
    assert!(config.contains("gpg.x509.program=/nonexistent"), "{config}");
    let config = signing(&OsString::from("/nonexistent-path"), Some("/Users/me/.ssh/allowed_signers")).join(" ");
    assert!(config.contains("gpg.ssh.allowedSignersFile=/Users/me/.ssh/allowed_signers"), "{config}");
}

#[cfg(target_os = "macos")]
#[test]
fn administrators_are_the_admin_groups_members() {
    // root is in macOS's admin group; no account has this uid.
    assert!(administrator(0));
    assert!(!administrator(3_999_999_999));
}
