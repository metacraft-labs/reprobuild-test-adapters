#!/usr/bin/env bash
# Run the consumers of the `repro_test_adapters` contract against THIS
# checkout of it: the downstream lane of reprobuild-test-adapters.
#
# WHY THIS EXISTS
#
#   This package declares the `TestRunner` contract that an adapter library
#   (reprobuild-ct-test-runner) instantiates and that reprobuild recognizes
#   (README "Why a separate package"). Both compile against it, so a change
#   here can break either one. Without this lane a consumer saw a contract
#   change only when it bumped its pin, often months after the change had
#   landed.
#
# WHAT IT RUNS
#
#   reprobuild-ct-test-runner: its own `scripts/run_tests.sh` (what its
#     `just test` runs), in its own flake dev shell, with
#     REPRO_TEST_ADAPTERS_SRC naming this checkout's `src/` and REPROBUILD_SRC
#     the reprobuild checkout (for ct_test_interface, which both the adapter
#     and `generic_test_observations` import). The verdict is the suite's own
#     exit status; the driver also refuses an empty suite.
#
#   reprobuild: the tests and programs whose subject is its use of the
#     contract, in its own flake dev shell, with the flake's
#     `reprobuild-test-adapters-src` and `reprobuild-ct-test-runner-src`
#     inputs overridden to the checkouts under test and REPRO_TEST_ADAPTERS_SRC
#     / REPRO_CT_TEST_RUNNER_SRC exported to them (config.nims reads the
#     variables first):
#       * tests/integration/t_integration_test_runner_interface.nim -- the
#         contract through `repro_dsl_stdlib/interfaces/test_runner`, the
#         re-export every recipe sees;
#       * tests/integration/t_integration_test_runner_adapter_registered.nim
#         -- the ct-test adapter installed into the stdlib build context;
#       * `nim check` of libs/repro_dsl_stdlib/src/repro_dsl_stdlib.nim, the
#         prelude the recipe-interface extractor compiles every recipe
#         against (its active_context imports the contract);
#       * a compile of tools/tap-test-runner/repro_tap_test_runner.nim, the
#         second runner, built on `generic_test_observations` through
#         libs/repro_generic_test_recorder.
#     The M20 test that drives the TAP runner against a live runquotad
#     (t_m20_second_runner_generic_layer) is not run: it needs reprobuild's
#     whole engine and runquota built, which a lane per adapters change
#     cannot afford on the shared pool. The compile above is where the
#     generic-observation contract meets reprobuild's code.
#
# A MISSING CONSUMER OR ENTRY POINT IS AN ERROR, NEVER A SKIP: a lane that
# skipped to green when a consumer moved would test nothing and say it passed.
# A consumer revision that no longer carries a file this driver runs is
# refused by name.
#
# USAGE
#
#   ci/downstream-consumers.sh [--adapters DIR] [--ct-test-runner DIR]
#                              [--reprobuild DIR]
#                              [--only ct-test-runner|reprobuild]
#
#   Defaults: --adapters is this script's checkout; each consumer defaults to
#   a sibling of it (`<adapters>/../<repo name>`). NIM_DOWNSTREAM_FLAGS adds
#   flags to the compiles this driver runs itself (for example
#   `--parallelBuild:4` on a shared host).
#
#   The last line is `TEST-COUNTS: …`. The exit status is non-zero when any
#   consumer fails, when a consumer or entry point is missing, or when a suite
#   ran no test.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
adapters="$(cd "${script_dir}/.." && pwd)"
ct_dir=""
rb_dir=""
only=""

die() {
  echo "downstream: error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adapters) adapters="${2:?--adapters needs a directory}"; shift 2 ;;
    --ct-test-runner) ct_dir="${2:?--ct-test-runner needs a directory}"; shift 2 ;;
    --reprobuild) rb_dir="${2:?--reprobuild needs a directory}"; shift 2 ;;
    --only) only="${2:?--only needs a consumer}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "${only}" in
  ""|ct-test-runner|reprobuild) ;;
  *) die "--only takes ct-test-runner or reprobuild, not '${only}'" ;;
esac

[[ -d "${adapters}" ]] || die "adapters checkout '${adapters}' does not exist"
adapters="$(cd "${adapters}" && pwd)"
[[ -n "${ct_dir}" ]] || ct_dir="${adapters}/../reprobuild-ct-test-runner"
[[ -n "${rb_dir}" ]] || rb_dir="${adapters}/../reprobuild"

