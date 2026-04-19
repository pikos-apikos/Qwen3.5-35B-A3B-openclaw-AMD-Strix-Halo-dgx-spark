#!/usr/bin/env python3
"""Validate all systemd unit files in the systemd/ directory."""
import configparser
import sys
from pathlib import Path

failed = False
for path in sorted(Path("systemd").glob("*.service")):
    print(f"Checking: {path}")
    try:
        cp = configparser.ConfigParser()
        cp.read(path)
        desc = cp["Unit"]["Description"]
        exec_start = cp["Service"]["ExecStart"]
        print(f"  Unit: {desc}")
        print(f"  ExecStart: {exec_start.strip()}")
        print("  OK")
    except Exception as e:
        print(f"  FAILED: {e}")
        failed = True
    print()

sys.exit(1 if failed else 0)