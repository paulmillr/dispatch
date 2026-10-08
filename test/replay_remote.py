"""Run the native replay worker over an existing authenticated SSH profile."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import tarfile
import uuid
from capture import digest, write


REMOTE = r'''
import hashlib,io,json,os,shutil,subprocess,sys,tarfile
from pathlib import Path, PurePosixPath
os.umask(0o077)
parent=Path.home()/'.dispatch-replay'
parent.mkdir(mode=0o700,exist_ok=True)
if parent.is_symlink() or parent.stat().st_uid!=os.getuid() or parent.stat().st_mode & 0o077:raise ValueError('unsafe replay directory')
root=parent/sys.argv[1];root.mkdir(mode=0o700)
def digest(path):
 with path.open('rb') as f:
  h=hashlib.sha256()
  for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
  return h.hexdigest()
with tarfile.open(fileobj=sys.stdin.buffer,mode='r|*') as archive:
 names=set()
 for member in archive:
  p=PurePosixPath(member.name)
  if not member.isfile() or p.is_absolute() or '..' in p.parts or member.name in names:raise ValueError('unsafe upload member')
  names.add(member.name);path=root/member.name;path.parent.mkdir(parents=True,exist_ok=True)
  with archive.extractfile(member) as source,path.open('xb') as output:shutil.copyfileobj(source,output)
inputs=json.loads((root/'transfer.json').read_text())
if names!=set(inputs['files'])|{'transfer.json'}:raise ValueError('upload manifest differs')
for name,sha in inputs['files'].items():
 if digest(root/name)!=sha:raise ValueError('upload checksum differs: '+name)
for name in ('original','helper','tool'): (root/name).chmod(0o700)
original=root/'original'
image=inputs['image']
if image and Path(image).is_file() and digest(Path(image))==inputs['files']['original']:original=Path(image)
command=[sys.executable,str(root/'worker.py'),'--captures',str(root/'captures'),'--list',str(root/'list.json'),'--original',str(original),'--helper',str(root/'helper'),'--tool',str(root/'tool'),'--output',str(root/'results')]
for name,value in inputs['limits'].items():command+=['--'+name,str(value)]
if image:command+=['--image',image]
with (root/'worker.log').open('wb') as log:
 result=subprocess.run(command,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
results=root/'results';results.mkdir(exist_ok=True)
shutil.copyfile(root/'worker.log',results/'worker.log')
files={str(p.relative_to(results)):digest(p) for p in sorted(results.rglob('*')) if p.is_file() and not p.is_symlink()}
receipt=json.dumps({'remote_directory':str(root),'exit':result.returncode,'files':files}).encode()
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as archive:
 member=tarfile.TarInfo('receipt.json');member.size=len(receipt);member.mode=0o600
 archive.addfile(member,io.BytesIO(receipt))
 for name in files:archive.add(results/name,arcname=name,recursive=False)
'''


def run(profile, corpus, paths, original, candidate, tool, image, output, limits, dry_run=False):
    corpus, output = Path(corpus).resolve(), Path(output).resolve()
    limits = {'timeout': 8, 'budget': 1800, 'memory': 4096, **limits}
    if set(limits) != {'timeout', 'budget', 'memory'} or any(type(v) is not int or v <= 0 for v in limits.values()):
        raise ValueError('Replay limits must be positive integers')
    if image and not Path(image).is_absolute(): raise ValueError('Replay image must be absolute')
    paths = list(paths)
    if not paths or len(paths) != len(set(paths)): raise ValueError('Capture paths must be nonempty and unique')
    sources = {'original': Path(original), 'helper': Path(candidate), 'tool': Path(tool),
               'worker.py': Path(__file__).with_name('replay_worker.py')}
    for name in paths:
        path = PurePosixPath(name)
        source = corpus / name
        if path.is_absolute() or '..' in path.parts or not source.resolve().is_relative_to(corpus) or not source.is_file():
            raise ValueError('Capture path escapes corpus or is not a file: ' + name)
        sources['captures/' + name] = source
    generation = 'replay-' + uuid.uuid4().hex
    command = ['ssh', *profile.get('options', []), profile['destination'],
               shlex.join(['python3', '-c', REMOTE, generation])]
    plan = {'destination': profile['destination'], 'remote_directory': '~/.dispatch-replay/' + generation,
            'captures': paths, 'image': image, 'output': str(output), 'limits': limits,
            'inputs': {name: str(path.resolve()) for name, path in sources.items() if not name.startswith('captures/')}}
    if dry_run: return plan
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    files = {name: digest(path) for name, path in sources.items()}
    listing = json.dumps(paths).encode();files['list.json'] = hashlib.sha256(listing).hexdigest()
    inputs = {'files': files, 'image': image, 'limits': limits}
    upload = output/'upload.tar.gz'
    with tarfile.open(upload, 'w:gz') as archive:
        for name, source in sources.items():
            info = archive.gettarinfo(str(source), arcname=name)
            info.type = tarfile.REGTYPE;info.linkname = '';info.size = source.stat().st_size;info.mode = 0o600
            with source.open('rb') as stream: archive.addfile(info, stream)
        for name, data in [('list.json', listing), ('transfer.json', json.dumps(inputs).encode())]:
            info = tarfile.TarInfo(name);info.size = len(data);info.mode = 0o600
            archive.addfile(info, io.BytesIO(data))
    upload.chmod(0o600)
    write(output/'transfer.json', plan)
    with upload.open('rb') as source, (output/'download.tar').open('xb') as target, (output/'transport.log').open('xb') as log:
        subprocess.run(command, stdin=source, stdout=target, stderr=log, check=True, timeout=limits['budget'] + 120)
    stage = output/'download';stage.mkdir(mode=0o700)
    with tarfile.open(output/'download.tar') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)) or any(not m.isfile() or PurePosixPath(m.name).is_absolute() or '..' in PurePosixPath(m.name).parts for m in members):
            raise ValueError('Unsafe result archive')
        receipt = json.load(archive.extractfile('receipt.json'))
        if set(names) != set(receipt['files']) | {'receipt.json'}: raise ValueError('Result manifest differs')
        for name, sha in receipt['files'].items():
            path = stage/name;path.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(name) as source, path.open('xb') as target: shutil.copyfileobj(source, target)
            path.chmod(0o600)
            if digest(path) != sha: raise ValueError('Result checksum differs: ' + name)
        for name in receipt['files']:
            destination = output/name
            if destination.exists(): raise ValueError('Refusing to overwrite result: ' + name)
        for name in receipt['files']:
            destination = output/name;destination.parent.mkdir(parents=True, exist_ok=True)
            (stage/name).replace(destination)
    write(output/'receipt.json', receipt)
    rows = json.loads((output/'comparison.json').read_text()) if (output/'comparison.json').exists() else []
    return {**receipt, 'rows': rows, 'success': receipt['exit'] == 0 and len(rows) == len(paths) and {row['capture'] for row in rows} == set(paths),
            'diagnostics': str(output/'worker.log')}
