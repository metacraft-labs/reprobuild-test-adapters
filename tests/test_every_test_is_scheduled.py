#!/usr/bin/env python3
"""Every file under tests/ is run by CI.

A test nothing runs protects nothing: `tests/test_locked_sibling_revision.sh`
covered the script that gates every Linux CI run and was itself run by no
workflow, and `tests/test_dev_shell_writes_nothing_elsewhere.sh` likewise. The
metacraft CI-test-coverage ground rule allows a manual-only test only when it
needs hardware CI lacks and this repository's documentation says so; neither
applies to any test here, so this check admits no manual-only list.

A test counts as scheduled when it is

* the `source:` of an `AdapterTestSpec` in repro.nim (`repro test` runs it), or
* named in the shell command of a `run:` step of a workflow under
  .github/workflows/. A mention in a comment, a step `name:` or an `env:`
  value does not count: only the command a step executes. Nor does a step
  that cannot fail the job: one whose `if:` is literally false, or whose
  `continue-on-error:` is anything but `false`.

The workflow reader is line-based because the CI Python has no YAML library.
`self_check()` runs it over a sample of each case above before it reads the
real workflows, so a reader that miscounts fails this test instead of passing
it.

The check reads the real repository files; nothing is mocked.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
RECIPE = ROOT / 'repro.nim'
WORKFLOWS = ROOT / '.github' / 'workflows'

RUN_KEY = re.compile(r'^(?P<indent>\s*)(?P<dash>-\s+)?run:\s*(?P<rest>.*)$')
STEP_KEY = re.compile(r'^(?P<lead>\s*(?:-\s+)?)(?P<key>[\w-]+):\s*(?P<rest>.*)$')
SPEC_SOURCE = re.compile(r'AdapterTestSpec\(\s*source:\s*"([^"]+)"')


def indent_of(line):
    return len(line) - len(line.lstrip())


def is_yaml_structure(line):
    """A line that is neither blank nor a comment."""
    return bool(line.strip()) and not line.lstrip().startswith('#')


def scalar(rest):
    """An inline YAML value without a trailing comment, quotes or `${{ }}`."""
    value = re.sub(r'\s+#.*$', '', rest).strip()
    value = value.strip('\'"').strip()
    match = re.fullmatch(r'\$\{\{\s*(.*?)\s*\}\}', value)
    return (match[1] if match else value).strip('\'"').strip().lower()


def step_gates(lines, run_index, key_indent):
    """Whether the step holding the `run:` key at `run_index` can fail its job.

    The step is the sequence item whose keys sit at `key_indent`: it starts at
    the line where `- ` puts a key in that column and ends at the next
    structural line indented less than that column.
    """
    start = run_index
    while start >= 0:
        line = lines[start]
        match = STEP_KEY.match(line)
        if match and '-' in match['lead'] and len(match['lead']) == key_indent:
            break
        if is_yaml_structure(line) and indent_of(line) < key_indent:
            return True  # not inside a step list; nothing to disqualify it
        start -= 1
    if start < 0:
        return True
    end = start + 1
    while end < len(lines) and not (is_yaml_structure(lines[end])
                                    and indent_of(lines[end]) < key_indent):
        end += 1
    for line in lines[start:end]:
        match = STEP_KEY.match(line)
        if not match or len(match['lead']) != key_indent:
            continue
        if match['key'] == 'if' and scalar(match['rest']) == 'false':
            return False
        if match['key'] == 'continue-on-error' and scalar(match['rest']) != 'false':
            return False
    return True


def run_commands(text):
    """The shell text of every `run:` step that can fail its job.

    A block scalar (`run: |` / `run: >`, with optional chomping indicator) is
    every following line indented deeper than the `run:` key, blank lines
    included. Lines that are YAML comments inside a block scalar are part of
    the script, so shell comments are removed separately below.
    """
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        match = RUN_KEY.match(lines[i])
        run_index = i
        i += 1
        if not match:
            continue
        key_indent = len(match['indent']) + len(match['dash'] or '')
        rest = match['rest'].strip()
        if rest and rest[0] in '|>':
            block = []
            while i < len(lines):
                line = lines[i]
                if line.strip() and indent_of(line) <= key_indent:
                    break
                block.append(line)
                i += 1
            command = '\n'.join(block)
        elif rest and not rest.startswith('#'):
            command = rest
        else:
            continue
        if step_gates(lines, run_index, key_indent):
            yield command


def without_shell_comments(script):
    """Drops whole-line shell comments; a path in one is not a command."""
    return '\n'.join(line for line in script.splitlines()
                     if not line.lstrip().startswith('#'))


SELF_CHECK_WORKFLOW = """\
jobs:
  j:
    steps:
      # run: bash tests/in-a-yaml-comment.sh
      - name: bash tests/in-a-step-name.sh
        env:
          X: bash tests/in-an-env-value.sh
        run: |
          # bash tests/in-a-shell-comment.sh
          bash tests/block-counts.sh
      - run: bash tests/inline-counts.sh
      - name: disabled
        if: false
        run: bash tests/if-false.sh
      - name: disabled by expression
        if: ${{ false }}
        run: bash tests/if-expression-false.sh
      - name: cannot fail
        run: bash tests/continue-on-error.sh
        continue-on-error: true
      - name: may fail
        continue-on-error: false
        if: matrix.os == 'linux'
        run: >-
          bash tests/folded-counts.sh
"""


def self_check():
    """Fails unless the reader counts exactly the steps that gate the job."""
    found = set()
    for command in run_commands(SELF_CHECK_WORKFLOW):
        found.update(re.findall(r'tests/[\w-]+\.sh',
                                without_shell_comments(command)))
    expected = {'tests/block-counts.sh', 'tests/inline-counts.sh',
                'tests/folded-counts.sh'}
    if found != expected:
        print(f'FAIL: the workflow reader found {sorted(found)} in its '
              f'self-check sample, expected {sorted(expected)}', file=sys.stderr)
        return False
    return True


def main():
    if not self_check():
        return 1
    tests = sorted(p.relative_to(ROOT).as_posix()
                   for p in TESTS.iterdir() if p.is_file())
    if not tests:
        print('FAIL: tests/ holds no files', file=sys.stderr)
        return 1

    scheduled = {}
    # A commented-out spec is not run by `repro test`.
    recipe = '\n'.join(line for line in RECIPE.read_text().splitlines()
                        if not line.lstrip().startswith('#'))
    for source in SPEC_SOURCE.findall(recipe):
        scheduled.setdefault(source, []).append('repro.nim AdapterTestSpec')
    workflows = sorted(WORKFLOWS.glob('*.yml')) + sorted(WORKFLOWS.glob('*.yaml'))
    if not workflows:
        print(f'FAIL: no workflow under {WORKFLOWS}', file=sys.stderr)
        return 1
    for workflow in workflows:
        for command in run_commands(workflow.read_text()):
            command = without_shell_comments(command)
            for test in tests:
                if re.search(r'(?<![\w./-])' + re.escape(test) + r'(?![\w.-])', command):
                    scheduled.setdefault(test, []).append(workflow.name)

    unscheduled = [t for t in tests if t not in scheduled]
    for test in tests:
        where = ', '.join(sorted(set(scheduled.get(test, [])))) or 'NOTHING'
        print(f'{"ok  " if test in scheduled else "FAIL"} {test}: run by {where}')
    if unscheduled:
        print(f'FAIL: {len(unscheduled)} test file(s) are run by no workflow step '
              'and no repro.nim AdapterTestSpec: ' + ', '.join(unscheduled),
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
