#!/usr/bin/env python3
"""Regression cases for structural metrics; run with lizard 1.24.0 installed."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('quality_metrics', ROOT / 'scripts/quality-metrics.py')
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


class QualityMetricsTests(unittest.TestCase):
    def test_writers_include_subscripts_compound_and_optional_chains(self):
        for source in [
            'workspace.spaces = spaces', 'workspace.spaces += restored',
            'workspace.spaces[s].panes[p].tabs[t].herdr?.focusedSurface = id',
            'workspace.spaces[s].tmuxTabs[w].arrangement.panes[0].tabs = [tab]',
            'workspace.spaces.removeAll { $0.id == id }', 'workspace.spaces[s].panes.append(pane)',
            'workspace.spaces[s].panes[p].tabs.removeSubrange(0..<2)',
            'context.next.spaces = spaces',
        ]:
            # The name-based draft convention intentionally excludes next.
            expected = 0 if source.startswith('context.next.') else 1
            self.assertEqual(len(metrics.SPACES_WRITER.findall(source)), expected, source)
        for source in ['next.spaces.append(space)', 'layout.spaces[s].hostID = host',
                       '$0.spaces += spaces', 'workspace.spaces == spaces', 'workspace.spaces.count']:
            self.assertIsNone(metrics.SPACES_WRITER.search(source), source)
        self.assertIsNotNone(metrics.SPACES_WRITER.search('nextWorkspace.spaces = spaces'))

    def test_bare_extension_writes_and_selection(self):
        for source in ['spaces[s].hostID = host', 'spaces.insert(space, at: 0)', 'spaces += more']:
            self.assertIsNotNone(metrics.BARE_SPACES_WRITER.search(source), source)
        for source in ['next.spaces = spaces', 'let spaces = []', 'var spaces = []']:
            self.assertIsNone(metrics.BARE_SPACES_WRITER.search(source), source)
        self.assertIsNotNone(metrics.SELECTION_WRITER.search('workspace?.selectedSpace = selected'))
        for source in ['next.selectedSpace = id', 'layout.selectedSpace = id', '$0.selectedSpace = id',
                       'workspace.selectedSpace == id']:
            self.assertIsNone(metrics.SELECTION_WRITER.search(source), source)
        self.assertIsNotNone(metrics.BARE_SELECTION_WRITER.search('selectedSpace = id'))

    def test_collections_count_type_properties_not_nested_fields_or_locals(self):
        source = '''class Owner {
    @ObservationIgnored private(set) var ids: Set<UUID> = []
    private var values: [String: Int] = [:]
    struct Entry {
        let values: [Int]
    }
    func run() {
        var local: [String] = []
    }
}'''
        self.assertEqual(len(metrics.COLLECTION_PROPERTY.findall(source)), 2)

    def test_swift_initializer_expressions_do_not_hide_following_functions(self):
        source = '''struct Owner {
    func saved() {
        consume(.init(value: 1))
    }
    func apply() {
        if ready { update() }
    }
}'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Fixture.swift'
            path.write_text(metrics.SWIFT_INIT.sub('.__initializer', source))
            rows = metrics.run_lizard('swift', [path])
        self.assertIsNotNone(rows, 'Install lizard==1.24.0 to run the metrics tests')
        functions = {r['function']: r for r in rows}
        self.assertEqual(set(functions), {'saved', 'apply'})
        self.assertEqual(functions['saved']['ccn'], 1)
        self.assertEqual(functions['saved']['length'], 3)
        self.assertEqual(functions['apply']['ccn'], 2)

    def test_rust_byte_literals_and_inline_tests_preserve_line_positions(self):
        source = "fn production() { if tag == b'E' { run(); } }\n#[cfg(test)]\nmod tests {\nfn example() {}\n}\nfn last() {}\n"
        stripped = metrics.RUST_BYTE_CHAR.sub('0x00', metrics.strip_rust_tests(source))
        self.assertNotIn('example', stripped)
        self.assertNotIn("b'E'", stripped)
        self.assertEqual(stripped.count('\n'), source.count('\n'))
        self.assertIn('fn last()', stripped)


if __name__ == '__main__':
    unittest.main()
