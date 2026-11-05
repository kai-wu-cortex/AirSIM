#!/usr/bin/env python3
"""Reject Date >=/<= imports absent from the reported iOS 27.2 beta runtime.

Run on the final .app (including nested extensions/Watch/debug dylibs), or a
single Mach-O. This complements signing checks; it does not certify runtime
compatibility or replace a TestFlight launch test.
"""
import re
import subprocess
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-date-runtime-imports.py <app-or-Mach-O>")
    root = Path(sys.argv[1])
    if not root.exists():
        raise SystemExit(f"Missing artifact: {root}")
    magic = {bytes.fromhex(s) for s in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe",
        "bebafeca", "cafebabf", "bfbafeca")}
    imports = re.compile(r"_\$s10Foundation4DateV2[gl]eoiySbAC_ACtFZ\b")
    checked = 0
    failures = []
    for path in sorted(root.rglob("*")) if root.is_dir() else [root]:
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in magic:
                continue
        checked += 1
        result = subprocess.run(["xcrun", "nm", "-u", str(path)],
                                capture_output=True, text=True, check=True)
        if imports.search(result.stdout):
            failures.append(str(path))
    if checked == 0:
        raise SystemExit("No Mach-O binaries found; nothing verified")
    if failures:
        raise SystemExit("Unsafe Date >=/<= runtime imports:\n" + "\n".join(failures))
    print(f"PASS: {checked} Mach-O binaries have no Date >=/<= runtime imports")


if __name__ == "__main__":
    main()
