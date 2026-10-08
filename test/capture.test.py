#!/usr/bin/env python3
"""Collection contracts exercised with an existing, unmodified native capture."""
import importlib.util
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class Collection(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parent.parent
        self.fixture = Path(os.environ.get('DISPATCH_CAPTURE_TEST_SOURCE', root/'test/fixtures/helper-login/capture.jsonl'))
        temporary=Path(os.environ.get('TMPDIR',root/'build/capture-tests'))
        temporary.mkdir(parents=True,exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=temporary)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.source = self.remote / 'helper-17-1.jsonl'
        shutil.copyfile(self.fixture, self.source)
        self.target = self.root / 'download'

    def test_verified_download_acknowledges_but_retains_source(self):
        original = self.source.read_bytes()
        capture.collect(['/bin/sh', '-c'], str(self.remote), self.target)
        self.assertEqual((self.target / capture.digest(self.fixture) / self.source.name).read_bytes(), original)
        self.assertEqual(self.source.read_bytes(),original)
        self.assertEqual(json.loads((self.remote/'.acknowledged.json').read_text()),
                         {self.source.name:capture.digest(self.fixture)})

    def test_conflicting_download_never_acknowledges_source(self):
        self.target.mkdir()
        destination = self.target/capture.digest(self.fixture)/self.source.name
        destination.parent.mkdir()
        destination.write_bytes(b'conflicting destination')
        with self.assertRaises((OSError, ValueError)):
            capture.collect(['/bin/sh', '-c'], str(self.remote), self.target)
        self.assertEqual(self.source.read_bytes(), self.fixture.read_bytes())
        self.assertEqual(destination.read_bytes(), b'conflicting destination')

    def test_failed_transfer_never_deletes_source(self):
        with self.assertRaises(Exception):
            capture.collect(['/bin/false'], str(self.remote), self.target)
        self.assertEqual(self.source.read_bytes(), self.fixture.read_bytes())

    def test_changed_source_survives_acknowledgement(self):
        run = subprocess.run
        def invoke(command, **options):
            result = run(command, **options)
            if command[-1].endswith(' export'):
                with self.source.open('ab') as stream: stream.write(b'\n')
            return result
        with patch.object(capture.subprocess, 'run', invoke), self.assertRaises(ValueError):
            capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual(self.source.read_bytes(),self.fixture.read_bytes()+b'\n')
        self.assertEqual((self.target/capture.digest(self.fixture)/self.source.name).read_bytes(),self.fixture.read_bytes())

    def test_corrupt_download_is_not_acknowledged(self):
        copy = shutil.copyfileobj
        def corrupt(source, output):
            copy(source,output)
            output.write(b'corrupted transport')
        with patch.object(capture.shutil,'copyfileobj',corrupt), self.assertRaises(ValueError):
            capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual(self.source.read_bytes(),self.fixture.read_bytes())

    def test_growing_lifetime_keeps_each_distinct_snapshot(self):
        original=self.fixture.read_bytes()
        prefix=b''.join(original.splitlines(keepends=True)[:10])
        self.source.write_bytes(prefix)
        first=capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.source.write_bytes(original)
        second=capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual([(self.target/p).read_bytes() for p in first+second],[prefix,original])
        self.assertEqual(capture.collect(['/bin/sh','-c'],str(self.remote),self.target),[])
        self.assertEqual(self.source.read_bytes(),original)

    def test_runs_never_overwrite_and_index_preserves_capture_bytes(self):
        run = capture.begin(self.root, 'one', [])
        path = run / 'raw/Example.test-17-1.jsonl'
        shutil.copyfile(self.fixture, path)
        result = capture.index(run, [{'identifier':'DispatchTests/Example/test', 'outcome':'Failed'}])
        self.assertEqual(path.read_bytes(), self.fixture.read_bytes())
        self.assertEqual([(r['case'],r['outcome'],r['sha256']) for r in result['captures']],
                         [('Example.test','Failed',capture.digest(self.fixture))])
        with self.assertRaises(FileExistsError): capture.begin(self.root, 'one', [])

    def test_native_outcomes_use_case_receipts_without_export(self):
        run=capture.begin(self.root,'outcomes',[])
        for case in ['Once.test','Repeated.test']:
            shutil.copyfile(self.fixture,run/'raw'/(case+'-17-1.jsonl'))
        events=[{'case':'DispatchTests/Once/test','event':'end','outcome':'passed'},
                {'case':'DispatchTests/Repeated/test','event':'end','outcome':'failed'},
                {'case':'DispatchTests/Repeated/test','event':'end','outcome':'passed'}]
        (run/'raw/cases.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in events))
        result=capture.index(run)
        self.assertEqual([(row['case'],row['outcome']) for row in result['captures']],
                         [('Once.test','passed'),('Repeated.test',None)])

    @unittest.skipUnless(os.environ.get('DISPATCH_CAPTURE_IDENTITY_SOURCE'), 'native identity integration requires captured executable')
    def test_recorded_digest_matches_snapshot_at_different_install_path(self):
        source=Path(os.environ['DISPATCH_CAPTURE_IDENTITY_SOURCE'])
        image=Path(os.environ['DISPATCH_CAPTURE_IDENTITY_IMAGE'])
        run=capture.begin(self.root,'identity',[{'platform':'linux','path':str(image),'image':'/preserved/resource/helper'}])
        destination=run/'raw/remote/Example.test/host/helper-17-1.jsonl'
        destination.parent.mkdir(parents=True)
        shutil.copyfile(source,destination)
        result=capture.index(run)
        row=result['captures'][0]
        self.assertEqual((row['case'],row['platform'],row['helper_sha256']),
                         ('Example.test','linux',capture.digest(image)))
        self.assertEqual(result['collection_errors'],[])
        self.assertEqual(destination.read_bytes(),source.read_bytes())
        (run/'helpers'/capture.digest(image)).write_bytes(b'changed preserved image')
        with self.assertRaisesRegex(ValueError,'Preserved helper checksum differs'):
            capture.index(run)

    def test_empty_selection_file_cannot_expand_to_full_suite(self):
        source = self.root/'tests.json'
        source.write_text('[]')
        result = subprocess.run([sys.executable,str(Path(__file__).with_name('xcode.py')),
                                 '--tests-from',str(source),'--list'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('non-empty JSON array',result.stderr)

    def test_recorded_image_failure_is_preserved_without_inventing_a_binding(self):
        # full040b helper-76294-1791183109009458000: the executable had been
        # removed, so startup image.sha256 recorded an error, not a byte value.
        failure = {'kind':'error','errno':2,'code':'NotFound',
                   'message':'No such file or directory (os error 2)'}
        run = capture.begin(self.root,'metadata',[])
        path = run/'raw/Example.test-76294-1791183109009458000.jsonl'
        row = {'section':'startup','op':'image.sha256',
               'data':json.dumps({'sequence':0,'output':failure}).encode().hex()}
        path.write_text(json.dumps(row)+'\n')
        result = capture.index(run)
        self.assertEqual(result['captures'],[{
            'case':'Example.test','path':str(path.relative_to(run)),
            'sha256':capture.digest(path),'lifetime':path.stem,'platform':None,
            'image':None,'helper_sha256':None,'outcome':None,
            'metadata_error':'CapturedMetadataError',
            'metadata_failure':{'op':'image.sha256','output':failure}}])
        self.assertEqual(result['collection_errors'],[{
            'case':'Example.test','path':str(path.relative_to(run)),
            'errors':[{'kind':'CapturedMetadataError',
                       'op':'image.sha256','output':failure}]}])

    def test_legacy_remote_identity_is_not_inferred_from_local_platform(self):
        run = capture.begin(self.root,'remote',[])
        manifest = json.loads((run/'manifest.json').read_text())
        manifest['platform'] = 'macos'
        capture.write(run/'manifest.json',manifest)
        path = run/'raw/remote/Example.test/remote-host/helper-17-1.jsonl'
        path.parent.mkdir(parents=True)
        shutil.copyfile(self.fixture,path)
        row = capture.index(run)['captures'][0]
        self.assertEqual((row['case'],row['platform'],row['helper_sha256']),('Example.test',None,None))
        with self.assertRaises(FileExistsError): capture.import_run(self.remote,run)

    def test_replay_plan_retains_each_opaque_variant_across_runs(self):
        expected=[]
        for name in ['older','newer']:
            run=capture.begin(self.root,name,[])
            paths=[]
            for variant in ['first','second']:
                path=run/'app/Example.test'/(variant+'.jsonl')
                path.parent.mkdir(exist_ok=True)
                # Planning treats payload as opaque; use real captured bytes, not invented events.
                shutil.copyfile(self.fixture,path)
                paths.append(str(path))
            capture.index(run)
            expected+=paths
        plan=capture.replay_rounds(self.root/'build/captures')
        self.assertEqual(sorted(row['DispatchTests/Example/test'] for row in plan),sorted(expected))
        self.assertEqual(len(plan),4)

    def test_missing_declared_remote_file_is_coverage_failure(self):
        run=capture.begin(self.root,'missing',[])
        target=run/'raw/remote/Example.test/host';target.mkdir(parents=True)
        receipt=target/'collection.json'
        capture.write(receipt,{'platform':'linux','files':{'absent.jsonl':capture.digest(self.fixture)}})
        result=capture.index(run)
        self.assertEqual(result['collection_errors'],[{'case':'Example.test',
            'path':str(receipt.relative_to(run)),
            'errors':[{'kind':'MissingCapture','path':'absent.jsonl'}]}])

    def test_repeated_native_outcomes_retain_all_passed_and_report_ambiguity(self):
        for name,outcomes in [('passed',['Passed','Passed']),('mixed',['Passed','Failed'])]:
            run=capture.begin(self.root,name,[])
            for lifetime in [1,2]:
                shutil.copyfile(self.fixture,run/f'raw/Example.test-{lifetime}-1.jsonl')
            result=capture.index(run,[{'identifier':'DispatchTests/Example/test','outcome':value} for value in outcomes])
            self.assertEqual([row['outcome'] for row in result['captures']],
                             ['Passed','Passed'] if name=='passed' else [None,None])
            errors=[] if name=='passed' else [{'case':'Example.test','outcomes':outcomes,
                'captures':[row['path'] for row in result['captures']],
                'errors':[{'kind':'AmbiguousInvocationOutcome'}]}]
            self.assertEqual(result['collection_errors'],errors)
            target=self.root/('retained-'+name)
            capture.retain(run,target)
            retained=json.loads((target/'manifest.json').read_text())
            self.assertEqual((len(retained['captures']),retained['collection_errors']),
                             (2,[]) if name=='passed' else (0,errors))

    def test_collection_failure_is_manifest_coverage_failure(self):
        run=capture.begin(self.root,'failed',[])
        target=run/'raw/remote/Example.test/remote-host'
        with self.assertRaises(subprocess.CalledProcessError):
            capture.collect(['/bin/false'],str(self.remote),target)
        result=capture.index(run)
        self.assertEqual(result['collection_errors'],[{
            'case':'Example.test','path':'raw/remote/Example.test/remote-host/collection.json',
            'errors':[{'kind':'CalledProcessError','returncode':1}]}])
        self.assertEqual(self.source.read_bytes(),self.fixture.read_bytes())

    def test_versioned_remote_entries_keep_receipt_platform_and_case(self):
        run=capture.begin(self.root,'versions',[])
        target=run/'raw/remote/Example.test/remote-host'
        expected=[]
        for data in [b''.join(self.fixture.read_bytes().splitlines(keepends=True)[:10]),self.fixture.read_bytes()]:
            self.source.write_bytes(data)
            paths=capture.collect(['/bin/sh','-c'],str(self.remote),target)
            expected += [{'case':'Example.test','path':str((target/p).relative_to(run)),
                          'sha256':capture.digest(self.source),'lifetime':self.source.stem,
                          'platform':{'Darwin':'macos','Linux':'linux'}.get(platform.system(),platform.system().lower()),
                          'image':None,'helper_sha256':None,'outcome':'Failed'} for p in paths]
        result=capture.index(run,[{'identifier':'DispatchTests/Example/test','outcome':'Failed'}])
        self.assertEqual(result['captures'],sorted(expected,key=lambda r:r['path']))
        self.assertEqual(result['collection_errors'],[])

    def test_retention_preserves_all_passed_variants_and_only_their_dependencies(self):
        run=capture.begin(self.root,'mixed',[{'platform':'linux','path':sys.executable}])
        self.assertEqual(run,self.root/'build/captures/mixed')
        manifest=json.loads((run/'manifest.json').read_text())
        helper=manifest['helpers'][0]
        statuses=['Passed','passed','Failed',None,'skipped',['Passed','Failed']]
        for category in ('captures','app'):
            for index,outcome in enumerate(statuses):
                # Export treats payload as opaque; these are genuine captured bytes.
                path=run/('raw' if category=='captures' else 'app')/f'variant{index}.jsonl'
                shutil.copyfile(self.fixture,path)
                entry={'case':f'Case.test{index}','path':str(path.relative_to(run)),
                       'sha256':capture.digest(path),'outcome':outcome,'variant':str(index)}
                if category=='captures':entry['helper_sha256']=helper['sha256']
                manifest[category].append(entry)
        manifest['outcomes']=[{'identifier':f'DispatchTests/Case/test{i}','outcome':v} for i,v in enumerate(statuses)]
        manifest['collection_errors']=[{'case':'Case.test0','errors':['retained issue']},
                                       {'case':'Case.test2','errors':['excluded issue']},
                                       {'case':None,'errors':['unscoped issue']}]
        capture.write(run/'manifest.json',manifest)
        before={str(p.relative_to(run)):capture.digest(p) for p in run.rglob('*') if p.is_file()}
        target=self.root/'captures/mixed'
        plan=capture.retain(run,target,dry_run=True)
        self.assertFalse(target.exists())
        self.assertEqual(plan['excluded'],{'captures':4,'app':4})
        self.assertEqual(len(plan['files']),5)
        capture.retain(run,target)
        actual=json.loads((target/'manifest.json').read_text())
        expected={**manifest,'captures':manifest['captures'][:2],'app':manifest['app'][:2],
                  'outcomes':manifest['outcomes'][:2],
                  'collection_errors':[manifest['collection_errors'][0],manifest['collection_errors'][2]],
                  'retention':{'source_manifest_sha256':before['manifest.json'],
                               'excluded':{'captures':4,'app':4}}}
        self.assertEqual(actual,expected)
        self.assertEqual({str(p.relative_to(run)):capture.digest(p) for p in run.rglob('*') if p.is_file()},before)
        for entry in actual['captures']+actual['app']+actual['helpers']:
            self.assertEqual(capture.digest(target/entry['path']),entry['sha256'])
        with self.assertRaises(FileExistsError):capture.retain(run,target)

    def test_retention_rejects_changed_or_escaping_files_without_publication(self):
        run=capture.begin(self.root,'invalid',[])
        manifest=json.loads((run/'manifest.json').read_text())
        path=run/'raw/pass.jsonl'
        shutil.copyfile(self.fixture,path)
        entry={'case':'Case.test','path':'raw/pass.jsonl','sha256':capture.digest(path),'outcome':'passed'}
        manifest['captures']=[entry]
        target=self.root/'captures/invalid'
        for changed in [{**entry,'sha256':'0'*64},{**entry,'path':'../remote/helper-17-1.jsonl'}]:
            manifest['captures']=[changed];capture.write(run/'manifest.json',manifest)
            with self.assertRaises(ValueError):capture.retain(run,target)
            self.assertFalse(target.exists())
        path.unlink();path.symlink_to(self.fixture.resolve())
        manifest['captures']=[entry];capture.write(run/'manifest.json',manifest)
        with self.assertRaises(ValueError):capture.retain(run,target)
        self.assertFalse(target.exists())

    def test_retention_keeps_proofs_and_rejects_incomplete_copy(self):
        run=capture.begin(self.root,'proof',[])
        manifest=json.loads((run/'manifest.json').read_text())
        path=run/'raw/pass.jsonl'
        shutil.copyfile(self.fixture,path)
        proof=run/'proofs/proof.json'
        proof.parent.mkdir();proof.write_text('{"verified":true}\n')
        manifest['captures']=[{'case':'Case.test','path':'raw/pass.jsonl',
            'sha256':capture.digest(path),'outcome':'passed',
            'binding_proof':{'path':'proofs/proof.json','sha256':capture.digest(proof)}}]
        manifest['helpers']=[{'path':'helpers/unused','sha256':'unused','platform':'linux'}]
        capture.write(run/'manifest.json',manifest)
        target=self.root/'captures/proof'
        copy=shutil.copy2
        def corrupt(source,destination):
            result=copy(source,destination)
            Path(destination).write_bytes(b'bad transfer')
            return result
        with patch.object(capture.shutil,'copy2',corrupt),self.assertRaises(ValueError):
            capture.retain(run,target)
        self.assertFalse(target.exists())
        capture.retain(run,target)
        actual=json.loads((target/'manifest.json').read_text())
        self.assertEqual(actual['helpers'],[])
        self.assertEqual(actual['captures'],manifest['captures'])
        self.assertEqual((target/'proofs/proof.json').read_bytes(),proof.read_bytes())
        self.assertEqual(sorted(str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()),
                         ['manifest.json','proofs/proof.json','raw/pass.jsonl'])

    def test_retention_of_run_without_passed_variants_publishes_nothing(self):
        run=capture.begin(self.root,'empty',[])
        target=self.root/'captures/empty'
        plan=capture.retain(run,target)
        self.assertEqual(plan['retained'],{'captures':0,'app':0})
        self.assertFalse(target.exists())


if __name__ == '__main__': unittest.main()
