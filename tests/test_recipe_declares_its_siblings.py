#!/usr/bin/env python3
"""Every sibling repository the recipe reads is a declared, locked dependency.

repro.nim compiles the tests against `../reprobuild/libs/ct_test_interface/src`,
so the reprobuild checkout next to this one is an input of the build. A lock
records only the dependencies repro.nim declares in `uses:`. An undeclared
sibling is therefore either missing from repro.lock, or left there as an entry
the push gate refuses as stale. CI binds its `../reprobuild` checkout to the
revision repro.lock pins (ci/locked-sibling-revision.py), so that entry has to
exist and has to be one the recipe accounts for.

The check reads the real repro.nim and repro.lock; nothing is mocked:
* every `../<name>/` path in a string literal of repro.nim (comments
  excluded) names a sibling the recipe reads;
* each such sibling is listed in the package's `uses:` block;
* repro.lock pins each one at exactly one full commit.
"""
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'repro.nim'
LOCK = ROOT / 'repro.lock'

STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
SIBLING_PATH = re.compile(r'(?:^|[^.\w])\.\./([A-Za-z0-9_.-]+)/')
FAILURES = []


def code_lines(text):
    """The recipe's lines with `#` and `##` comments removed."""
    for line in text.splitlines():
        out, in_string = [], False
        for char in line:
            if char == '"':
                in_string = not in_string
            elif char == '#' and not in_string:
                break
            out.append(char)
        yield ''.join(out)


def siblings_read(lines):
    names = set()
    for line in lines:
        for literal in STRING.findall(line):
            names.update(SIBLING_PATH.findall(literal))
    return names


def uses_entries(lines):
    """Quoted entries of the package-level `uses:` block, first word only."""
    entries, block_indent = set(), None
    for line in lines:
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if block_indent is None:
            if line.strip() == 'uses:':
                block_indent = indent
            continue
        if indent <= block_indent:
            block_indent = None
            if line.strip() == 'uses:':
                block_indent = indent
            continue
        for literal in STRING.findall(line):
            entries.add(literal.split()[0])
    return entries


def main():
    lines = list(code_lines(RECIPE.read_text(encoding='utf-8')))
    siblings = siblings_read(lines)
    if not siblings:
        FAILURES.append('repro.nim reads no ../<sibling>/ path; this check no longer applies')
    declared = uses_entries(lines)
    locked = {}
    for dep in tomllib.loads(LOCK.read_text(encoding='utf-8'))['lock'].get('deps', []):
        locked.setdefault(dep['name'], []).append(dep.get('revision', ''))
    for name in sorted(siblings):
        if name not in declared:
            FAILURES.append(f'repro.nim reads ../{name}/ but its uses: block does not declare "{name}"'
                            f' (declared: {sorted(declared)})')
        revisions = locked.get(name, [])
        if len(revisions) != 1 or not re.fullmatch(r'[0-9a-f]{40}', revisions[0]):
            FAILURES.append(f'repro.lock pins {name} at {revisions!r}, not one full commit')
    for failure in FAILURES:
        print('FAIL', failure)
    if FAILURES:
        return 1
    print(f'recipe siblings declared and locked: {sorted(siblings)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
