"""Small, persistent timing records for host and guest test stages."""
from contextlib import contextmanager
from pathlib import Path
import json
import subprocess
import sys
import time
import threading


class Profile:
    def __init__(self, path):
        self.path = Path(path)
        self.data = {'stages': []}
        self._lock = threading.RLock()

    def save(self):
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix('.tmp')
            temporary.write_text(json.dumps(self.data, indent=2) + '\n')
            temporary.replace(self.path)

    @contextmanager
    def stage(self, name):
        record = {'name': name, 'status': 'running'}
        with self._lock:
            self.data['stages'].append(record)
            self.save()
        started = time.perf_counter()
        try:
            yield record
        except BaseException:
            record['status'] = 'failed'
            raise
        else:
            if record['status'] == 'running':
                record['status'] = 'passed'
        finally:
            record['seconds'] = time.perf_counter() - started
            self.save()


if __name__ == '__main__':
    path, stage, *command = sys.argv[1:]
    profile = Profile(path)
    if profile.path.exists():
        profile.data = json.loads(profile.path.read_text())
    try:
        with profile.stage(stage):
            subprocess.run(command, check=True)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