# The contract this lane exists to test. An adapters tree without it is not
# the package; the consumers would silently resolve some other copy.
[[ -f "${adapters}/src/repro_test_adapters/test_runner.nim" ]] ||
  die "'${adapters}' is not a reprobuild-test-adapters checkout (no src/repro_test_adapters/test_runner.nim)"

# Each consumer must be a checkout carrying every entry point named here.
require_consumer() {
  local name="$1" dir="$2"
  shift 2
  [[ -d "${dir}" ]] ||
    die "${name} checkout '${dir}' does not exist; clone it beside the adapters checkout or pass --${name}"
  local rel
  for rel in "$@"; do
    [[ -e "${dir}/${rel}" ]] ||
      die "${name} at $(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo '?') has no ${rel}, which this lane runs; update ci/downstream-consumers.sh to the consumer's current layout"
  done
}

nim_extra=()
if [[ -n "${NIM_DOWNSTREAM_FLAGS:-}" ]]; then
  read -r -a nim_extra <<<"${NIM_DOWNSTREAM_FLAGS}"
fi

# rb_dir is needed by both consumers (ct_test_interface lives in it).
require_consumer reprobuild "${rb_dir}" libs/ct_test_interface/src
rb_dir="$(cd "${rb_dir}" && pwd)"

describe() {
  local dir="$1"
  printf '%s' "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || echo 'not a git checkout')"
  if [[ -n "$(git -C "${dir}" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    printf ' (with uncommitted changes)'
  fi
}

echo "downstream: adapters under test: ${adapters} @ $(describe "${adapters}")"

passed_suites=0
failed_suites=0
failed_names=()

record() {
  local label="$1" rc="$2"
  if [[ "${rc}" -eq 0 ]]; then
    passed_suites=$((passed_suites + 1))
    echo "downstream: PASS ${label}"
  else
    failed_suites=$((failed_suites + 1))
    failed_names+=("${label}")
    echo "downstream: FAIL ${label} (exit ${rc})"
  fi
}

# ---------------------------------------------------------------------------
# reprobuild-ct-test-runner
# ---------------------------------------------------------------------------
run_ct_test_runner() {
  require_consumer ct-test-runner "${ct_dir}" flake.nix scripts/run_tests.sh \
    libs/ct_test_runner_adapter/src/ct_test_runner_adapter.nim
  ct_dir="$(cd "${ct_dir}" && pwd)"
  echo "downstream: reprobuild-ct-test-runner @ $(describe "${ct_dir}")"

  # The same selection scripts/run_tests.sh makes. It exits 0 on an empty
  # selection ("no Nim tests found"), which here would be a lane that tests
  # nothing, so the driver counts first and refuses zero.
  local count
  count="$(cd "${ct_dir}" && { find tests libs -path '*/tests/t_*.nim' -type f 2>/dev/null; find tests -name 't_*.nim' -type f 2>/dev/null; } | wc -l)"
  if [[ "${count}" -eq 0 ]]; then
    die "reprobuild-ct-test-runner at $(describe "${ct_dir}") has no t_*.nim test programs"
  fi
  echo "downstream: reprobuild-ct-test-runner: ${count} test programs"
  ct_programs="${count}"

  # run_tests.sh compiles with `nim c -r` into build/nimcache/<test> and
  # build/test-bin/<test>. `nim c -r` skips the compile and reruns the old
  # binary when the command line and the modules recorded in that nimcache are
  # unchanged, and the contract's directory comes from the environment
  # (config.nims), not from the command line. A test binary left by a run
  # against another adapters tree would therefore be rerun without compiling
  # against this one. Remove the suite's build outputs so every test program
  # is compiled against the contract under test.
  rm -rf "${ct_dir}/build/nimcache" "${ct_dir}/build/test-bin"

  local rc=0
  (
    cd "${ct_dir}"
    nix develop --no-update-lock-file . --command \
      env REPRO_TEST_ADAPTERS_SRC="${adapters}/src" REPROBUILD_SRC="${rb_dir}" \
      bash scripts/run_tests.sh
  ) || rc=$?
  record "reprobuild-ct-test-runner scripts/run_tests.sh" "${rc}"
}

# ---------------------------------------------------------------------------
# reprobuild
# ---------------------------------------------------------------------------
rb_tests=(
  tests/integration/t_integration_test_runner_interface.nim
  tests/integration/t_integration_test_runner_adapter_registered.nim
)
rb_check=libs/repro_dsl_stdlib/src/repro_dsl_stdlib.nim
rb_compile=tools/tap-test-runner/repro_tap_test_runner.nim

run_reprobuild() {
  # The adapter-registered test imports ct_test_runner_install, which needs
  # the adapter: reprobuild compiles against the ct-test-runner checkout too.
  require_consumer ct-test-runner "${ct_dir}" libs/ct_test_runner_adapter/src/ct_test_runner_adapter.nim
  ct_dir="$(cd "${ct_dir}" && pwd)"
  require_consumer reprobuild "${rb_dir}" flake.nix "${rb_tests[@]}" "${rb_check}" "${rb_compile}"
  echo "downstream: reprobuild @ $(describe "${rb_dir}")"

  local out
  out="$(mktemp -d "${TMPDIR:-/tmp}/adapters-downstream-reprobuild.XXXXXX")"
  # One dev-shell entry runs every step; each step reports its own verdict on
  # a `downstream-step:` line, which the driver turns into suite results.
  local log="${out}/steps.log"
  local rc=0
  (
    cd "${rb_dir}"
    nix develop --no-update-lock-file . \
      --override-input reprobuild-test-adapters-src "path:${adapters}" \
      --override-input reprobuild-ct-test-runner-src "path:${ct_dir}" \
      --command env \
        REPRO_TEST_ADAPTERS_SRC="${adapters}/src" \
        REPRO_CT_TEST_RUNNER_SRC="${ct_dir}" \
        DOWNSTREAM_OUT="${out}" \
        bash -c '
          set -u
          flags=(--threads:on --hints:off --warnings:off "${@:3}")
          step() { local label="$1"; shift; local rc=0; "$@" || rc=$?; echo "downstream-step: ${rc} ${label}"; }
          for t in $1; do
            n="$(basename "$t" .nim)"
            step "reprobuild $t" nim c -r "${flags[@]}" \
              --nimcache:"$DOWNSTREAM_OUT/nimcache/$n" --out:"$DOWNSTREAM_OUT/bin/$n" "$t"
          done
          step "reprobuild nim check $2" nim check "${flags[@]}" \
            --nimcache:"$DOWNSTREAM_OUT/nimcache/dsl_stdlib_check" "$2"
          step "reprobuild nim c ${DOWNSTREAM_COMPILE}" nim c "${flags[@]}" \
            --nimcache:"$DOWNSTREAM_OUT/nimcache/tap" --out:"$DOWNSTREAM_OUT/bin/repro_tap_test_runner" \
            "${DOWNSTREAM_COMPILE}"
        ' _ "${rb_tests[*]}" "${rb_check}" ${nim_extra[@]+"${nim_extra[@]}"}
  ) 2>&1 | tee "${log}" || rc=$?

  local seen=0 line step_rc label
  while IFS= read -r line; do
    step_rc="${line#downstream-step: }"
    label="${step_rc#* }"
    step_rc="${step_rc%% *}"
    seen=$((seen + 1))
    record "${label}" "${step_rc}"
  done < <(grep '^downstream-step: ' "${log}" || true)
  local expected=$(( ${#rb_tests[@]} + 2 ))
  if [[ "${seen}" -ne "${expected}" ]]; then
    # The dev shell failed to start, or the inner script died early: every
    # step that reported nothing is a failure, never a skip.
    record "reprobuild: ${expected} steps expected, ${seen} reported (dev shell exit ${rc})" 1
  fi
  rm -rf "${out}"
}

ct_programs=0
export DOWNSTREAM_COMPILE="${rb_compile}"
if [[ -z "${only}" || "${only}" == ct-test-runner ]]; then
  run_ct_test_runner
fi
if [[ -z "${only}" || "${only}" == reprobuild ]]; then
  run_reprobuild
fi

total=$((passed_suites + failed_suites))
if [[ "${failed_suites}" -gt 0 ]]; then
  echo "downstream: failed:"
  printf '  %s\n' "${failed_names[@]}"
fi
echo "TEST-COUNTS: suites=${total} passed=${passed_suites} failed=${failed_suites} ct-test-runner-programs=${ct_programs}"
if [[ "${total}" -eq 0 ]]; then
  echo "downstream: error: no consumer suite ran" >&2
  exit 1
fi
[[ "${failed_suites}" -eq 0 ]]
