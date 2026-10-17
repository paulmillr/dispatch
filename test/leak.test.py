"""leak.py's needles: time zones over a made-up zone database (a zone name gets another real zone of its byte length),
login banner times read from captures, and the prompts and startup files a machine's facts make."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import leak

WARNING = '; warning: fewer than 10, a value of this length hides little'


class Zone(unittest.TestCase):
    def setUp(self):
        self.zones, self.picked = leak.ZONES, dict(leak.PICKED)
        leak.ZONES, leak.PICKED = {'Area/One', 'Area/Two', 'Area/Three'}, {}

    def tearDown(self):
        leak.ZONES, leak.PICKED = self.zones, self.picked

    def test_a_zone_gets_another_zone_of_its_length_and_keeps_it(self):
        title = 'time zone name, a real zone of its byte length picked at random as its value (zones of that length: 2'
        self.assertEqual(leak.zone('Area/One'), (title + WARNING + ')', ['Area/One\tArea/Two']))
        self.assertEqual(leak.zone('Area/One'), (title + WARNING + ')', ['Area/One\tArea/Two']))
        # The only other zone of its length is taken: masked instead, never a value used before.
        self.assertEqual(leak.zone('Area/Two'), (title + ', every other one used here: masked instead' + WARNING + ')', ['Area/Two']))

    def test_a_zone_no_other_shares_its_length_with_stops(self):
        with self.assertRaises(SystemExit) as stop:
            leak.zone('Area/Three')
        self.assertEqual(str(stop.exception), 'time zone Area/Three: no other zone in the local database has its byte '
                         'length, so a replacement cannot hide it: handle it by hand (capture again with another TZ)')


class Banner(unittest.TestCase):
    def test_banner_times_get_distinct_values_on_one_day(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Path(directory, 'Suite/test')
            case.mkdir(parents=True)
            text = b'\0Last login: Fri Oct 16 14:44:47 on ttys007\r\nLast login: Tue Jun  9 04:32:50 on ttys012'
            (case / 'one.rpl').write_bytes(text + b'\x01Last login: Fri Oct 16 14:44:47 on ttys002')
            (case / 'two.rpl').write_bytes(b'Last login: Thu Jan  1 00:00:01 2026 from 10.0.0.1')
            # A capture's zstd, through the zstd tool.
            if shutil.which('zstd'):
                packed = subprocess.run(['zstd', '-cq', '--long=27'], input=b'Last login: Sat Mar  7 09:08:07 on ttys001',
                                        stdout=subprocess.PIPE, check=True).stdout
                (case / 'three.rpl.zst').write_bytes(packed)
            lines = leak.banners([Path(directory)])
        needles = [line.split('\t')[0] for line in lines]
        values = [line.split('\t')[1] for line in lines]
        zstd = ['Sat Mar  7 09:08:07'] if shutil.which('zstd') else []
        self.assertEqual(needles, ['Fri Oct 16 14:44:47'] + zstd + ['Thu Jan  1 00:00:01', 'Tue Jun  9 04:32:50'])
        self.assertEqual(len(set(values)), len(needles))
        self.assertTrue(all(value.startswith('Thu Jan  1 00:00:') and len(value) == 19 for value in values))
        # A value never equals a time met: capture replace refuses a value that is also a needle.
        self.assertNotIn('Thu Jan  1 00:00:01', values)

    def test_no_banners_give_no_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(leak.banners([Path(directory)]), [])


class Groups(unittest.TestCase):
    def test_prompts_and_startup_files(self):
        candidates, _ = leak.groups({'account': ['user'], 'host': ['test.local', 'test'],
                                     'startup': ['/Users/user/dots/home/.zshrc', '/Users/user/dots']})
        found = dict(candidates)
        self.assertEqual(found['shell prompts: account@host as a prompt shows it'], ['user@test', 'user@test.local'])
        self.assertEqual(found['shell startup files linked elsewhere and their repositories'],
                         ['/Users/user/dots/home/.zshrc', '/Users/user/dots'])

    def test_utc_names_no_place(self):
        # A machine in UTC (the runner's zone, a test VM's) gives no time zone needle: replaced, UTC would change in
        # every recording.
        candidates, _ = leak.groups({'timezone': ['/usr/share/zoneinfo/Etc/UTC', 'Etc/UTC', 'UTC +0000']})
        self.assertFalse([value for title, values in candidates if 'time zone' in title for value in values])


if __name__ == '__main__':
    unittest.main()
