#!/usr/bin/env python3
"""Resolve an EBS volume ID to one unmounted whole-disk device on this host."""

import json
import re
import subprocess
import sys


def identify(blocks, volume_id, expected_mount):
    if not re.fullmatch(r"vol-[0-9a-f]{8,17}", volume_id):
        raise ValueError("pg_data_volume_id must be an EBS volume ID")
    expected_serial = volume_id.replace("-", "")
    matches = [
        disk
        for disk in blocks
        if disk.get("type") == "disk"
        and str(disk.get("serial") or "").strip().replace("-", "").lower()
        == expected_serial
    ]
    if len(matches) != 1:
        raise ValueError("expected exactly one disk with the requested EBS serial")
    disk = matches[0]
    if disk.get("children"):
        raise ValueError("the EBS disk contains partitions; inspect it before deployment")
    mount = disk.get("mountpoint")
    if mount not in (None, expected_mount):
        raise ValueError("the EBS disk is mounted at an unexpected path")
    path = disk.get("path")
    if not isinstance(path, str) or not path.startswith("/dev/"):
        raise ValueError("the EBS disk has no device path")
    return path


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: identify_ebs.py VOLUME_ID EXPECTED_MOUNT")
    result = subprocess.run(
        ["lsblk", "--json", "--output", "PATH,SERIAL,TYPE,MOUNTPOINT"],
        check=True,
        capture_output=True,
        text=True,
    )
    blocks = json.loads(result.stdout)["blockdevices"]
    print(identify(blocks, sys.argv[1], sys.argv[2]))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"EBS identification failed: {error}", file=sys.stderr)
        sys.exit(1)
