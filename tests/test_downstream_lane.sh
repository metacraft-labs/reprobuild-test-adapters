#!/usr/bin/env bash
# The downstream lane exists, and it tests the consumers against the contract
# under test rather than some other copy of it.
#
# Until the lane existed, no CI job ran the two repositories that compile
# against `repro_test_adapters` against a change to it, so a contract change
# reached them only when they bumped a pin. This test holds both halves of the
# lane:
#
#   1. WIRING. .github/workflows/ci-reprobuild.yml has a `downstream` job that
#      runs on pull requests, clones both consumers, and runs
#      ci/downstream-consumers.sh and this test.
#   2. MUTATION CONTROL. A copy of this checkout whose `TestRunner` contract is
#      broken (`newTestRunner`, which both consumers call, renamed) is handed
#      to the driver once per consumer. Each run must fail, and its log must
#      show the compiler failing on the rename, which only the BROKEN copy has. A lane that resolved the
#      contract from a flake input, a store path or a sibling `../`
#      checkout instead would pass here, and so would one that ran nothing.
#
# Nothing is mocked: the consumers are real checkouts, built in their own dev
# shells by the real driver. They default to siblings of this checkout
# (`../reprobuild-ct-test-runner`, `../reprobuild`); DOWNSTREAM_CT_TEST_RUNNER
# and DOWNSTREAM_REPROBUILD name others. `--wiring-only` runs half 1 alone,
# which needs no consumer.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${root}/.github/workflows/ci-reprobuild.yml"
driver="${root}/ci/downstream-consumers.sh"
wiring_only=0
[[ "${1:-}" == --wiring-only ]] && wiring_only=1

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

echo "downstream-lane: [1] the workflow runs the lane on pull requests"
[[ -x "${driver}" ]] && pass "ci/downstream-consumers.sh exists and is executable" ||
  fail "ci/downstream-consumers.sh is missing or not executable"

# The workflow's `on:` block (top-level, up to the next top-level key).
on_block="$(awk '/^on:/{f=1; next} f && /^[^[:space:]#]/{exit} f' "${workflow}")"
grep -Eq '^[[:space:]]+pull_request:' <<<"${on_block}" &&
  pass "the workflow triggers on pull_request" ||
  fail "the workflow does not trigger on pull_request"

# The `downstream` job's body: from its key to the next job key at the same
# two-space indent.
job="$(awk '/^  downstream:/{f=1; print; next} f && /^  [A-Za-z0-9_-]+:/{exit} f' "${workflow}")"
if [[ -z "${job}" ]]; then
  fail "the workflow has no 'downstream' job"
else
  pass "the workflow has a 'downstream' job"
  grep -Eq '^[[:space:]]+if:' <<<"$(awk '/^  downstream:/{f=1; next} f && /^    steps:/{exit} f' "${workflow}")" &&
    fail "the downstream job is conditional (a job-level 'if:'), so it can skip to green" ||
    pass "the downstream job has no job-level condition"
  grep -q 'continue-on-error' <<<"${job}" &&
    fail "the downstream job uses continue-on-error, so it cannot fail CI" ||
    pass "the downstream job can fail CI"
  for repo in reprobuild-ct-test-runner reprobuild; do
    grep -Eq "for repo in .*\\b${repo}\\b" <<<"${job}" &&
      pass "the downstream job clones ${repo}" ||
      fail "the downstream job does not clone ${repo}"
  done
  grep -Eq '^[[:space:]]+run: bash ci/downstream-consumers\.sh[[:space:]]*$' <<<"${job}" &&
    pass "the downstream job runs ci/downstream-consumers.sh over every consumer" ||
    fail "the downstream job does not run 'bash ci/downstream-consumers.sh' (all consumers)"
  grep -Eq '^[[:space:]]+run: bash tests/test_downstream_lane\.sh[[:space:]]*$' <<<"${job}" &&
    pass "the downstream job runs this mutation control" ||
    fail "the downstream job does not run 'bash tests/test_downstream_lane.sh'"
fi

if [[ "${wiring_only}" -eq 1 || "${failures}" -gt 0 ]]; then
  if [[ "${failures}" -gt 0 ]]; then
    echo "downstream-lane: FAIL (${failures})"
    exit 1
  fi
  echo "downstream-lane: PASS (wiring only)"
  exit 0
fi

echo "downstream-lane: [2] each consumer fails on a broken contract, reading the broken copy"
ct_dir="${DOWNSTREAM_CT_TEST_RUNNER:-${root}/../reprobuild-ct-test-runner}"
rb_dir="${DOWNSTREAM_REPROBUILD:-${root}/../reprobuild}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/adapters-downstream-lane.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
broken="${scratch}/broken-adapters"
mkdir -p "${broken}"
# The tracked and the untracked-but-not-ignored files: the tree under test.
(cd "${root}" && git ls-files -z -co --exclude-standard | xargs -0 cp --parents -t "${broken}")
contract="${broken}/src/repro_test_adapters/test_runner.nim"
mutant=newTestRunnerRenamedByTheDownstreamLaneTest
grep -q '^proc newTestRunner\*(' "${contract}" ||
  { fail "the contract no longer declares 'proc newTestRunner*(' to mutate; update this test"; exit 1; }
# Callers inside the package follow the rename, so the package itself still
# compiles and the breakage is the consumers' alone: they call newTestRunner,
# which the broken copy no longer has.
while IFS= read -r -d '' f; do
  sed -i -E "s/\\bnewTestRunner\\b/${mutant}/g" "${f}"
done < <(find "${broken}/src" -name '*.nim' -print0)
grep -rqw newTestRunner "${broken}/src" &&
  { fail "the mutation left a newTestRunner reference in the package"; exit 1; }
grep -q "^proc ${mutant}\\*(" "${contract}" ||
  { fail "the mutation did not rename the declaration"; exit 1; }

for consumer in ct-test-runner reprobuild; do
  log="${scratch}/${consumer}.log"
  rc=0
  bash "${driver}" --adapters "${broken}" --ct-test-runner "${ct_dir}" \
    --reprobuild "${rb_dir}" --only "${consumer}" >"${log}" 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    fail "${consumer}: the lane PASSED against a contract without newTestRunner"
    tail -20 "${log}" | sed 's/^/        /'
    continue
  fi
  if [[ "${rc}" -eq 2 ]]; then
    fail "${consumer}: the driver refused to run (exit 2), so the mutation was never compiled"
    tail -20 "${log}" | sed 's/^/        /'
    continue
  fi
  pass "${consumer}: the lane fails (exit ${rc})"
  # The failure has to be the mutation's. Every other copy of the contract
  # (the flake input, a store path, a sibling checkout) declares
  # newTestRunner, so an undeclared newTestRunner is the compiler reading the
  # broken copy, and nothing else.
  if grep -q "undeclared identifier: 'newTestRunner'" "${log}"; then
    pass "${consumer}: it fails because newTestRunner is undeclared"
  else
    fail "${consumer}: it failed, but not on the undeclared newTestRunner"
    grep -E 'Error|FAIL' "${log}" | head -10 | sed 's/^/        /'
  fi
  if grep -q "^downstream: adapters under test: ${broken} " "${log}"; then
    pass "${consumer}: the driver named the broken copy as the tree under test"
  else
    fail "${consumer}: the driver did not name ${broken} as the tree under test"
  fi
done

if [[ "${failures}" -gt 0 ]]; then
  echo "downstream-lane: FAIL (${failures})"
  exit 1
fi
echo "downstream-lane: PASS"
