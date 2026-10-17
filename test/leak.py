#!/usr/bin/env python3
"""What a test run with these arguments (test/run.sh's) may record about the machines it touches: this Mac and every
SSH test host of the checkout's profiles. Prints a needles file draft (docs/capture_scrub.md): `#` lines say where the
values below them come from; process lists are context, as comments. Keep the private values, delete the public ones,
then search the captures for them (capture grep --needles). The output holds private values: keep it out of anything
shared. Environments are not printed (they can hold credentials): the helper records its own at startup, and capture
grep lists every capture's: read them there. With --captures, also the login banners' times those captures show: run it
after the recording then (the run's own logins make most of them)."""
import bz2
import contextlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import zoneinfo

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
            ('git', 'git config --global user.name; git config --global user.email'), ('process', 'ps -A -o comm='),
            ('timezone', 'readlink /etc/localtime'), ('timezone', 'cat /etc/timezone'), ('timezone', 'echo "$TZ"'),
            ('timezone', 'date +"%Z %z"'),
            # Shell startup files linked into a dotfiles repository: test shells source them, and they print paths of it.
            ('startup', 'cd && for f in .zshenv .zprofile .zshrc .zlogin .zlogout .bash_profile .bash_login .bashrc .profile; do '
                        '[ -L "$f" ] && t=$(readlink -f "$f") && echo "$t" && d=$(dirname "$t") && '
                        'while [ "$d" != / ] && [ ! -e "$d/.git" ]; do d=$(dirname "$d"); done && [ "$d" != / ] && echo "$d"; done'))
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


# The local zone database's names (Debian's also holds `localtime`, a link to /etc/localtime: not a zone), and the value
# picked for each zone name met.
ZONES, PICKED = zoneinfo.available_timezones() - {'localtime'}, {}
# UTC under its names, its abbreviation and offset: what the runner hands every test (and a test VM may run in), so no
# machine's place; replaced, it would change every recording's public time zone.
UNIVERSAL = {'UTC', 'GMT', 'UCT', 'Zulu', 'Universal', 'GMT0', 'Greenwich', 'Etc', '+0000', 'UTC +0000', 'GMT +0000'} | \
    {'Etc/' + name for name in ('UTC', 'GMT', 'UCT', 'Zulu', 'Universal', 'GMT0', 'GMT+0', 'GMT-0', 'Greenwich')}


def zone(name):
    """A time zone name's group: `name<TAB>value`, a real zone of the same byte length picked at random (secrets: no
    seed, another pick each run) once per name. Masked, a zone name is easy to guess back (few zones have its shape); a
    value of its length hides it only among the zones of that length: the title counts them, and with no other one
    nothing can hide it (stops). A value is never a zone name or value met before (capture replace refuses those): when
    every other one is, the name stays without a value (masked)."""
    same = [other for other in ZONES if len(other.encode()) == len(name.encode())]
    if len(same) < 2:
        raise SystemExit(f'time zone {name}: no other zone in the local database has its byte length, so a replacement '
                         'cannot hide it: handle it by hand (capture again with another TZ)')
    if name not in PICKED:
        free = sorted(set(same) - {name, *PICKED, *PICKED.values()})
        PICKED[name] = secrets.choice(free) if free else None
    used = '' if PICKED[name] else ', every other one used here: masked instead'
    few = '; warning: fewer than 10, a value of this length hides little' if len(same) < 10 else ''
    return (f'time zone name, a real zone of its byte length picked at random as its value (zones of that length: {len(same)}{used}{few})',
            [f'{name}\t{PICKED[name]}' if PICKED[name] else name])


def groups(facts):
    """A machine's facts as (title, values) groups: needle candidates, then context (printed as comments)."""
    names = facts.get('name', []) + [line.split(':')[4].split(',')[0] for line in facts.get('passwd', []) if line.count(':') == 6]
    hardware = '\n'.join(facts.get('hardware', []))
    ids = facts.get('id', []) + re.findall(
        r'(?:"IOPlatform(?:UUID|SerialNumber)" = "|(?:Serial Number \(system\)|Hardware UUID|Provisioning UDID): )([^"\s]+)', hardware)
    addresses = re.findall(r'\b(?:inet6?|ether|link/ether) (?:addr:)?([0-9a-fA-F:.]+)', '\n'.join(facts.get('address', [])))
    zones = [part for value in facts.get('timezone', []) for part in parts(re.sub(r'^.*zoneinfo/', '', value), r'[/ ]')
             if part not in UNIVERSAL]
    hosts = facts.get('host', [])
    return [('account: name, full name and its words', facts.get('account', []) + [part for name in names for part in parts(name, r'\s+')]),
            ('host names and their parts', [part for host in hosts for part in parts(host, r'[.-]')]),
            # A prompt shows account@host, often the host's first label only: a label alone is too short a needle, and a
            # terminal that redraws only changed cells can cut the full name.
            ('shell prompts: account@host as a prompt shows it',
             [f'{account}@{host}' for account in facts.get('account', []) for host in dict.fromkeys([h.split('.')[0] for h in hosts] + hosts)]),
            ('shell startup files linked elsewhere and their repositories', facts.get('startup', [])),
            ('home and temporary directories and their parts',
             [part for path in facts.get('home', []) + facts.get('temporary', []) for part in parts(path.rstrip('/'), '/')]),
            ('machine, boot and hardware ids', ids + [value.lower() for value in ids]),
            ('network addresses (capture replace --ips replaces every IPv4 one)', addresses),
            ('SSH host keys: fingerprints and comments', keys(facts.get('key', []))),
            ('git identity', facts.get('git', [])),
            # Agents write the zone into what they send (Codex: <timezone>Area/City</timezone>).
            *[zone(part) for part in zones if part in ZONES],
            ('time zone: name parts, abbreviation and offset', [part for part in zones if part not in ZONES])], \
        [('processes', facts.get('process', []))]


