## Reprobuild project file for reprobuild-test-adapters.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** This is a pure-Nim,
## dependency-free leaf library — the ``repro_test_adapters`` package that
## declares the ``TestRunner`` cross-cutting contract (the vtable-style
## record an adapter library instantiates and a reprobuild project
## recognizes). Its whole reason for existing is to depend on nothing but
## the Nim standard library (``import std/[os, strutils]``) so the adapter
## and its consumer can share one type definition with no dependency cycle
## through the reprobuild engine (see ``README.md``). It therefore has NO
## in-scope sibling build dependency, and the ``uses:`` block is just the
## toolchain floor — there is no ``uses: "<sibling>"`` edge.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``codetracer-trace-format-nim/repro.nim``
## / ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the upstream tool floor via ``uses:`` so consumers that
##   depend on this repo (via ``uses: "repro_test_adapters"``) pick up the
##   same toolchain the nimble file's ``requires "nim >= 2.2.0"`` implies.
## * Declares ``library repro_test_adapters`` so consumers — the reprobuild
##   engine and out-of-tree adapter libraries such as
##   ``reprobuild-ct-test-runner`` — can express a workspace dependency on
##   this repo. The importable umbrella is ``src/repro_test_adapters.nim``
##   (it re-exports ``repro_test_adapters/test_runner``); consumers
##   ``import repro_test_adapters``.
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template", exactly as reprobuild's own ``repro.nim`` does
##   it. The BUILD halves collect into ``test-builds`` and the EXECUTE
##   halves into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure (the execute edge transitively
##   depends on its build edge).
##
## **Module search path and complete corpus.** The owning config.nims
## resolves ct_test_interface's shared source-leaf contract from the adjacent
## reprobuild checkout. Both shipped portable modules are registered below:
## the original TestRunner contract and M20 generic declaration/TAP corpus.
## Source, config.nims and the real adjacent source-leaf tree are declared
## compile inputs; neither constants nor runner results are copied or mocked.
## Every existing assertion executes on every supported platform.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl
import repro_dsl_stdlib/foreign_env

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by the test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edge. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the ``nim-stackable-hooks`` /
# ``nim-pty`` leaf recipes, this file does NOT import
# ``ct_test_runner_install`` (engine-coupled, reprobuild-internal): the
# execute edge routes through the engine's default direct-binary runner
# (run the binary, key on exit status), which is exactly the exit-0
# verification this corpus needs — Nim ``unittest`` prints per-suite results
# and exits non-zero on failure.
import ct_test_nim_unittest

type
  AdapterTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

const adapterTestSpecs: seq[AdapterTestSpec] = @[
  # The original portable contract test for the
  # ``TestRunner`` vtable + the direct-binary default runner. No OS gate;
  # compiles + runs to exit 0 on every host.
  AdapterTestSpec(source: "tests/test_runner_test.nim",
    binary: "build/test-bin/test_runner_test"),
  AdapterTestSpec(source: "tests/generic_test_observations_test.nim",
    binary: "build/test-bin/generic_test_observations_test"),
]

package repro_test_adapters:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles the test binary (the ``buildNimUnittest.build`` edge
    # below), matching the nimble file's ``requires "nim >= 2.2.0"``;
    # ``gcc`` is the C back-end ``nim c`` shells out to. Sufficient for the
    # path-mode resolver under ``nix develop``.
    "nim >=2.2 <3.0"
    when defined(macosx):
      "clang >=14"
    else:
      "gcc >=12"

  # Library declaration — the ``src/`` tree (``srcDir = "src"``) is
  # importable when this package is consumed via
  # ``uses: "repro_test_adapters"``. The umbrella is
  # ``src/repro_test_adapters.nim`` (it re-exports
  # ``repro_test_adapters/test_runner``); consumers
  # ``import repro_test_adapters``.
  library repro_test_adapters

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per test file. The BUILD half
    # collects into ``test-builds`` (compile verification); the EXECUTE half
    # into ``test`` so ``repro test`` / ``repro build test`` materialise the
    # runnable closure (the execute edge transitively depends on its build
    # edge).
    #
    # Own source/config and the actual shared source-leaf contract are
    # inputs of both compile actions; imports retain the owning constants.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = @["src", "../reprobuild/libs/ct_test_interface/src"],
        extraInputs = @["src", "config.nims", "../reprobuild/libs/ct_test_interface/src"],
        actionId = "repro_test_adapters.test_build." & stem)
      when defined(macosx):
        appendRegisteredActionToolIdentityRefs(edge.action.id, @["clang"])
      else:
        appendRegisteredActionToolIdentityRefs(edge.action.id, @["gcc"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "repro_test_adapters.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in adapterTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
