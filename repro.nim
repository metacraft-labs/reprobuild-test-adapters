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
## **Module search path.** This repo ships NO ``config.nims`` / ``nim.cfg``
## / ``Justfile`` — its ``nimble`` file only sets ``srcDir = "src"`` and
## ``requires "nim >= 2.2.0"``. The single test does ``import
## repro_test_adapters``, which resolves only when ``src`` is on the module
## search path, so the BUILD edge passes ``paths = @["src"]`` explicitly
## (the ``--path:src`` a ``nimble test`` would supply from ``srcDir``).
## ``src`` is added to ``extraInputs`` so the whole library tree
## (``src/repro_test_adapters.nim`` + ``src/repro_test_adapters/``) is a
## declared input of the compile. No ``-d:release`` / ``--mm`` override is
## warranted: the repo has no matrix Justfile pinning a memory manager, so
## the edge uses the wrapper's defaults (matching what a bare ``nim c -r``
## on the test file would do).
##
## **Per-test platform gating.** There is exactly ONE test file,
## ``tests/test_runner_test.nim``. Its imports are ``std/[os, unittest]`` +
## ``repro_test_adapters`` — no OS-only import, no ``{.error.}`` module
## guard, no ``when not defined(<os>): quit`` head-guard. Every ``check``
## exercises portable stdlib string / path logic (the direct-binary
## default runner's basename synthesis, the ``validate`` vtable-completeness
## asserts). It compiles and runs to exit 0 on every host, so its edge is
## unconditionally in the graph — no ``when defined(...)`` extraction gate
## is needed. No pty/subprocess is spawned (``run`` is never actually
## invoked against a real binary in the tests — only the empty-path
## ``-1`` branch is checked), so no serialising ``pool`` is warranted
## either.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl

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
  # The sole test file — portable stdlib contract tests for the
  # ``TestRunner`` vtable + the direct-binary default runner. No OS gate;
  # compiles + runs to exit 0 on every host.
  AdapterTestSpec(source: "tests/test_runner_test.nim",
    binary: "build/test-bin/test_runner_test"),
]

package repro_test_adapters:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles the test binary (the ``buildNimUnittest.build`` edge
    # below), matching the nimble file's ``requires "nim >= 2.2.0"``;
    # ``gcc`` is the C back-end ``nim c`` shells out to. Sufficient for the
    # path-mode resolver under ``nix develop``.
    "nim >=2.2 <3.0"
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
    # ``paths = @["src"]`` supplies ``--path:src`` (the repo has no
    # ``config.nims``; the test's ``import repro_test_adapters`` needs it).
    # ``src`` is an ``extraInput`` so the whole library tree is a declared
    # input of the compile.
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
        paths = @["src"],
        extraInputs = @["src"],
        actionId = "repro_test_adapters.test_build." & stem)
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
