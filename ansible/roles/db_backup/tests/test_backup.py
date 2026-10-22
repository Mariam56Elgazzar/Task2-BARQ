"""Exercise backup completion, failure cleanup, and scoped retention locally."""

import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from jinja2 import Environment, FileSystemLoader, StrictUndefined


TEMPLATES = Path(__file__).parents[1] / "templates"


class BackupScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.backup_dir = root / "backups"
        self.backup_dir.mkdir(mode=0o700)
        self.stack_dir = root / "db"
        self.stack_dir.mkdir()
        (self.stack_dir / ".env").write_text("POSTGRES_DB=notes\n", encoding="utf-8")
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        mountpoint = self.bin_dir / "mountpoint"
        mountpoint.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        mountpoint.chmod(0o755)
        self.docker = self.bin_dir / "fake-docker"
        self.docker.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ \"$*\" == *pg_dump* ]]; then\n"
            "  printf 'PGDMP-test-archive'\n"
            "  [[ ${FAKE_DUMP_FAIL:-0} != 1 ]]\n"
            "elif [[ \"$*\" == *pg_restore* ]]; then\n"
            "  cat >/dev/null\n"
            "  [[ ${FAKE_RESTORE_FAIL:-0} != 1 ]]\n"
            "else exit 2; fi\n",
            encoding="utf-8",
        )
        self.docker.chmod(0o755)
        env = Environment(loader=FileSystemLoader(TEMPLATES), undefined=StrictUndefined)
        rendered = env.get_template("notes-pg-backup.j2").render(
            backup_directory=str(self.backup_dir),
            backup_stack_path=str(self.stack_dir),
            backup_mount_path=str(root / "data"),
            backup_docker_bin=str(self.docker),
            backup_retention_days=7,
        )
        self.script = root / "backup.sh"
        self.script.write_text(rendered, encoding="utf-8")
        self.script.chmod(0o700)
        self.env = os.environ | {"PATH": f"{self.bin_dir}:{os.environ['PATH']}"}

    def run_backup(self, *args, **extra_env):
        return subprocess.run(
            [str(self.script), *args],
            env=self.env | extra_env,
            capture_output=True,
            text=True,
            check=False,
        )

    def archives(self):
        return list(self.backup_dir.glob("notes-*.dump"))

    def test_success_creates_checked_pair_and_status_is_read_only(self):
        self.assertEqual(self.run_backup().returncode, 0)
        archive = self.archives()[0]
        self.assertTrue(Path(f"{archive}.sha256").is_file())
        self.assertEqual(self.run_backup("--has-complete").returncode, 0)
        self.assertEqual(len(self.archives()), 1)

    def test_failed_dump_preserves_old_backup_and_cleans_partial(self):
        self.assertEqual(self.run_backup().returncode, 0)
        existing = self.archives()[0]
        self.assertNotEqual(self.run_backup(FAKE_DUMP_FAIL="1").returncode, 0)
        self.assertEqual(self.archives(), [existing])
        self.assertFalse(list(self.backup_dir.glob("*.partial")))

    def test_failed_archive_check_does_not_publish_partial(self):
        self.assertNotEqual(self.run_backup(FAKE_RESTORE_FAIL="1").returncode, 0)
        self.assertFalse(self.archives())
        self.assertFalse(list(self.backup_dir.glob("*.partial")))

    def test_retention_only_removes_old_complete_project_pair(self):
        old = self.backup_dir / "notes-old.dump"
        old.write_text("old", encoding="utf-8")
        sidecar = Path(f"{old}.sha256")
        sidecar.write_text("placeholder\n", encoding="utf-8")
        unrelated = self.backup_dir / "other-project.dump"
        unrelated.write_text("keep", encoding="utf-8")
        past = time.time() - 8 * 86400
        os.utime(old, (past, past))
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertFalse(old.exists())
        self.assertFalse(sidecar.exists())
        self.assertTrue(unrelated.exists())

    def test_concurrent_attempt_fails_without_touching_backups(self):
        lock = self.backup_dir / ".backup.lock"
        with lock.open("w", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.run_backup().returncode, 0)
        self.assertFalse(self.archives())


if __name__ == "__main__":
    unittest.main()
