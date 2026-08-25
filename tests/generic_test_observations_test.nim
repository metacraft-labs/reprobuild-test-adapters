## M20 / OS-8, the half that is assertable without a daemon: this package
## is a SECOND DECLARER of ``ext_test_execution`` that shares the first
## declarer's constants rather than copying them, and its TAP adapter can
## fill every required column without inventing a value.
##
## Normative sources:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20;
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Generic
##   test-execution extension", invariants OS-5 and OS-8.
##
## THE OTHER HALF IS IN REPROBUILD. Whether two runners' rows actually
## land in one table and are actually queried indistinguishably is a
## question about a running ``runquotad``, and it is asserted end-to-end
## in ``reprobuild/tests/integration/t_m20_second_runner_generic_layer.nim``.
## What is asserted HERE is what that test cannot see: that the triple this
## package declares is the shared one by CONSTRUCTION, so it cannot drift
## into agreement-by-coincidence.
##
## NO MOCKS. The subjects are the shipped modules and, for the literal
## scan, the shipped source file itself.

import std/[os, strutils, unittest]

import repro_test_adapters

const ObservationsSource =
  currentSourcePath().parentDir.parentDir /
    "src" / "repro_test_adapters" / "generic_test_observations.nim"

suite "M20 the generic declaration is shared, not copied":

  test "the declaration is the shared triple":
    let declaration = testExecutionDeclaration()
    check declaration.extensionId == TestExecutionExtensionId
    check declaration.owner == TestExecutionExtensionOwner
    check declaration.schemaVersion == TestExecutionSchemaVersion
    check declaration.migrations == testExecutionMigrations()
    # THE LADDER MUST REACH THE DECLARED VERSION or RunQuota refuses the
    # declaration outright and every row this package produces is lost
    # with nothing to say so.
    check declaration.migrations.len == int(declaration.schemaVersion)

  test "this package spells no part of the triple itself":
    # THE ASSERTION EQUALITY CANNOT MAKE. Comparing two constants proves
    # they are equal TODAY; it says nothing about whether they are one
    # constant or two that will drift. RunQuota cannot help: ``owner`` is
    # written at first registration and never compared again, so a drifted
    # owner is accepted in silence, and a drifted id creates a second
    # table that no query joins. So the property asserted is the one that
    # forecloses the drift — the value appears in this repository only as
    # an IMPORT.
    #
    # Read from the shipped source rather than restated, so a future edit
    # that reintroduces a literal is caught by this test rather than by a
    # reader of the diff.
    check fileExists(ObservationsSource)
    let source = readFile(ObservationsSource)
    # Non-vacuity first: the file this scan reads is the file that builds
    # the declaration. If the path were wrong the scan below would pass
    # against an empty string.
    check "testExecutionDeclaration" in source
    check "extensionId: TestExecutionExtensionId" in source
    for forbidden in ["\"" & TestExecutionExtensionId & "\"",
                      "\"" & TestExecutionExtensionOwner & "\"",
                      "\"ext_" & TestExecutionExtensionId & "\""]:
      checkpoint("forbidden literal " & forbidden)
      check forbidden notin source

  test "the row is positionally consistent with the column list":
    # A COLUMN LIST AND A VALUE LIST OF DIFFERENT LENGTHS IS A SILENT
    # LOSS: the row write is one buffered frame with no reply, so the
    # store's rejection reaches nobody.
    let outcome = TestOutcome(testId: "alpha", attempt: 1, status: tsPass)
    check testExecutionRow(outcome).len == testExecutionRowColumns().len
    check testExecutionRowColumns() == testExecutionColumns()

  test "every required column is filled and nothing else has to be":
    # THE M20 GATE CLAUSE, in the form this package can assert: "no
    # CodeTracer-specific column is required to record a test outcome".
    # The outcome below carries NOTHING but the three universal facts.
    let bare = TestOutcome(testId: "alpha", attempt: 1, status: tsPass)
    check bare.recordable()
    let columns = testExecutionRowColumns()
    let values = testExecutionRow(bare)
    for required in testExecutionRequiredColumns():
      let idx = columns.find(required)
      checkpoint("required column " & required)
      check idx >= 0
      check values[idx].kind != ockNull
    # And the converse control: everything that is NOT required really is
    # absent here, so the check above is not passing because the bare
    # outcome happens to fill the whole row.
    var optionalNulls = 0
    for i, name in columns:
      if name notin testExecutionRequiredColumns() and
          values[i].kind == ockNull:
        inc optionalNulls
    check optionalNulls == columns.len - testExecutionRequiredColumns().len

  test "an absent figure is NULL and never zero or empty":
    # §"executions": "A figure the writer was not given MUST be stored as
    # NULL, never as zero. Zero is a measurement."
    let outcome = TestOutcome(testId: "alpha", attempt: 1, status: tsPass)
    let columns = testExecutionRowColumns()
    let values = testExecutionRow(outcome)
    for name in ["suite", "duration_ms", "stdout_len", "stderr_len",
                 "retry_of", "error_message", "skip_reason"]:
      checkpoint("column " & name)
      check values[columns.find(name)].kind == ockNull
    # Positive control on the same columns: a figure the writer WAS given
    # is an integer, so the NULLs above are the absence and not the
    # encoding.
    var known = outcome
    known.durationMs = 0
    known.durationKnown = true
    known.suite = "s"
    let knownValues = testExecutionRow(known)
    check knownValues[columns.find("duration_ms")].kind == ockInt
    check knownValues[columns.find("duration_ms")].number == 0
    check knownValues[columns.find("suite")].kind == ockText

