#!/usr/bin/env python3
"""Preserve and index native test captures; acknowledge verified snapshots without deleting sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
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
import hashlib,json,os,platform,sys,tarfile
from pathlib import Path
root=Path(sys.argv[1]).expanduser()
receipt=root/'.acknowledged.json'
acknowledged=json.loads(receipt.read_text()) if receipt.exists() else {}
def digest(p):
 with p.open('rb') as f:
  h=hashlib.sha256()
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
  return h.hexdigest()
if sys.argv[2]=='export':
 files=[p for p in sorted(root.glob('*.jsonl')) if p.is_file() and not p.is_symlink()]
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


def begin(root, run, helpers):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', run):
        raise ValueError('Run must be a single directory name')
    root = Path(root).resolve()
    directory = root / 'build' / 'captures' / run
    directory.mkdir(parents=True, exist_ok=False)
    for name in ('raw','app','helpers'): (directory/name).mkdir()
    source = {'commit': None, 'diff_sha256': None}
    if (root/'.git').exists():
        source = {'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
                  'diff_sha256':hashlib.sha256(subprocess.check_output(['git','diff','HEAD','--binary'],cwd=root)).hexdigest()}
    saved = []
    for helper in helpers:
        path = Path(helper['path']).resolve()
        sha = digest(path)
        output = directory/'helpers'/sha
        if not output.exists(): shutil.copy2(path, output)
        saved.append({**helper,'path':str(output.relative_to(directory)), 'sha256':sha,
                      'image':helper.get('image',str(path))})
    write(directory/'manifest.json', {'version':1,'run':run,'source':source,'helpers':saved,
          'captures':[],'app':[],'outcomes':[],'collection_errors':[]})
    return directory


def index(directory, outcomes=(), bindings=None):
    directory = Path(directory)
    manifest = json.loads((directory/'manifest.json').read_text())
    attributed = {r['path']:r for r in manifest['captures'] if r.get('binding_proof')}
    attributed.update(bindings or {})
    manifest['outcomes'] = list(outcomes) or manifest['outcomes']
    results = {}
    for row in manifest['outcomes']:
        case = row['identifier'].removeprefix('DispatchTests/').replace('/','.')
        results.setdefault(case,[]).append(row['outcome'])
    events = directory/'raw/cases.jsonl'
    completed = {}
    journals = {}
    if events.exists():
        for line in events.read_text().splitlines():
            event = json.loads(line)
            if event.get('event') != 'end' or not event.get('outcome'): continue
            case = event['case'].removeprefix('DispatchTests/').replace('/','.')
            completed.setdefault(case,[]).append(event['outcome'])
            if event.get('journal'):
                parts = Path(event['journal']).parts
                if 'app' in parts:
                    journals[str(Path(*parts[parts.index('app'):]))] = event['outcome']
    # Case receipts count actual invocations; a single exported summary must not
    # overwrite several distinct captured invocations with one guessed outcome.
    results.update(completed)
    ambiguous = {case:values for case,values in results.items()
                 if len(values)>1 and not all(str(value).lower()=='passed' for value in values)}
    results = {case:values[0] if case not in ambiguous else None for case,values in results.items()}
    entries = []
    errors = []
    for receipt in sorted((directory/'raw').rglob('collection.json')):
        relative=receipt.relative_to(directory/'raw')
        data=json.loads(receipt.read_text())
        missing = [{'kind':'MissingCapture','path':name} for name in data.get('files',{})
                   if not (receipt.parent/name).is_file()]
        if data.get('errors') or missing:
            errors.append({'case':relative.parts[1] if relative.parts[0]=='remote' else None,
                           'path':str(receipt.relative_to(directory)),'errors':data.get('errors',[])+missing})
    for path in sorted((directory/'raw').rglob('*.jsonl')):
        if path.name == 'cases.jsonl': continue
        relative = path.relative_to(directory/'raw')
        match = re.fullmatch(r'(.+)-(\d+)-(\d+)\.jsonl', path.name)
        case = relative.parts[1] if relative.parts[0]=='remote' and len(relative.parts)>2 else match[1] if match else None
        if case == 'helper': case = None
        image = None
        sha = None
        metadata_error = None
        metadata_failure = None
        try:
            with path.open() as stream:
                for line in stream:
                    row = json.loads(line)
                    if row.get('section') != 'startup': break
                    if row.get('op') in ('image','image.sha256') and row.get('data'):
                        output = json.loads(bytes.fromhex(row['data']))['output']
                        if output.get('kind') == 'error':
                            metadata_error = 'CapturedMetadataError'
                            metadata_failure = {'op':row['op'],'output':output}
                            continue
                        value = bytes.fromhex(output['bytes'])
                        if row['op']=='image': image = value.decode()
                        else:
                            if len(value) != 32: raise ValueError('Invalid executable digest')
                            sha = value.hex()
        except (ValueError, KeyError) as error:
            metadata_error = type(error).__name__
        receipt = next((parent/'collection.json' for parent in path.parents
                        if parent.is_relative_to(directory/'raw') and (parent/'collection.json').exists()),None)
        collection=json.loads(receipt.read_text()) if receipt else None
        if collection and collection['files'].get(str(path.relative_to(receipt.parent))) != digest(path):
            metadata_error='CollectionChecksumMismatch'
        system = collection.get('platform') if collection else (
            manifest.get('platform') if relative.parts[0]!='remote' else None)
        helpers = [h for h in manifest['helpers'] if
                   (h['sha256']==sha if sha else image is not None and h['image']==image)
                   and (not system or h['platform']==system)] if not metadata_error else []
        identities = {h['sha256'] for h in helpers}
        helper = helpers[0] if len(identities)==1 else None
        if helper and digest(directory/helper['path']) != helper['sha256']:
            raise ValueError('Preserved helper checksum differs')
        entry = {'case':case,'path':str(path.relative_to(directory)),'sha256':digest(path),
                        'lifetime':path.stem,'platform':system or (helper and helper['platform']),
                        'image':image,'helper_sha256':helper['sha256'] if helper else None,
                        'outcome':results.get(case)}
        if metadata_error: entry['metadata_error'] = metadata_error
        if metadata_failure: entry['metadata_failure'] = metadata_failure
        if entry['path'] in attributed:
            binding = attributed[entry['path']]
            if binding['sha256'] != entry['sha256']:
                raise ValueError('Binding proof names different capture bytes: ' + entry['path'])
            if not any(h['sha256']==binding['helper_sha256'] for h in manifest['helpers']):
                raise ValueError('Binding helper was not preserved in this run')
            if digest(directory/'helpers'/binding['helper_sha256']) != binding['helper_sha256']:
                raise ValueError('Preserved helper checksum differs')
            proof = binding['binding_proof']
            source = directory/Path(proof['path'])
            if digest(source) != proof['sha256']:
                raise ValueError('Binding proof checksum differs')
            destination = directory/'proofs'/proof['sha256']
            destination.parent.mkdir(exist_ok=True)
            if destination.exists():
                if digest(destination) != proof['sha256']: raise ValueError('Preserved binding proof checksum differs')
            else: shutil.copyfile(source,destination)
            for field in ('platform','image','helper_sha256'):
                if entry[field] is not None and entry[field] != binding[field]:
                    raise ValueError('Binding conflicts with captured ' + field)
                entry[field] = binding[field]
            entry['binding_proof'] = {'path':str(destination.relative_to(directory)), 'sha256':proof['sha256']}
        entries.append(entry)
    if set(attributed)-{r['path'] for r in entries}:
        raise ValueError('Binding proof names an absent capture')
    errors += [{'case':case,'outcomes':values,'captures':[entry['path'] for entry in entries if entry['case']==case],
                'errors':[{'kind':'AmbiguousInvocationOutcome'}]}
               for case,values in ambiguous.items() if any(str(value).lower()=='passed' for value in values)
               and any(entry['case']==case for entry in entries)]
    manifest['captures'] = entries
    errors += [{'case':entry['case'],'path':entry['path'],'errors':[{'kind':entry['metadata_error'],**entry.get('metadata_failure',{})}]} for entry in entries if entry.get('metadata_error')]
    manifest['collection_errors'] = errors
    manifest['app'] = [{'case':p.parent.name if p.parent != directory/'app' else p.stem,
                        'variant':p.stem,'path':str(p.relative_to(directory)),'sha256':digest(p)}
                       for p in sorted((directory/'app').rglob('*.jsonl'))]
    for entry in manifest['app']:
        entry['outcome'] = journals.get(entry['path'],results.get(entry['case']))
    write(directory/'manifest.json',manifest)
    return manifest


def retain(source, target, dry_run=False):
    """Promote every explicitly passed variant; keep the complete source untouched."""
    source, target = Path(source).resolve(), Path(target).absolute()
    if target.exists() or target.is_symlink(): raise FileExistsError(target)
    if target.resolve().is_relative_to(source): raise ValueError('Retention target is inside source')
    original = source/'manifest.json'
    contents = original.read_bytes()
    manifest = json.loads(contents)
    manifest_sha = hashlib.sha256(contents).hexdigest()
    passed = lambda value: isinstance(value,str) and value.lower() == 'passed'
    selected = {kind:[entry for entry in manifest.get(kind,[]) if passed(entry.get('outcome'))]
                for kind in ('captures','app')}
    excluded = {kind:len(manifest.get(kind,[]))-len(entries) for kind,entries in selected.items()}
    cases = {entry['case'] for entries in selected.values() for entry in entries}
    hashes = {entry.get('helper_sha256') for entry in selected['captures']}
    helpers = [entry for entry in manifest.get('helpers',[]) if entry['sha256'] in hashes]
    errors = [entry for entry in manifest.get('collection_errors',[])
              if entry.get('case') is None or entry['case'] in cases
              or any(passed(value) for value in entry.get('outcomes',[]))]
    outcomes = [entry for entry in manifest.get('outcomes',[])
                if passed(entry.get('outcome')) and
                entry['identifier'].removeprefix('DispatchTests/').replace('/','.') in cases]
    files = {}
    records = selected['captures']+selected['app']+helpers
    records += [entry['binding_proof'] for entry in selected['captures'] if entry.get('binding_proof')]
    records += [entry for entry in errors if entry.get('path')]
    for entry in records:
        relative = Path(entry['path'])
        if relative.is_absolute() or '..' in relative.parts or relative == Path('manifest.json'):
            raise ValueError('Invalid retained path: '+str(relative))
        path = source/relative
        if any(parent.is_symlink() for parent in [path,*path.parents] if parent != source and parent.is_relative_to(source)):
            raise ValueError('Retained path is a symlink: '+str(relative))
        if not path.is_file(): raise ValueError('Retained file is missing: '+str(relative))
        sha = digest(path)
        if entry.get('sha256',sha) != sha: raise ValueError('Retained checksum differs: '+str(relative))
        if str(relative) in files and files[str(relative)] != sha:
            raise ValueError('Conflicting retained path: '+str(relative))
        files[str(relative)] = sha
    plan = {'source':str(source),'target':str(target),'excluded':excluded,
            'retained':{kind:len(entries) for kind,entries in selected.items()},
            'files':[{'path':path,'sha256':sha} for path,sha in sorted(files.items())]}
    if dry_run or not (cases or errors): return plan
    retained = {**manifest,**selected,'helpers':helpers,'outcomes':outcomes,'collection_errors':errors,
                'retention':{'source_manifest_sha256':manifest_sha,'excluded':excluded}}
    target.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.retain-',dir=target.parent) as temporary:
        stage = Path(temporary)/'run'
        stage.mkdir()
        for relative,sha in files.items():
            destination = stage/relative
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source/relative,destination)
            if digest(destination) != sha: raise ValueError('Source changed during retention: '+relative)
        if digest(original) != retained['retention']['source_manifest_sha256']:
            raise ValueError('Source manifest changed during retention')
        write(stage/'manifest.json',retained)
        if target.exists() or target.is_symlink(): raise FileExistsError(target)
        stage.rename(target)
    return plan


def replay_rounds(directory):
    """Keep all recorded case invocations; each round runs at most one variant of each case."""
    directory = Path(directory)
    manifests = [directory/'manifest.json'] if (directory/'manifest.json').is_file() else sorted(directory.rglob('manifest.json'))
    cases = {}
    for path in manifests:
        manifest = json.loads(path.read_text())
        for entry in manifest.get('app',[]):
            journal = (path.parent/entry['path']).resolve()
            if not journal.is_relative_to(path.parent.resolve()): raise ValueError('App journal leaves capture run')
            if digest(journal) != entry['sha256']: raise ValueError('App journal checksum differs: '+str(journal))
            case = 'DispatchTests/'+entry['case'].replace('.','/',1)
            cases.setdefault(case,[]).append(str(journal))
    if not cases: raise ValueError('No app journals in corpus; native-only historical captures cannot replay app state')
    return [{case:paths[i] for case,paths in cases.items() if i<len(paths)}
            for i in range(max(map(len,cases.values())))]


def import_run(source, directory, outcomes=(), bindings=None):
    """Copy real historical bytes, never synthesize missing context or outcomes."""
    source, directory = Path(source), Path(directory)
    if any((directory/'raw').iterdir()):
        raise FileExistsError('Import requires an empty new run; existing versions are immutable')
    shutil.copytree(source, directory/'raw', dirs_exist_ok=True)
    return index(directory,outcomes,bindings)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='mode',required=True)
    transfer=sub.add_parser('collect')
    transfer.add_argument('--directory',required=True)
    transfer.add_argument('--target',type=Path,required=True)
    transfer.add_argument('--dry-run',action='store_true')
    transfer.add_argument('command',nargs=argparse.REMAINDER)
    ingest=sub.add_parser('import')
    ingest.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    ingest.add_argument('--run',required=True)
    ingest.add_argument('--source',type=Path,required=True)
    ingest.add_argument('--helper',action='append',default=[],help='PLATFORM=PATH; original binary only')
    ingest.add_argument('--helpers',type=Path,help='JSON array of original {platform,path,image} mappings')
    ingest.add_argument('--source-commit',help='Original capturing source commit, not the importing checkout')
    ingest.add_argument('--source-diff-sha256',help='Original capturing source diff hash when recorded')
    ingest.add_argument('--platform',choices=['macos','linux'])
    ingest.add_argument('--outcomes',type=Path)
    ingest.add_argument('--bindings',type=Path,help='Verified original bindings keyed by raw capture path; each includes sha256 and binding_proof')
    ingest.add_argument('--dry-run',action='store_true')
    promotion=sub.add_parser('retain')
    promotion.add_argument('--source',type=Path,required=True)
    promotion.add_argument('--target',type=Path,required=True)
    promotion.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    if args.mode=='retain':
        print(json.dumps(retain(args.source,args.target,args.dry_run),indent=2));return
    if args.dry_run:
        print(json.dumps(vars(args),default=str));return
    if args.mode=='collect':
        command=args.command[1:] if args.command[:1]==['--'] else args.command
        collect(command,args.directory,args.target)
    else:
        helpers=[dict(zip(['platform','path'],value.split('=',1))) for value in args.helper]
        if args.helpers: helpers += json.loads(args.helpers.read_text())
        run=begin(args.root,args.run,helpers)
        manifest=json.loads((run/'manifest.json').read_text());manifest['platform']=args.platform
        manifest['importer'] = manifest['source']
        manifest['source'] = {'commit':args.source_commit,'diff_sha256':args.source_diff_sha256}
        write(run/'manifest.json',manifest)
        import_run(args.source,run,json.loads(args.outcomes.read_text()) if args.outcomes else (),
                   json.loads(args.bindings.read_text()) if args.bindings else None)


if __name__=='__main__':main()
