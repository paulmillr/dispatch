#!/usr/bin/env python3
"""Build and launch the hardened Release app outside the XCTest host (disposable Mac)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CONTROLLER = r'''
import AppKit

let app = Process()
app.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
app.environment = ProcessInfo.processInfo.environment
app.currentDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[2])
let receipt = URL(fileURLWithPath: CommandLine.arguments[3])
func visible() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 0
    }
}
func shell() -> Bool {
    guard let value = try? String(contentsOf: receipt, encoding: .utf8),
          let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
}
var failure: String?
do {
    guard URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == app.currentDirectoryURL?.resolvingSymlinksInPath() else {
        throw NSError(domain: "Release smoke HOME was not isolated", code: 1)
    }
    try app.run()
    let deadline = Date().addingTimeInterval(30)
    while app.isRunning && !(visible() && shell()) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard app.isRunning && visible() && shell() else {
        throw NSError(domain: "Release app did not open a window and PTY shell", code: 1)
    }
    let until = Date().addingTimeInterval(5)
    while Date() < until {
        guard app.isRunning && visible() && shell() else {
            throw NSError(domain: "Release app or terminal stopped after launch", code: 1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
} catch { failure = String(describing: error) }
if app.isRunning {
    NSRunningApplication(processIdentifier: app.processIdentifier)?.terminate()
    let deadline = Date().addingTimeInterval(10)
    while app.isRunning && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if app.isRunning {
        failure = failure ?? "Release app did not quit"
        app.terminate()
        let deadline = Date().addingTimeInterval(3)
        while app.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if app.isRunning { kill(app.processIdentifier, SIGKILL) }
    }
}
if app.processIdentifier > 0 {
    app.waitUntilExit()
    if app.terminationReason != .exit || app.terminationStatus != 0 {
        failure = failure ?? "Release app did not exit normally: \(app.terminationStatus)"
    }
}
if let failure { fputs(failure + "\n", stderr); exit(1) }
print("Release launch: visible window and live PTY for five seconds; clean quit")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Check an already built app instead of building Release')
    args = parser.parse_args()
    build = ROOT / 'build/release-smoke'
    build.mkdir(parents=True, exist_ok=True)
    if args.app is None:
        subprocess.run([str(ROOT / 'run.sh'), '--prod', '--just-build'], cwd=ROOT, check=True, timeout=1800)
    app = (args.app or ROOT / 'build/Build/Products/Release/Dispatch.app').resolve()
    source = build / 'controller.swift'
    source.write_text(CONTROLLER)
    controller = build / 'controller'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(build / 'modules'),
                    str(source), '-o', str(controller)], check=True, timeout=120)
    with tempfile.TemporaryDirectory(prefix='home-', dir=os.environ.get('DISPATCH_TEST_ROOT', build)) as directory:
        home = Path(directory)
        settings = home / 'Library/Application Support/Dispatch/Local/settings.json'
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({'startingDirectory': str(home)}))
        # The regular login-shell path sources this private startup file. The
        # receipt proves terminal creation and command execution, not just a PID.
        (home / '.zshenv').write_text('export HOME="$ZDOTDIR"\n')
        (home / '.zshrc').write_text('[[ -t 0 && -t 1 ]] && printf "%s\\n" "$$" > "$DISPATCH_RELEASE_RECEIPT"\n')
        receipt = home / 'terminal.pid'
        env = dict(os.environ, HOME=directory, CFFIXED_USER_HOME=directory, ZDOTDIR=directory,
                   DISPATCH_RELEASE_RECEIPT=str(receipt))
        for key in list(env):
            if key.startswith(('DYLD_', 'TEST_RUNNER_', 'DISPATCH_TEST')) or key in ('DISPATCH_HELPER2', 'XCTestConfigurationFilePath'):
                del env[key]
        with (build / 'launch.log').open('w') as output:
            result = subprocess.run([str(controller), str(app / 'Contents/MacOS/Dispatch'), directory, str(receipt)],
                                    cwd=home, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=60)
        print((build / 'launch.log').read_text(), end='')
        (build / 'result.json').write_text(json.dumps({'app': str(app), 'engine': engine, 'exit_code': result.returncode}) + '\n')
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
