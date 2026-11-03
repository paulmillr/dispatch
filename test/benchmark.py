#!/usr/bin/env python3
"""Headless regression checks for benchmark integrity and comparison rules."""
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).resolve().parent.parent / 'scripts/benchmark.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
with patch.dict(sys.modules, benchmark=bench):
    frame_spec = importlib.util.spec_from_file_location('chat_frames', Path(__file__).resolve().parent.parent / 'scripts/benchmark-chat-frames.py')
    frames = importlib.util.module_from_spec(frame_spec)
    frame_spec.loader.exec_module(frames)


def report(samples=None):
    return {'schema': 1, 'workload_version': 1, 'suite': 'core', 'environment': {'kind': 'hardware'},
            'configuration': 'Release', 'duration_seconds': 5, 'repeats': 3, 'status': 'complete',
            'runs': [[bench.metric('parse/latency', 'ms', samples or list(range(1, 11)))] for _ in range(3)]}


class BenchmarkTests(unittest.TestCase):
    def test_comparison_preserves_samples_and_reports_change(self):
        before, after = report(), report(list(range(2, 22, 2)))
        delta = bench.compare(before, after)['parse/latency']
        self.assertEqual(delta['percent'], 100)
        self.assertEqual(delta['before']['p95'], 10)
        self.assertNotIn('p99', delta['before'])
        self.assertEqual(delta['after']['runs'][0], list(range(2, 22, 2)))

    def test_rejects_incompatible_conditions(self):
        for key, value in [('environment', {'kind': 'vm'}), ('suite', 'full'),
                           ('workload_version', 2), ('configuration', 'Debug'), ('duration_seconds', 60)]:
            with self.subTest(key=key):
                after = report()
                after[key] = value
                with self.assertRaises(ValueError):
                    bench.compare(report(), after)

    def test_rejects_missing_duplicate_and_mismatched_workloads(self):
        for mutation in ('missing', 'duplicate', 'unit', 'count'):
            after = report()
            if mutation == 'missing':
                after['runs'][1] = []
            elif mutation == 'duplicate':
                after['runs'][1] *= 2
            elif mutation == 'unit':
                after['runs'][1][0]['unit'] = 's'
            else:
                after['runs'][1][0]['samples'].append(42)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                bench.compare(report(), after)

    def test_rejects_invalid_samples(self):
        for values in ([], [float('nan')], [float('inf')], ['3'], [True]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                bench.metric('invalid', 'ms', values)

    def test_zero_baseline_has_no_percentage(self):
        delta = bench.compare(report([0]), report([1]))['parse/latency']
        self.assertIsNone(delta['percent'])
        self.assertEqual(delta['delta'], 1)

    def test_observed_heartbeat_counts_can_differ(self):
        before, after = report(), report()
        for run in before['runs'] + after['runs']:
            run[0]['sampling'] = 'observed'
        after['runs'][1][0]['samples'].append(11)
        self.assertIn('parse/latency', bench.compare(before, after))

    def test_rejects_failed_and_incomplete_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for status, runs in [('failed', 3), ('running', 3), ('complete', 2)]:
                value = report()
                value['status'] = status
                value['runs'] = value['runs'][:runs]
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    bench.read_report(str(path))

    def test_modern_and_legacy_xctestrun_targets(self):
        target = {'TestBundlePath': 'tests'}
        self.assertEqual(bench.test_targets({'DispatchTests': target, '__xctestrun_metadata__': {}}), [target])
        self.assertEqual(bench.test_targets({'TestConfigurations': [{'TestTargets': [target]}]}), [target])

    def test_ui_adapter_retains_memory_and_latency(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'ui').mkdir()
            (folder / 'ui/sample.json').write_text(json.dumps({'name': 'action', 'seconds': [.01, .02],
                'cpuSeconds': .1, 'residentBefore': 2**20, 'residentAfter': 2 * 2**20,
                'peakResident': 3 * 2**20, 'heartbeatSeconds': [.016]}))
            values = {v['name']: v for v in bench.ui_reports(folder)}
            self.assertEqual(values['action/latency']['samples'], [10, 20])
            self.assertEqual(values['action/rss-growth']['samples'], [1])
            self.assertEqual(values['action/peak-rss']['samples'], [3])

    def test_scrolling_frames_keep_presentation_separate_from_input(self):
        row = dict(uniqueFrames=11, captureSamples=20, presentationIntervals=[1 / 60] * 10,
                   compositedFPS=60, callbackHz=120, work=[.002, .009], workOver120Budget=1,
                   cpuSeconds=1, mainCPUSeconds=.8, rssPeak=3 * 2**20)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in frames.PHASES:
                (folder / (name + '.json')).write_text(json.dumps(row))
            values = {v['name']: v for v in frames.metrics(folder)}
            self.assertEqual(values['mixed-2400/composited-fps']['samples'], [60])
            self.assertEqual(values['mixed-2400/input-rate']['samples'], [120])
            self.assertEqual(values['mixed-2400/main-loop-work']['samples'], [2, 9])
            self.assertEqual(values['mixed-2400/main-loop-work']['sampling'], 'observed')
            self.assertEqual(values['mixed-2400/work-over-120Hz-budget']['samples'], [50])
            for change in (dict(uniqueFrames=9), dict(captureSamples=5), dict(work=[]), dict(presentationIntervals=[])):
                with self.subTest(change=change):
                    (folder / (frames.PHASES[0] + '.json')).write_text(json.dumps(row | change))
                    with self.assertRaises(ValueError):
                        frames.metrics(folder)


if __name__ == '__main__':
    unittest.main()
