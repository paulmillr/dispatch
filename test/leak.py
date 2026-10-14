#!/usr/bin/env python3
"""What a test run with these arguments (test/run.sh's) may record about the machines it touches: this Mac and every
SSH test host of the checkout's profiles. Prints a needles file draft (docs/capture_scrub.md): `#` lines say where the
values below them come from; process lists are context, as comments. Keep the private values, delete the public ones,
then search the captures for them (capture grep --needles). The output holds private values: keep it out of anything
shared. Environments are not printed (they can hold credentials): the helper records its own at startup, read it there."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'test'))
import xcode

# What every machine is asked (this one through sh, an SSH test host through ssh): each command's output lines come back
# as `kind<TAB>line`; a command the machine lacks answers nothing.
COMMANDS = (('account', 'id -un'), ('name', 'id -F'), ('passwd', 'getent passwd "$(id -un)"'), ('home', 'echo "$HOME"'),
            ('temporary', 'echo "$TMPDIR"'), ('temporary', 'getconf DARWIN_USER_TEMP_DIR'),
            ('temporary', 'getconf DARWIN_USER_CACHE_DIR'), ('host', 'hostname'), ('host', 'scutil --get ComputerName'),
            ('host', 'scutil --get LocalHostName'), ('host', 'scutil --get HostName'), ('id', 'cat /etc/machine-id'),
            ('id', 'cat /proc/sys/kernel/random/boot_id'), ('id', 'sysctl -n kern.uuid kern.bootsessionuuid'),
            ('hardware', 'ioreg -rd1 -c IOPlatformExpertDevice'), ('hardware', 'system_profiler SPHardwareDataType'),
            ('address', 'ifconfig -a'), ('address', 'ip addr'),
            ('key', 'for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done'),
            ('git', 'git config --global user.name; git config --global user.email'), ('process', 'ps -A -o comm='))
SCRIPT = ''.join(f'({command}) </dev/null 2>/dev/null | awk -v kind={kind} \'{{print kind "\\t" $0}}\'\n'
                 for kind, command in COMMANDS)


def probe(command):
    """What a machine answers: kind -> values in the order met; else why it could not be asked."""
    try:
        result = subprocess.run(command, input=SCRIPT, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {}, str(error)
    facts = {}
    for line in result.stdout.splitlines():
        kind, _, value = line.partition('\t')
        facts.setdefault(kind, []).append(value.strip())
    return facts, None if facts else result.stderr.strip() or f'exit {result.returncode}'


def parts(value, separators):
    """A value and its parts: a path's components, a host name's labels, a name's words."""
    return [value] + re.split(separators, value)


def keys(lines):
    """Fingerprints and comments of `ssh-keygen -l` lines (comments often name an account and host)."""
    return [value for line in lines for key in re.findall(r'^\d+ (\S+) (.*) \(\w+\)$', line) for value in key]


def groups(facts):
    """A machine's facts as (title, values) groups: needle candidates, then context (printed as comments)."""
    names = facts.get('name', []) + [line.split(':')[4].split(',')[0] for line in facts.get('passwd', []) if line.count(':') == 6]
    hardware = '\n'.join(facts.get('hardware', []))
    ids = facts.get('id', []) + re.findall(
        r'(?:"IOPlatform(?:UUID|SerialNumber)" = "|(?:Serial Number \(system\)|Hardware UUID|Provisioning UDID): )([^"\s]+)', hardware)
    addresses = re.findall(r'\b(?:inet6?|ether|link/ether) (?:addr:)?([0-9a-fA-F:.]+)', '\n'.join(facts.get('address', [])))
    return [('account: name, full name and its words', facts.get('account', []) + [part for name in names for part in parts(name, r'\s+')]),
            ('host names and their parts', [part for host in facts.get('host', []) for part in parts(host, r'[.-]')]),
            ('home and temporary directories and their parts',
             [part for path in facts.get('home', []) + facts.get('temporary', []) for part in parts(path.rstrip('/'), '/')]),
            ('machine, boot and hardware ids', ids + [value.lower() for value in ids]),
            ('network addresses (capture replace --ips replaces every IPv4 one)', addresses),
            ('SSH host keys: fingerprints and comments', keys(facts.get('key', []))),
            ('git identity', facts.get('git', []))], \
        [('processes', facts.get('process', []))]


def emit(where, candidates, context, seen):
    """Prints each value once in the whole output, under the first group that has it. Loopback names no machine."""
    for title, values in candidates:
        fresh = [value for value in dict.fromkeys(values) if value and value not in seen and not value.startswith('127.') and value != '::1']
        seen.update(fresh)
        if fresh:
            print(f'# {where}: {title}', *fresh, sep='\n')
    for title, values in context:
        if values:
            print(f'# {where}: {title} (context: copy the private parts as needles)', *['# ' + value for value in dict.fromkeys(values)], sep='\n')


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return result.stdout.splitlines()


def main():
    args = xcode.arguments(__doc__).parse_args()
    print('# test/leak.py ' + shlex.join(sys.argv[1:]))
    seen = set()
    facts, _ = probe(['sh', '-s'])
    candidates, context = groups(facts)
    checkout = [('this checkout and its parts', parts(str(ROOT.resolve()), '/'))]
    run_name = [('capture run name (recorded in paths)', [args.capture or args.replay])] if args.capture or args.replay else []
    agent = [('SSH agent keys: fingerprints and comments', keys(run(['ssh-add', '-l'])))]
    emit('local', candidates + checkout + run_name + agent, context, seen)
    # The SSH tests' hosts (DispatchTests SSHLinuxTestProfile.url): the checkout's profiles, else the test VM's.
    for name in ('linux-ssh.json', 'host-linux-ssh.json'):
        path = ROOT / 'build' / name if (ROOT / 'build' / name).exists() else Path('/Users/admin/dispatch-tests') / name
        if not path.exists():
            continue
        profile = json.loads(path.read_text())
        destination, options = profile['destination'], profile.get('options', [])
        where = f'{destination} ({path.name})'
        # ssh -G resolves the options and ssh_config without connecting: the account, address and key files ssh uses.
        config = {}
        for line in run(['ssh', '-G', *options, destination]):
            key, _, value = line.partition(' ')
            config.setdefault(key, []).append(value)
        files = [os.path.expanduser(file) for file in config.get('identityfile', []) + config.get('certificatefile', [])]
        ssh = parts(destination, '@') + [value for key in ('user', 'hostname', 'hostkeyalias', 'proxyjump') for value in config.get(key, [])]
        emit(where, [('destination, resolved user and host', ssh),
                     ('key and known hosts files', files + [file for value in config.get('userknownhostsfile', []) for file in value.split()]),
                     ('key fingerprints and comments', keys([line for file in files if Path(file + '.pub').exists()
                                                             for line in run(['ssh-keygen', '-lf', file + '.pub'])]))], [], seen)
        facts, error = probe(['ssh', *options, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', destination, 'sh -s'])
        if error:
            print(f'# {where}: NOT REACHED, its account, host names, ids and addresses are missing here: {error}')
        emit(where, *groups(facts), seen)
    return 0


if __name__ == '__main__':
    sys.exit(main())