suite "M20 the TAP adapter is a runner of this package's own contract":

  test "tapTestRunner is a complete, named, non-CodeTracer runner":
    let runner = tapTestRunner()
    runner.validate()
    check runner.name == TapRunnerName
    check "codetracer" notin runner.name
    check runner.name != defaultTestRunner().name

  test "TAP results map onto the generic vocabulary":
    let run = parseTap("""
TAP version 13
1..5
ok 1 - alpha
not ok 2 - beta
  ---
  message: 'expected 1 to equal 2'
  duration_ms: 12
  ...
ok 3 - gamma # SKIP no fixture on this platform
not ok 4 - delta # TODO not implemented yet
ok 5 - epsilon # TODO already fixed
""")
    check run.planned == 5
    check run.outcomes.len == 5
    check run.outcomes[0].testId == "alpha"
    check run.outcomes[0].status == tsPass
    check run.outcomes[1].status == tsFail
    check run.outcomes[1].errorMessage == "expected 1 to equal 2"
    check run.outcomes[1].durationKnown
    check run.outcomes[1].durationMs == 12
    check run.outcomes[2].status == tsSkip
    check run.outcomes[2].skipReason == "no fixture on this platform"
    # A FAILING TODO IS AN EXPECTED FAILURE AND A PASSING ONE IS AN
    # UNEXPECTED PASS. Both directions, because collapsing them to "pass"
    # hides the stale TODO, which is the one worth reading.
    check run.outcomes[3].status == tsXfail
    check run.outcomes[4].status == tsXpass
    # TAP HAS NO SUITE, so every row leaves it absent rather than "".
    for outcome in run.outcomes:
      check outcome.suite.len == 0
      check outcome.attempt == 1
      check outcome.recordable()
      # AND NO PER-CASE OUTPUT SIZES. Unknown, not zero.
      check not outcome.stdoutKnown
      check not outcome.stderrKnown

  test "a producer that dies mid-plan does not report its unrun cases as passes":
    # THE FIXTURE A WELL-BEHAVED PRODUCER CANNOT MAKE. Cases 3 and 4 were
    # planned and never reported; an absent row and a passing row are
    # indistinguishable to every later query, so the runner records what
    # it observed — that they never reported.
    let run = parseTap("""
TAP version 13
1..4
ok 1 - alpha
not ok 2 - beta
Bail out! database unreachable
""")
    check run.bailedOut
    check run.outcomes.len == 4
    check run.outcomes[2].status == tsTimeout
    check run.outcomes[3].status == tsTimeout
    check run.outcomes[2].errorMessage.len > 0
    for outcome in run.outcomes:
      check outcome.recordable()

  test "an escaped hash is not a directive":
    # The description ``handles \# in input`` is a name, not a skip. The
    # naive split turns it into one, and the resulting row claims a case
    # was skipped for a reason nobody wrote.
    let run = parseTap("ok 1 - handles \\# in input\n")
    check run.outcomes.len == 1
    check run.outcomes[0].status == tsPass
    check run.outcomes[0].testId == "handles \\# in input"

  test "a description-less result still gets a test_id":
    # ``test_id`` is ``not null``; a row without one is refused and the
    # refusal reaches nobody.
    let run = parseTap("1..2\nok 1\nnot ok 2\n")
    check run.outcomes.len == 2
    for outcome in run.outcomes:
      check outcome.testId.len > 0
      check outcome.recordable()
    check run.outcomes[0].testId != run.outcomes[1].testId

  test "non-TAP noise is ignored rather than parsed as results":
    let run = parseTap("""
# a comment
some tool wrote this line
TAP version 13
1..1
ok 1 - alpha
""")
    check run.outcomes.len == 1
    check run.outcomes[0].testId == "alpha"
