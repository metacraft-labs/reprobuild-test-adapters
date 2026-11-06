#!/usr/bin/env python3
"""Print the revision a committed repro.lock pins for one sibling repository.

CI clones each sibling at the revision the triggering commit's own repro.lock
names, so a workflow that needs that revision reads it here rather than keeping
a copy that goes stale at the next re-pin.

Usage: locked-sibling-revision.py <repro.lock> <sibling-name>

Exit status 0 prints the full commit id. Anything else writes the reason to
stderr and prints nothing: an absent or ambiguous entry, a revision that is not
a commit id (a branch name would select whatever that branch points at when the
job runs), or an integrity field naming a different commit. The last two are
the checks clone-siblings applies to the same entry.
"""
import re
import sys
import tomllib


def locked_revision(lock_path: str, name: str) -> str:
    with open(lock_path, "rb") as lock_file:
        lock = tomllib.load(lock_file)
    entries = [
        dep
        for dep in lock.get("lock", {}).get("deps", [])
        if dep.get("name") == name and dep.get("self") != "true"
    ]
    if len(entries) != 1:
        raise ValueError(f"expected one sibling entry for '{name}', found {len(entries)}")
    revision = entries[0].get("revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
        raise ValueError(f"'{name}' records revision '{revision}', which is not a commit id")
    integrity = entries[0].get("integrity", "")
    if integrity.startswith("git-sha") and integrity.partition(":")[2] != revision:
        raise ValueError(f"'{name}' records revision {revision} but integrity {integrity}")
    return revision


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        print(locked_revision(argv[1], argv[2]))
    except (OSError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"{argv[1]}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