# login(1)'s banner: "Last login: Fri Oct 16 14:44:47 on ttys007", the account's previous login to the second (sshd's
# adds the year and where from). The time is the needle; its line, tty and host vary.
BANNER = re.compile(rb'Last login: ((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ \d]\d '
                    rb'\d\d:\d\d:\d\d)')


@contextlib.contextmanager
def expanded(path):
    """A capture's bytes as a stream: bzip2 as recorded, zstd in the corpus (through the zstd tool)."""
    if path.suffix != '.zst':
        with (bz2.open if path.suffix == '.bz2' else open)(path, 'rb') as stream:
            yield stream
        return
    with subprocess.Popen(['zstd', '-dcq', '--long=27', str(path)], stdout=subprocess.PIPE) as process:
        yield process.stdout
        process.stdout.read()
    if process.returncode:
        raise OSError(f'{path}: zstd exited {process.returncode}')


def banners(directories):
    """The login times the captures under `directories` show, each with a value of its shape on 1 January 1970: all one
    day, in random order (secrets), never a time met (capture replace refuses a value equal to a needle or another value).
    A capture is read in pieces, the end of each kept for a banner the next one completes."""
    times = set()
    for directory in directories:
        for path in sorted(Path(directory).rglob('*.rpl*')):
            with expanded(path) as stream:
                tail = b''
                while chunk := stream.read(1 << 24):
                    data = tail + chunk
                    times.update(time.decode() for time in BANNER.findall(data))
                    tail = data[-64:]
    values = [value for second in range(2 * len(times) + 1)
              for value in [f'Thu Jan  1 {second // 3600:02d}:{second // 60 % 60:02d}:{second % 60:02d}'] if value not in times]
    secrets.SystemRandom().shuffle(values)
    return [f'{time}\t{value}' for time, value in zip(sorted(times), values)]


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
    parser = xcode.arguments(__doc__)
    parser.add_argument('--captures', action='append', type=Path, default=[], metavar='DIR',
                        help='Also list the login banner times the captures under DIR show (repeatable)')
    args = parser.parse_args()
    print('# test/leak.py ' + shlex.join(sys.argv[1:]))
    seen = set()
    facts, _ = probe(['sh', '-s'])
    candidates, context = groups(facts)
    checkout = [('this checkout and its parts', parts(str(ROOT.resolve()), '/'))]
    run_name = [('capture run name (recorded in paths)', [args.capture or args.replay])] if args.capture or args.replay else []
    agent = [('SSH agent keys: fingerprints and comments', keys(run(['ssh-add', '-l'])))]
    # The login session's agent socket (/var/run/com.apple.launchd.<random>/Listeners; /private/tmp on older macOS), what
    # an app launchd starts (Xcode's test host) inherits as SSH_AUTH_SOCK even when a shell points it elsewhere (a gpg
    # agent): the app drops it while testing, earlier captures keep it. Its placeholder is the same length of X.
    sockets = [str(path) for folder in ('/private/var/run', '/private/tmp') for path in Path(folder).glob('com.apple.launchd.*/Listeners')
               if path.lstat().st_uid == os.getuid()]
    socket = list(dict.fromkeys(re.findall(r'com\.apple\.launchd\.([A-Za-z0-9]+)', ' '.join([os.environ.get('SSH_AUTH_SOCK', '')] + sockets))))
    agent.append(('SSH agent socket: launchd\'s per-session folder name', [f'{name}\t{"X" * len(name)}' for name in socket]))
    banner = [('"Last login" banner times in ' + ', '.join(map(str, args.captures)), banners(args.captures))] if args.captures else []
    emit('local', candidates + checkout + run_name + agent + banner, context, seen)
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
