## ``TestRunner`` cross-cutting contract — the shared types a test-runner
## adapter library instantiates and its reprobuild consumer recognizes.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`TestRunner`", this module *declares* the contract that test-runner
## adapter packages satisfy. The interface is expressed as a
## vtable-style record of ``proc`` fields (per Package-Model §"The
## framework-recognition interface lives outside reprobuild") so a
## ``TestRunner`` value can be constructed by any adapter package
## without recompiling its consumers.
##
## This contract lives in the standalone ``repro_test_adapters`` package
## (depended on by both the reprobuild engine and out-of-tree adapter
## libraries such as ``reprobuild-ct-test-runner``) precisely so the
## adapter and its consumer share one definition of these types without
## a dependency cycle through the reprobuild engine. The contract is
## ``import std/[os, strutils]`` only — it carries no engine dependency.
##
## Recipes consume ``TestRunner`` through the active build context:
## ``currentBuildContext().testRunner.run(...)`` — they never construct
## one. The stdlib supplies a sequential-invocation default
## (``defaultTestRunner``) that runs the binary as-is; framework-aware
## adapters replace it via the variant-conditioned ``uses:`` mechanism.

import std/[os, strutils]

type
  TestBinary* = object
    ## The path to a built test binary plus an optional adapter-specific
    ## metadata blob. Adapters that need richer per-binary metadata
    ## carry it in ``metadata`` (a string-keyed bag); the default
    ## runner ignores it.
    path*: string
    metadata*: string

  TestCase* = object
    ## A single case the runner can address. ``qualifiedName`` is the
    ## adapter-defined fully qualified identifier (suite path + case
    ## name); ``displayName`` is what a human-facing log line shows.
    qualifiedName*: string
    displayName*: string

  QualifiedName* = string
    ## Alias for the canonical case identifier the runner enumerates.

  ExitCode* = int
    ## Mirrors a Unix-style process exit code: 0 on success, non-zero
    ## on failure. The stdlib's default runner forwards the binary's
    ## native exit code verbatim.

  TestRunner* = ref object of RootObj
    ## Vtable for a test-runner adapter. The interface is intentionally
    ## stored as a ``ref object`` (inheriting ``RootObj``) so the
    ## ``PackageBuildState`` slots can hold the value as a ``RootRef``
    ## per the M3 layering described in
    ## ``runtime_core.nim`` §"M3 — cross-cutting interface slots".
    name*: string
      ## Adapter identity, e.g. ``"default-test-runner"`` or
      ## ``"ct-test-runner"``.
    run*: proc(binary: TestBinary; filter: string): ExitCode
      ## Run the binary, optionally filtered by adapter-defined
      ## ``filter`` string (mapped to the framework's ``-k`` / ``--run``
      ## equivalent). Returns the process exit code.
    list*: proc(binary: TestBinary): seq[TestCase]
      ## Enumerate every test case the binary knows about with both
      ## the qualified name and the human-facing display name.
    enumerate*: proc(binary: TestBinary): seq[QualifiedName]
      ## Return the qualified names only — the cheaper form recipes
      ## consume when they only need to address cases, not display
      ## them.

proc newTestRunner*(
    name: string;
    run: proc(binary: TestBinary; filter: string): ExitCode;
    list: proc(binary: TestBinary): seq[TestCase];
    enumerate: proc(binary: TestBinary): seq[QualifiedName]
    ): TestRunner =
  ## Builder for a fully populated ``TestRunner``. Adapter packages
  ## invoke this rather than constructing the object literally so that
  ## additive vtable extensions in later milestones (``runBatch``,
  ## ``supportsPartition``) don't break existing constructor sites at
  ## the spec's "additive only within a major version" guarantee.
  TestRunner(
    name: name,
    run: run,
    list: list,
    enumerate: enumerate)

proc validate*(r: TestRunner) =
  ## Assert every required field is non-nil. The active-build-context
  ## constructor calls this when wiring the slot so a malformed adapter
  ## raises at construction time rather than at the first recipe call.
  doAssert r != nil,
    "TestRunner is nil — the active build context's testRunner slot " &
    "was never populated"
  doAssert r.name.len > 0,
    "TestRunner.name is empty — every adapter must set its identity"
  doAssert r.run != nil,
    "TestRunner.run is nil — adapter '" & r.name & "' is incomplete"
  doAssert r.list != nil,
    "TestRunner.list is nil — adapter '" & r.name & "' is incomplete"
  doAssert r.enumerate != nil,
    "TestRunner.enumerate is nil — adapter '" & r.name &
      "' is incomplete"

# ---------------------------------------------------------------------
# Direct-binary default implementation.
#
# The stdlib ships a fallback ``TestRunner`` that invokes the binary
# directly. It treats the binary as a black box: ``run`` execs it and
# forwards the exit code; ``list`` returns one synthesised entry
# carrying the binary's basename so the surface stays usable for
# recipes that haven't opted into a framework-aware runner.
# Framework-aware adapters replace this with the proper protocol-aware
# adapter.
# ---------------------------------------------------------------------

proc directRun(binary: TestBinary; filter: string): ExitCode =
  ## Exec the binary as-is. The stdlib default treats ``filter`` as a
  ## single positional argument when non-empty; adapters that own a
  ## structured CLI grammar override this proc entirely.
  if binary.path.len == 0:
    return -1
  let argv =
    if filter.len > 0: @[binary.path, filter]
    else: @[binary.path]
  let cmdline = argv.join(" ")
  try:
    execShellCmd(cmdline)
  except OSError:
    -1

proc directList(binary: TestBinary): seq[TestCase] =
  ## The fallback runner can't introspect the binary's case list; it
  ## synthesises one entry carrying the binary's basename so the
  ## ``list`` surface is non-empty when callers iterate it.
  if binary.path.len == 0:
    return @[]
  let nameOnly = binary.path.extractFilename()
  @[TestCase(qualifiedName: nameOnly, displayName: nameOnly)]

proc directEnumerate(binary: TestBinary): seq[QualifiedName] =
  if binary.path.len == 0:
    return @[]
  @[binary.path.extractFilename()]

proc defaultTestRunner*(): TestRunner =
  ## The stdlib's fallback ``TestRunner``. Framework-aware adapters
  ## replace it via the variant-conditioned ``uses:`` mechanism. The
  ## fallback's identity name is ``"default-test-runner"`` so build
  ## reports can tell the slot was the stdlib default rather than a
  ## chosen adapter.
  newTestRunner(
    name = "default-test-runner",
    run = directRun,
    list = directList,
    enumerate = directEnumerate)
