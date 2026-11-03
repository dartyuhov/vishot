#!/usr/bin/env python3
"""Print the content-addressed, uncommitted integration candidate; never write Git."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


ROOT = Path(__file__).resolve().parent.parent
EXCLUDED = (
    ".vishot",
    "docs/site-cli-qa.md",
    "docs/ways-of-work/plan/cli-architecture/module-extraction/implementation-handoff.md",
)
PATHS = ["."] + [f":(top,exclude){path}" for path in EXCLUDED]


def git(*args, data=None):
    return subprocess.check_output(["git", *args], cwd=ROOT, input=data)


def main():
    head = git("rev-parse", "HEAD").decode().strip()
    # Compare HEAD directly with disk, including staged changes; don't detect renames.
    changes = git("diff", "--name-status", "--no-renames", "--no-ext-diff",
                  "--no-textconv", "-z", "HEAD", "--", *PATHS).split(b"\0")[:-1]
    statuses = {os.fsdecode(changes[i + 1]): changes[i].decode()
                for i in range(0, len(changes), 2)}
    for path in git("ls-files", "--others", "--exclude-standard", "-z",
                    "--", *PATHS).split(b"\0")[:-1]:
        statuses[os.fsdecode(path)] = "??"

    records = []
    for path, status in sorted(statuses.items()):
        if status == "D":
            mode, blob = "-", "-"
        else:
            absolute = ROOT / path
            info = absolute.lstat()
            if stat.S_ISLNK(info.st_mode):
                mode = "120000"
                blob = git("hash-object", "--no-filters", "--stdin",
                           data=os.fsencode(os.readlink(absolute))).decode().strip()
            elif stat.S_ISREG(info.st_mode):
                mode = "100755" if info.st_mode & stat.S_IXUSR else "100644"
                blob = git("hash-object", "--no-filters", "--", path).decode().strip()
            else:
                raise ValueError(f"Unsupported candidate file type: {path}")
        records.append([status, mode, blob, path])

    manifest = {"format": "vishot-candidate-v1", "head": head,
                "excluded": list(EXCLUDED), "changes": records}
    encoded = (json.dumps(manifest, ensure_ascii=True, sort_keys=True,
                          separators=(",", ":")) + "\n").encode("ascii")
    print(encoded.decode("ascii"), end="")
    print(f"HEAD={head}")
    print(f"CHANGED_PATHS={len(records)}")
    print(f"MANIFEST_GIT_BLOB={git('hash-object', '--stdin', data=encoded).decode().strip()}")
    print(f"MANIFEST_SHA256={hashlib.sha256(encoded).hexdigest()}")


if __name__ == "__main__":
    main()
