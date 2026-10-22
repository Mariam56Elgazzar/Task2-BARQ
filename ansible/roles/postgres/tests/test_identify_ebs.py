"""Guard against selecting the wrong block device before filesystem creation."""

import importlib.util
from pathlib import Path
import unittest


MODULE = Path(__file__).parents[1] / "files" / "identify_ebs.py"
SPEC = importlib.util.spec_from_file_location("identify_ebs", MODULE)
identify_ebs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identify_ebs)


class IdentifyEbsTests(unittest.TestCase):
    def setUp(self):
        self.volume = "vol-0123456789abcdef0"
        self.disk = {
            "path": "/dev/nvme1n1",
            "serial": "vol0123456789abcdef0",
            "type": "disk",
            "mountpoint": None,
        }

    def test_finds_exact_serial_among_disks(self):
        root = {"path": "/dev/nvme0n1", "serial": "vol00000000000000000", "type": "disk"}
        self.assertEqual(
            identify_ebs.identify([root, self.disk], self.volume, "/srv/pgdata"),
            "/dev/nvme1n1",
        )

    def test_refuses_missing_or_duplicate_device(self):
        with self.assertRaises(ValueError):
            identify_ebs.identify([], self.volume, "/srv/pgdata")
        with self.assertRaises(ValueError):
            identify_ebs.identify([self.disk, self.disk], self.volume, "/srv/pgdata")

    def test_refuses_partitions_and_other_mounts(self):
        with self.assertRaises(ValueError):
            identify_ebs.identify([self.disk | {"children": [{"type": "part"}]}], self.volume, "/srv/pgdata")
        with self.assertRaises(ValueError):
            identify_ebs.identify([self.disk | {"mountpoint": "/"}], self.volume, "/srv/pgdata")


if __name__ == "__main__":
    unittest.main()
