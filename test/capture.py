#!/usr/bin/env python3
"""Collect a host's helper captures into a test's staging directory (acknowledged, never deleted at the source).
This script knows files, not the capture format: the Rust capture tool reads captures (store, prune, check)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()


def write(path, value):
    temporary = path.with_suffix('.pending')
    with temporary.open('w') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


# An acknowledgement avoids downloading unchanged bytes; the writer's source is never removed.
REMOTE = r'''
import fcntl,hashlib,json,os,platform,sys,tarfile,time
from pathlib import Path
root=Path(sys.argv[1]).expanduser()
receipt=root/'.acknowledged.json'
acknowledged=json.loads(receipt.read_text()) if receipt.exists() else {}
def digest(p):
 with p.open('rb') as f:
  h=hashlib.sha256()
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
  return h.hexdigest()
def writing(p):
 with p.open('rb') as f:
  try:fcntl.flock(f,fcntl.LOCK_SH|fcntl.LOCK_NB);return False
  except BlockingIOError:return True
if sys.argv[2]=='export':
 # A helper still writing holds its capture locked; its test just closed its connection, so it ends within
 # seconds. One still running after that is copied as it is (a cut snapshot).
 deadline=time.monotonic()+10
 for p in sorted(root.glob('*.rpl.bz2')):
  while p.is_file() and not p.is_symlink() and writing(p) and time.monotonic()<deadline:time.sleep(0.05)
 files=[p for p in sorted(root.glob('*.rpl.bz2')) if p.is_file() and not p.is_symlink()]
 hashes={p.name:digest(p) for p in files}
 files=[p for p in files if acknowledged.get(p.name)!=hashes[p.name]]
 manifest={'platform':{'Darwin':'macos','Linux':'linux'}.get(platform.system(),platform.system().lower()),'files':{p.name:hashes[p.name] for p in files}}
 import io
 data=json.dumps(manifest).encode()
 with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as archive:
  entry=tarfile.TarInfo('collection.json');entry.size=len(data)
  archive.addfile(entry,io.BytesIO(data))
  for p in files:archive.add(p,arcname=p.name,recursive=False)
else:
 expected=json.loads(sys.argv[3]);changed=[]
 for name,sha in expected.items():
  p=root/name
  if p.parent!=root or p.is_symlink():raise ValueError('invalid acknowledgement')
  if p.exists():
   if digest(p)==sha:acknowledged[name]=sha
   else:changed.append(name)
 if root.exists():
  temporary=receipt.with_suffix('.pending')
  temporary.write_text(json.dumps(acknowledged));temporary.replace(receipt)
 print(json.dumps({'changed':changed}))
'''


def collect(command, directory, target):
    """command is an SSH argv ending with destination, or ['/bin/sh','-c'] locally."""
    target = Path(target)
    target.mkdir(parents=True, exist_ok=True)
    receipt = target/'collection.json'
    previous = json.loads(receipt.read_text()) if receipt.exists() else {'files':{},'errors':[]}
    try:
        with tempfile.TemporaryDirectory(prefix='.collect-', dir=target) as temporary:
            stage = Path(temporary)
            archive = stage/'capture.tar'
            with archive.open('wb') as output:
                subprocess.run([*command,shlex.join(['python3','-c',REMOTE,directory,'export'])],
                               stdout=output,check=True,timeout=60)
            with tarfile.open(archive) as bundle:
                members=bundle.getmembers()
                if any(not m.isfile() or Path(m.name).name!=m.name for m in members):
                    raise ValueError('Capture archive contains a non-file or nested path')
                if len({m.name for m in members})!=len(members): raise ValueError('Duplicate capture names')
                manifest=json.load(bundle.extractfile('collection.json'))
                expected=manifest['files']
                if {m.name for m in members}!=set(expected)|{'collection.json'}:
                    raise ValueError('Capture archive does not match collection manifest')
                for name,sha in expected.items():
                    path=stage/name
                    with bundle.extractfile(name) as source,path.open('xb') as output:
                        shutil.copyfileobj(source,output)
                        output.flush();os.fsync(output.fileno())
                    if digest(path)!=sha: raise ValueError('Capture checksum mismatch: '+name)
                    destination=target/sha/name
                    if destination.exists() and digest(destination)!=sha:
                        raise ValueError('Refusing to overwrite capture: '+str(destination))
            published={str(Path(sha)/name):sha for name,sha in expected.items()}
            for name,sha in expected.items():
                destination=target/sha/name
                destination.parent.mkdir(exist_ok=True)
                if not destination.exists(): (stage/name).replace(destination)
            previous['files'].update(published)
            previous['platform']=manifest['platform']
            write(receipt,previous)
            descriptor=os.open(target,os.O_RDONLY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
            reply=subprocess.run([*command,shlex.join(['python3','-c',REMOTE,directory,'ack',json.dumps(expected)])],
                                 stdout=subprocess.PIPE,text=True,check=True,timeout=60)
            if json.loads(reply.stdout)['changed']:
                raise ValueError('Remote captures changed during collection; newer sources retained')
        return list(published)
    except (OSError,ValueError,KeyError,tarfile.TarError,subprocess.SubprocessError) as error:
        previous.setdefault('errors',[]).append({'kind':type(error).__name__,
                                               'returncode':getattr(error,'returncode',None)})
        write(receipt,previous)
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='mode',required=True)
    transfer=sub.add_parser('collect')
    transfer.add_argument('--directory',required=True)
    transfer.add_argument('--target',type=Path,required=True)
    transfer.add_argument('--dry-run',action='store_true')
    transfer.add_argument('command',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    if args.dry_run:
        print(json.dumps(vars(args),default=str));return
    command=args.command[1:] if args.command[:1]==['--'] else args.command
    collect(command,args.directory,args.target)


if __name__=='__main__':main()
