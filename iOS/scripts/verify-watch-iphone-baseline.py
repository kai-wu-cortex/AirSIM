#!/usr/bin/env python3
"""Watch-only preview must preserve the validated iPhone 204 source baseline."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
baseline = "291249a0"
protected = ("iOS/AirSIM/", "iOS/Shared/", "iOS/AirSIMNotificationService/", "iOS/AirSIMLiveActivityExtension/")
def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args])
files = git("ls-tree", "-r", "--name-only", baseline).decode().splitlines()
checked = 0
for name in files:
    if name.startswith(protected) or name == "iOS/AirSIM.xcodeproj/project.pbxproj":
        if (root / name).read_bytes() != git("show", f"{baseline}:{name}"):
            raise SystemExit(f"iPhone baseline changed: {name}")
        checked += 1
print(f"iPhone 204 freeze verified: {checked} files byte-identical")
