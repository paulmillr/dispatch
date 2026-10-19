#!/usr/bin/env python3
"""Write Mobile/ThirdPartyLicenses/MobileTransport/Dependencies.txt: the crates linked into the iPhone SSH engine
(Mobile/Transport/Core, from its Cargo.lock), with their declared licences and license files reproduced
verbatim from build/cargo. Needs the crates fetched (python3 scripts/build-mobile-ssh.py --fetch)."""
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / "Mobile/Transport/Core"
CARGO_HOME = ROOT / "build/cargo"
OUTPUT = ROOT / "Mobile/ThirdPartyLicenses/MobileTransport/Dependencies.txt"
NOTICE = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)", re.I)


def crates():
    """(name, version, licence, proc-macro) for the normal dependencies of the iOS build."""
    env = dict(os.environ, CARGO_HOME=str(CARGO_HOME),
               PATH=str(ROOT / "build/rust/bin") + os.pathsep + os.environ.get("PATH", ""))
    tree = subprocess.run(["cargo", "tree", "--offline", "--frozen", "--target", "aarch64-apple-ios", "-e", "normal",
                           "--prefix", "none", "--format", "{p}\t{l}"], cwd=CRATE, env=env, check=True,
                          capture_output=True, text=True).stdout
    seen = {}
    for line in tree.splitlines():
        package, _, licence = line.partition("\t")
        fields = package.replace(" (*)", "").split()
        if len(fields) < 2 or fields[0] == "dispatch-mobile-ssh":
            continue
        seen[(fields[0], fields[1].lstrip("v"))] = (licence.replace("(*)", "").strip(), "(proc-macro)" in package)
    return sorted((name, version, licence, macro) for (name, version), (licence, macro) in seen.items())


def source(name, version):
    for index in sorted((CARGO_HOME / "registry/src").iterdir()):
        directory = index / f"{name}-{version}"
        if directory.is_dir():
            return directory
    raise SystemExit(f"{name} {version} is not fetched into {CARGO_HOME} (scripts/build-mobile-ssh.py --fetch)")


def main():
    listed = crates()
    out = ["iPhone SSH engine (Mobile/Transport/Core) dependencies", "",
           "Rust crates statically linked into DispatchMobileSSHCore (Cargo.lock), built with the pinned Rust",
           "toolchain, whose standard-library attribution is ThirdPartyLicenses/RustSSHHelper/COPYRIGHT-library.html.",
           "Procedural macros run only at build time and ship no code. Each crate's license files follow,",
           "reproduced from its published package.", "",
           "Crates (%d):" % len(listed)]
    out += ["  %s %s  %s%s" % (name, version, licence, "  (build-time macro)" if macro else "") for name, version, licence, macro in listed]
    out.append("")
    apache = None
    for name, version, licence, macro in listed:
        directory = source(name, version)
        out += ["=" * 72, f"{name}-{version}", f"Declared license: {licence}", ""]
        files = sorted(p for p in directory.iterdir() if p.is_file() and NOTICE.match(p.name))
        if not files:
            out += ["(the package ships no license file: used under Apache-2.0, whose text closes this file)", ""]
        apache = apache or next((p for p in files if p.name.upper() == "LICENSE-APACHE"), None)
        for path in files:
            out += [path.name, "-" * len(path.name), path.read_text(errors="replace").rstrip(), ""]
    out += ["=" * 72, "Apache License 2.0 (for the packages above that ship no license file)", "",
            apache.read_text().rstrip(), ""]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(out).rstrip() + "\n")


if __name__ == "__main__":
    main()
