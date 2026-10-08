"""Metadata tests; these never invent or modify an interaction capture."""
import unittest
from unittest.mock import patch
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile
from capture import digest
from replay import plan, regressions, main
from replay_worker import compare, read


class Comparison(unittest.TestCase):
    def test_build_command_uses_built_helpers_and_refuses_empty_corpus(self):
        import replay
        root=Path(__file__).resolve().parent.parent
        with patch('replay.subprocess.run') as run, patch('replay.plan',return_value=({},[])) as planned, \
             patch('replay.write'), patch('replay.Path.mkdir'), patch('replay.Path.read_text',return_value='[]'), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(['--build']),1)
        self.assertEqual([call.args[0] for call in run.call_args_list],[
            [sys.executable,str(root/'scripts/build-ssh-helper.py'),'--build-only'],
            [sys.executable,str(root/'scripts/build-ssh-helper.py'),'--build-only','--replay-tools']])
        corpus,helpers,tools,remotes,strict=planned.call_args.args
        self.assertEqual((corpus,helpers,tools,strict),(root/'captures',
            {'macos':root/'build/helper4-rust/bin/darwin-universal','linux':root/'build/helper4-rust/bin/linux-x86_64'},
            {'macos':root/'build/helper4-rust/bin/replay/darwin-universal','linux':root/'build/helper4-rust/bin/replay/linux-x86_64'},True))

    def test_all_observed_versions_and_nonzero_exits_are_retained(self):
        original = {
            'run-a/case/lifetime': {'complete': True, 'exit': 7},
            'run-b/case/lifetime': {'complete': True, 'exit': 0},
            'run-c/case/lifetime': {'complete': False, 'exit': 0},
        }
        candidate = {
            'run-a/case/lifetime': {'complete': True, 'exit': 7},
            'run-b/case/lifetime': {'complete': True, 'exit': 1},
            'run-c/case/lifetime': {'complete': True, 'exit': 0},
        }
        self.assertEqual(compare(original, candidate), [
            {'capture': 'run-a/case/lifetime', 'status': 'same', 'reason': None, 'original_exit': 7, 'candidate_exit': 7},
            {'capture': 'run-b/case/lifetime', 'status': 'changed', 'reason': 'exit differs', 'original_exit': 0, 'candidate_exit': 1},
            {'capture': 'run-c/case/lifetime', 'status': 'unverified', 'reason': 'original replay incomplete', 'original_exit': 0, 'candidate_exit': 0},
        ])

    def test_completion_boundaries_are_compared_without_inferring_native_success(self):
        original={name:dict(complete=True,exit=0,completion=boundary) for name,boundary in [
            ('handoff',{'kind':'handoff'}),('return',{'kind':'return','status':0}),('legacy',None)]}
        candidate={name:dict(row,completion={'kind':'return','status':0}) for name,row in original.items()}
        self.assertEqual(compare(original,candidate),[
            dict(capture='handoff',status='changed',reason='completion differs',original_exit=0,candidate_exit=0,
                 original_completion={'kind':'handoff'},candidate_completion={'kind':'return','status':0}),
            dict(capture='legacy',status='changed',reason='completion differs',original_exit=0,candidate_exit=0,
                 original_completion=None,candidate_completion={'kind':'return','status':0}),
            dict(capture='return',status='same',reason=None,original_exit=0,candidate_exit=0,
                 original_completion={'kind':'return','status':0},candidate_completion={'kind':'return','status':0})])

    def test_receipt_cannot_override_mismatch_or_contradict_process_exit(self):
        temporary=Path(__file__).resolve().parent.parent/'build/replay-tests'
        temporary.mkdir(parents=True,exist_ok=True)
        cases=[
            ('return-seven',7,{'kind':'return','status':7},False,True),
            ('return-wrapped',255,{'kind':'return','status':-1},False,True),
            ('wrong-return',7,{'kind':'return','status':0},False,False),
            ('wrong-handoff',7,{'kind':'handoff'},False,False),
            ('signal-hup',129,{'kind':'signal','signal':1},False,True),
            ('signal-term',143,{'kind':'signal','signal':15},False,True),
            ('wrong-signal',0,{'kind':'signal','signal':15},False,False),
            ('invalid-signal',128,{'kind':'signal','signal':0},False,False),
            ('signal-mismatch',129,{'kind':'signal','signal':1},True,False),
            ('mismatch',0,{'kind':'return','status':0},True,False),
        ]
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            root=Path(directory)
            rows=[]
            for index,(name,status,boundary,mismatch,_) in enumerate(cases):
                rows.append(dict(capture=name,exit=status,status='pass' if status==0 else 'fail'))
                receipt=root/f'{index:06}.complete'
                receipt.write_text(json.dumps(boundary));receipt.chmod(0o600)
                if mismatch:
                    evidence=root/f'{index:06}.mismatch';evidence.mkdir()
                    (evidence/'mismatch.json').write_text('{}')
            (root/'report.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            actual=read(root)
            self.assertEqual({name:row['complete'] for name,row in actual.items()},
                             {name:complete for name,_,_,_,complete in cases})
            self.assertEqual({row['capture']:row['status'] for row in compare(actual,actual)},
                             {name:'same' if complete else 'unverified' for name,_,_,_,complete in cases})

    def test_receipt_body_is_validated_but_empty_legacy_receipt_is_supported(self):
        temporary=Path(__file__).resolve().parent.parent/'build/replay-tests'
        temporary.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            root=Path(directory)
            rows=[dict(capture=name,exit=0,status='pass') for name in ['legacy','handoff','invalid']]
            (root/'report.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            for i,body in enumerate(['','{"kind":"handoff"}','{"kind":"native-success"}']):
                path=root/f'{i:06}.complete'
                path.write_text(body);path.chmod(0o600)
            result=read(root)
            self.assertEqual([(key,row['complete'],row.get('completion')) for key,row in result.items()],
                             [('legacy',True,None),('handoff',True,{'kind':'handoff'}),('invalid',False,None)])

    def test_helper_plan_retains_all_versions_across_runs(self):
        root = Path(__file__).resolve().parent.parent
        temporary = root / 'build/replay-tests'
        temporary.mkdir(parents=True, exist_ok=True)
        native = {'Darwin': 'macos', 'Linux': 'linux'}[platform.system()]
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            corpus = Path(directory)
            expected = []
            for name in ('older', 'newer'):
                run = corpus / name
                run.mkdir()
                helper = run / 'helper'
                shutil.copyfile(sys.executable, helper)
                entries = []
                for version in ('first', 'second'):
                    capture = run / (version + '.jsonl')
                    shutil.copyfile(root / 'test/fixtures/helper-login/capture.jsonl', capture)
                    entries.append(dict(case='Example.test', path=capture.name,
                                        sha256=digest(capture), platform=native,
                                        helper_sha256=digest(helper)))
                    expected.append((name, capture.name))
                (run / 'manifest.json').write_text(json.dumps(dict(
                    version=1, run=name, captures=entries,
                    helpers=[dict(path=helper.name, sha256=digest(helper))])))
            groups, unsupported = plan(corpus, {native: Path(sys.executable)},
                                       {native: Path(sys.executable)}, {})
            self.assertEqual(unsupported, [])
            self.assertEqual(sorted((row['run'], row['path'])
                                    for rows in groups.values() for row in rows), sorted(expected))

    def test_regressions_keep_each_previously_passing_changed_version(self):
        rows = [dict(run=str(i), case='Example.test', outcome=outcome, status=status)
                for i, (outcome, status) in enumerate([
                    ('Passed', 'changed'), ('passed', 'changed'), ('Failed', 'changed'),
                    (None, 'changed'), ('Passed', 'same'), ('Passed', 'unverified')])]
        self.assertEqual(regressions(rows), rows[:2])

    def test_requested_captures_missing_from_both_reports_cannot_pass(self):
        complete = dict(complete=True, exit=0)
        self.assertEqual(compare({'extra': complete}, {'extra': complete}, ['missing']), [
            dict(capture='extra', status='unverified', reason='unexpected capture result',
                 original_exit=0, candidate_exit=0),
            dict(capture='missing', status='unverified', reason='original result missing',
                 original_exit=None, candidate_exit=None),
        ])

    def test_preflight_reports_every_variant_and_worker_failure(self):
        root = Path(__file__).resolve().parent.parent
        temporary = root / 'build/replay-tests'
        temporary.mkdir(parents=True, exist_ok=True)
        native = {'Darwin': 'macos', 'Linux': 'linux'}[platform.system()]
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            corpus = Path(directory)
            helper = corpus / 'helper'
            shutil.copyfile(sys.executable, helper)
            entries = []
            for name, outcome in [('same', 'passed'), ('changed', 'passed'), ('missing', 'passed'),
                                  ('failed', 'failed'), ('unknown', None)]:
                capture = corpus / (name + '.jsonl')
                shutil.copyfile(root / 'test/fixtures/helper-login/capture.jsonl', capture)
                entries.append(dict(case='Example.test', path=capture.name, outcome=outcome,
                    sha256=digest(capture), platform=native, helper_sha256=digest(helper)))
            (corpus / 'manifest.json').write_text(json.dumps(dict(version=1, run='all-variants',
                captures=entries, helpers=[dict(path=helper.name, sha256=digest(helper))])))
            def worker(command, **kwargs):
                destination = Path(command[command.index('--output') + 1])
                destination.mkdir()
                (destination / 'comparison.json').write_text(json.dumps([
                    dict(capture='same.jsonl', status='same', reason=None),
                    dict(capture='changed.jsonl', status='changed', reason='candidate replay incomplete')]))
            output = io.StringIO()
            report = corpus / 'report'
            args = [str(corpus), '--helper', native+'='+str(helper), '--tool', native+'='+str(helper),
                    '--output', str(report), '--require-same']
            with patch('replay.subprocess.run', side_effect=worker), contextlib.redirect_stdout(output):
                self.assertEqual(main(args), 1)
            rows = json.loads((report / 'report.json').read_text())
            self.assertEqual({r['path']: r['status'] for r in rows}, {
                'same.jsonl': 'same', 'changed.jsonl': 'changed', 'missing.jsonl': 'unverified',
                'failed.jsonl': 'unverified', 'unknown.jsonl': 'unverified'})
            for name in ('changed', 'missing', 'failed', 'unknown'):
                self.assertIn(str(corpus / (name+'.jsonl')), output.getvalue())
            self.assertIn('Example.test', output.getvalue())
            gate = json.loads((report / 'gate.json').read_text())
            self.assertFalse(gate['passed'])
            self.assertEqual(gate['captures'], 5)

            manifest = json.loads((corpus/'manifest.json').read_text())
            manifest['captures'] = entries[:3]
            (corpus/'manifest.json').write_text(json.dumps(manifest))
            def successful(command, **kwargs):
                destination = Path(command[command.index('--output') + 1])
                destination.mkdir()
                listing = json.loads(Path(command[command.index('--list') + 1]).read_text())
                (destination/'comparison.json').write_text(json.dumps([
                    dict(capture=name, status='same', reason=None) for name in listing]))
            args[args.index('--output')+1] = str(corpus/'verified')
            with patch('replay.subprocess.run', side_effect=successful), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(args), 0)
            self.assertEqual(json.loads((corpus/'verified/gate.json').read_text()),
                             dict(passed=True, captures=3, blocked=[]))
            args[args.index('--output')+1] = str(corpus/'worker-error')
            with patch('replay.subprocess.run', side_effect=OSError('worker unavailable')), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(args), 1)
            failures = json.loads((corpus/'worker-error/report.json').read_text())
            self.assertEqual([(r['path'],r['status'],r['reason']) for r in failures],
                             [(r['path'],'unverified','worker unavailable') for r in entries[:3]])
            manifest['captures'][0]['sha256'] = 'incorrect'
            (corpus/'manifest.json').write_text(json.dumps(manifest))
            groups, blocked = plan(corpus/'manifest.json', {native:helper}, {native:helper}, {}, require_same=True)
            self.assertEqual([r['path'] for r in blocked], ['same.jsonl'])
            self.assertEqual([r['path'] for group in groups.values() for r in group], ['changed.jsonl','missing.jsonl'])

    def test_preflight_rejects_empty_and_missing_platform_worker(self):
        root = Path(__file__).resolve().parent.parent
        temporary = root / 'build/replay-tests'
        temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            corpus = Path(directory)
            manifest = dict(version=1, run='empty', captures=[], helpers=[])
            (corpus / 'manifest.json').write_text(json.dumps(manifest))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main([str(corpus), '--require-same', '--output', str(corpus/'empty')]), 1)
            manifest['captures'] = [dict(case='Example.test',path='missing.jsonl', outcome='passed',
                platform='missing-platform', helper_sha256='sha')]
            manifest['helpers'] = [dict(path='helper', sha256='sha')]
            (corpus/'manifest.json').write_text(json.dumps(manifest))
            groups, rows = plan(corpus/'manifest.json', {}, {}, {}, require_same=True)
            self.assertEqual(groups, {})
            self.assertEqual([(r['case'],r['path'],r['reason']) for r in rows],
                             [('Example.test','missing.jsonl','platform worker missing')])

    def test_missing_completion_or_results_cannot_pass(self):
        original = {'a': {'complete': True, 'exit': 0}, 'b': {'complete': True, 'exit': 0}}
        candidate = {'a': {'complete': False, 'exit': 0}, 'c': {'complete': True, 'exit': 0}}
        self.assertEqual(compare(original, candidate), [
            {'capture': 'a', 'status': 'changed', 'reason': 'candidate replay incomplete', 'original_exit': 0, 'candidate_exit': 0},
            {'capture': 'b', 'status': 'unverified', 'reason': 'candidate result missing', 'original_exit': 0, 'candidate_exit': None},
            {'capture': 'c', 'status': 'unverified', 'reason': 'original result missing', 'original_exit': None, 'candidate_exit': 0},
        ])


