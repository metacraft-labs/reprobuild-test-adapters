#!/usr/bin/env python3
"""Compile the lock readers CI can run and read the shipping repro.lock.

Two engines read this repository's committed lock in CI:

* the one the workflow pins (`repro-build-pin`) for lanes that cannot install a
  published release and build Repro from source instead (the arm64 lanes: the
  releases ship Linux x86_64, macOS arm64 and Windows x86_64 only);
* the owning locked Linux runtime, built from the ../reprobuild revision this
  repro.lock itself pins.

Both must read the schema the lock is written in. An engine that reads only an
older schema fails every lane with "unsupported lock schema ... (expected
...v2)".

No engine, parser, filesystem or compiler is mocked (so there is no mock to
justify under the workspace rules). The sibling Reprobuild Git object database
supplies exact immutable source revisions; no checkout is moved. Run in the dev
shell with the sibling repository available (a revision the clone lacks is an
error, not a skip). This checks reader compatibility on this host; it does not
claim native bootstrap qualification for other operating systems.
"""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PROBE = '''import std/os
import repro_lock
let text = readFile(paramStr(1))
let solved = parseSolvedGraphLock(text)
let locked = parseLockedDependencies(text)
doAssert solved.packages.len == locked.packages.len
# Both readers are on the build/publication path; neither may accept a
# partial lock silently after a schema migration.
echo "packages=", solved.packages.len, " deps=", locked.deps.len
'''
V2_CONTROL = '''schema = "reprobuild.solved-graph-lock.v2"
[lock]
platform = "amd64-linux"
optimal = false
inputs_digest = "fnv1a64:0123456789abcdef"
variants = []
packages = []
deps = []
'''
SHA = re.compile(r'\b[0-9a-f]{40}\b')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def extract_engine_sources(source, revision, work):
    """Place the engine's `libs` and `flake.lock` for REVISION under WORK."""
    archive = subprocess.check_output(['git', '-C', str(source), 'archive',
                                        revision, 'libs', 'flake.lock'])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        # The archive is `git archive` output of a pinned, immutable
        # Reprobuild revision (not untrusted input). Interpreters whose
        # tarfile predates extraction filters (no `data_filter`) reject
        # the `filter` keyword, so pass it only where it exists.
        if hasattr(tarfile, 'data_filter'):
            tar.extractall(work, filter='data')
        else:
            tar.extractall(work)


def workflow_pins(workflows):
    """Return {workflow name: [engine revision, ...]} from `repro-build-pin`."""
    pins = {}
    for name, text in workflows.items():
        pin = re.search(r'^\s+repro-build-pin:\s*(.+)$', text, re.M)
        if not pin:
            raise AssertionError(f'{name} must declare its Reprobuild source pin')
        pins[name] = sorted(set(SHA.findall(pin.group(1))))
        if not pins[name]:
            raise AssertionError(f'{name}: CI engines must use immutable full source revisions')
    return pins


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reprobuild', type=Path, default=ROOT.parent / 'reprobuild')
    parser.add_argument('--workflow', type=Path, action='append',
                        help='default: every workflow that declares repro-build-pin')
    parser.add_argument('--nim', default='nim')
    args = parser.parse_args()
    paths = args.workflow or [path for path in sorted((ROOT / '.github/workflows').glob('*.yml'))
                              if 'repro-build-pin:' in path.read_text()]
    if not paths:
        raise AssertionError('no workflow declares a Reprobuild source pin')
    workflows = {path.name: path.read_text() for path in paths}
    pins = workflow_pins(workflows)
    if len({tuple(v) for v in pins.values()}) != 1:
        raise AssertionError(f'workflows build different engines: {pins}')
    pinned = next(iter(pins.values()))
    committed = (ROOT / 'repro.lock').read_bytes()
    lock = tomllib.loads(committed.decode())['lock']
    # The owning locked Linux runtime is built from the revision the lock pins
    # for the reprobuild sibling, so that reader is exercised as well.
    locked = [dep['revision'] for dep in lock['deps'] if dep.get('name') == 'reprobuild']
    assert len(locked) == 1 and SHA.fullmatch(locked[0]), f'repro.lock must pin reprobuild once: {locked}'
    revisions = list(dict.fromkeys([*pinned, *locked]))
    expected = f"packages={len(lock['packages'])} deps={len(lock['deps'])}"
    failures = []
    for revision in revisions:
        with tempfile.TemporaryDirectory(prefix='adapters-ci-lock-reader-') as scratch:
            work = Path(scratch)
            extract_engine_sources(args.reprobuild, revision, work)
            (work / 'probe.nim').write_text(PROBE)
            (work / 'v2.lock').write_text(V2_CONTROL)
            (work / 'committed.lock').write_bytes(committed)
            paths = sorted((work / 'libs').glob('*/src'))
            command = [args.nim, 'c', '--hints:off', '--parallelBuild:2',
                        '-d:reproVendoredHash',
                        '--passC:-I' + str(work / 'libs/blake3/src/blake3/vendor'),
                        *('--path:' + str(p) for p in paths),
                        '--out:' + str(work / 'probe'), str(work / 'probe.nim')]
            print(f'Compiling exact CI reader {revision}', flush=True)
            run(*command, cwd=work)
            # A v2 positive control proves the probe and dependencies actually
            # work before attributing the shipping lock failure to its schema.
            control = subprocess.check_output([str(work / 'probe'), str(work / 'v2.lock')], text=True)
            assert control.strip() == 'packages=0 deps=0', control
            current = subprocess.run([str(work / 'probe'), str(work / 'committed.lock')],
                                      capture_output=True, text=True)
            if current.returncode or current.stdout.strip() != expected:
                failures.append(revision)
                print(f'FAIL {revision}: {current.stdout}{current.stderr}', flush=True)
                continue
            print(f'PASS {revision}: {expected}', flush=True)
            if revision not in pinned:
                continue
            # A source-built engine must not be bootstrapped with libraries
            # other than the ones its own flake.lock records. Compare
            # immutable producer identities, not version strings or ancestry.
            engine_lock = json.loads((work / 'flake.lock').read_text())
            inputs = engine_lock['nodes'][engine_lock['root']]['inputs']
            for name, workflow in workflows.items():
                for setting, dependency in [('repro-runquota-pin', 'runquota-src'),
                                            ('repro-io-mon-pin', 'io-mon-src'),
                                            ('repro-stackable-hooks-pin', 'nim-stackable-hooks-src')]:
                    row = re.search(r'^\s+' + setting + r':\s*(.+)$', workflow, re.M)
                    assert row, f'{name} must declare {setting}'
                    supplied = set(SHA.findall(row.group(1)))
                    locked_revision = engine_lock['nodes'][inputs[dependency]]['locked']['rev']
                    assert locked_revision in supplied, (name, revision, setting, locked_revision, supplied)
    assert not failures, f'CI engines cannot read committed lock: {failures}'


if __name__ == '__main__':
    main()