class Builder(unittest.TestCase):
    def test_replay_tools_reuse_four_targets_without_touching_helpers(self):
        root = Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location('portable_builder', root/'scripts/build-ssh-helper.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        temporary = root/'build/replay-tests'
        temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            project = Path(directory)
            cache = project/'target'
            (cache/'bin').mkdir(parents=True)
            protected = ('version','protocol-version',*builder.NAMES)
            for name in protected: (cache/'bin'/name).write_bytes(b'unchanged-helper')
            commands = []
            def execute(*args, **kwargs):
                commands.append(args)
                if len(args)>1 and args[1]=='build':
                    self.assertEqual(args[args.index('--package')+1], 'dispatch-helper4-core')
                    self.assertEqual(args[args.index('--example')+1], 'capture-redact')
                    self.assertEqual(args.count('--target'), 4)
                    for i, arg in enumerate(args):
                        if arg=='--target':
                            path=cache/args[i+1]/'release/examples/capture-redact'
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_bytes(args[i+1].encode())
                    from types import SimpleNamespace
                    return SimpleNamespace(stdout='')
                if args[:3]==('xcrun','lipo','-create'):
                    Path(args[-1]).write_bytes(b'universal-example')
            with patch.object(builder,'ROOT',project), patch.object(builder,'run',side_effect=execute), \
                 patch.object(builder.subprocess,'check_output',return_value='host: aarch64-apple-darwin\n'), \
                 patch.object(builder,'codec') as codec:
                builder.build('local',cache,replay_tools=True)
                codec.assert_not_called()
            self.assertEqual({p.name:p.read_bytes() for p in (cache/'bin/replay').iterdir()}, {
                'darwin-universal':b'universal-example', 'linux-aarch64':b'aarch64-unknown-linux-musl',
                'linux-x86_64':b'x86_64-unknown-linux-musl'})
            self.assertEqual([(cache/'bin'/name).read_bytes() for name in protected], [b'unchanged-helper']*len(protected))
            self.assertFalse((project/'build/ssh-helper-resources').exists())
            dry = project/'dry'
            with patch.object(builder,'ROOT',project), patch.object(builder,'run') as run, \
                 patch.object(builder.subprocess,'check_output',return_value='host: aarch64-apple-darwin\n'), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                builder.build('local',dry,replay_tools=True,dry_run=True)
                run.assert_not_called()
            self.assertFalse(dry.exists())
            self.assertIn('capture-redact',output.getvalue())
            self.assertIn(str(dry/'bin/replay/darwin-universal'),output.getvalue())

    def test_release_helpers_leave_out_capture_in_their_own_cargo_cache(self):
        root = Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location('portable_builder', root/'scripts/build-ssh-helper.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        temporary = root/'build/replay-tests'
        temporary.mkdir(parents=True, exist_ok=True)
        for configuration, features, cache in (('Debug', ['--features', 'dispatch-helper4/capture'], ''),
                                               ('Release', [], 'without-capture')):
            with self.subTest(configuration), tempfile.TemporaryDirectory(dir=temporary) as directory:
                project = Path(directory)
                target = project/'target'
                builds = []
                def execute(*args, **kwargs):
                    if len(args)>1 and args[1]=='build':
                        builds.append((args, kwargs['env']['CARGO_TARGET_DIR']))
                        for i, arg in enumerate(args):
                            if arg=='--target':
                                path=Path(kwargs['env']['CARGO_TARGET_DIR'])/args[i+1]/'release/dispatch-helper4'
                                path.parent.mkdir(parents=True, exist_ok=True)
                                path.write_bytes(args[i+1].encode())
                        from types import SimpleNamespace
                        return SimpleNamespace(stdout='')
                    if args[:3]==('xcrun','lipo','-create'):
                        Path(args[-1]).write_bytes(b'universal')
                with patch.dict(builder.os.environ, {'CONFIGURATION': configuration}), \
                     patch.object(builder,'ROOT',project), patch.object(builder,'run',side_effect=execute), \
                     patch.object(builder.subprocess,'check_output',return_value='host: aarch64-apple-darwin\n'), \
                     patch.object(builder,'codec',return_value='1\n'), contextlib.redirect_stdout(io.StringIO()):
                    builder.build('local',target)
                (args, cargo), = builds
                self.assertEqual([arg for arg in args if 'capture' in arg or arg=='--features'], features)
                self.assertEqual(Path(cargo), target/cache)
                self.assertEqual((target/'bin/linux-x86_64').read_bytes(), b'x86_64-unknown-linux-musl')


if __name__ == '__main__':
    unittest.main()
