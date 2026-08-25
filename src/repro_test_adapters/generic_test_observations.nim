## The FRAMEWORK-NEUTRAL test observation an adapter produces, and the
## registry declaration it produces it under.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Domain
##   Extensions" → "Generic test-execution extension", and invariants
##   OS-5, OS-8;
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20.
##
## **THIS MODULE IS THE SECOND DECLARER OF ``ext_test_execution``, AND
## THAT IS ITS REASON FOR EXISTING.** OS-8: "The generic test layer MUST
## be populated by at least two different runners. A schema only one
## runner can populate has failed this." The first declarer is
## CodeTracer's ``HistoryReporter`` (``ct_test_history``, reprobuild
## M19). This one is reached by any adapter built on this package's
## ``TestRunner`` contract — today the TAP runner in ``tap_runner``.
##
## **THE TRIPLE IS IMPORTED, NEVER SPELLED.** Every identifier below
## comes from ``ct_test_interface/test_execution_extension``: the
## extension id, the owner, the schema version, the migration ladder and
## the column order. Not one of them is written out here, and the
## package's own test asserts that by scanning this source.
##
## The reason is a property of RunQuota rather than a style preference.
## ``declareExtension`` records ``owner`` at FIRST registration and never
## compares it on any later declaration, and the row-write path passes no
## owner at all. So two runners that spell the triple independently and
## then drift apart produce:
##
## * a drifted ``owner`` — accepted in silence, with the registry
##   recording whichever runner happened to declare first;
## * a drifted ``extension_id`` — a SECOND table, into which the second
##   runner's rows disappear while every query still answers from the
##   first runner's table and looks healthy.
##
## Neither is detectable from the store. Sharing the constant removes the
## failure rather than testing for it.
##
## **NO TRANSPORT HERE, DELIBERATELY.** This module produces a
## DECLARATION VALUE and a ROW VALUE, both plain data. Writing them is
## the host's job (reprobuild's ``repro_generic_test_recorder`` speaks
## RQSP). Linking RunQuota's client into this package would put the
## observation transport into every adapter that only wanted the
## ``TestRunner`` vtable, and the package's reason for existing — one
## contract both sides share cheaply — would be gone.

import ct_test_interface/test_execution_extension

export TestExecutionExtensionId, TestExecutionExtensionOwner,
  TestExecutionSchemaVersion, TestExecutionStatuses,
  testExecutionMigrations, testExecutionColumns,
  testExecutionRequiredColumns, registeredTestExecutionName

type
  TestOutcomeStatus* = enum
    ## NAMED ``TestOutcomeStatus`` AND NOT ``TestStatus`` DELIBERATELY:
    ## ``std/unittest`` exports a ``TestStatus`` of its own, and a package
    ## exporting that name breaks every consumer that writes a unit test
    ## — the failure surfaces inside ``unittest``'s own template as an
    ## "undeclared field: 'OK'", nowhere near the import that caused it.
    ##
    ## The generic ``status`` vocabulary as an enum, so an adapter cannot
    ## spell one of the seven wrong and have its rows refused by the
    ## table's ``check`` constraint at run time — a refusal that costs
    ## every row and says nothing.
    ##
    ## The string values are checked against the shared vocabulary in the
    ## ``static`` block below, so this enum cannot drift from the DDL
    ## either.
    tsPass = "pass"
    tsFail = "fail"
    tsSkip = "skip"
    tsXfail = "xfail"
    tsXpass = "xpass"
    tsLeak = "leak"
    tsTimeout = "timeout"

  ObservationCellKind* = enum
    ## The three storage classes a generic test row needs. RunQuota's wire
    ## has a fourth (``real``); no column of ``ext_test_execution`` is one,
    ## so admitting it here would be an encoding an adapter could never
    ## legitimately produce.
    ockNull
    ockText
    ockInt

  ObservationCell* = object
    ## One opaque cell, in the host's transport-independent form.
    ##
    ## ``ockNull`` IS NOT "THE EMPTY STRING" AND NOT "ZERO". §"executions":
    ## "A figure the writer was not given MUST be stored as NULL, never as
    ## zero. Zero is a measurement." A TAP producer knows no per-case
    ## stderr size; writing 0 would claim the case wrote nothing to stderr
    ## and no reader could tell that apart from a case that genuinely did.
    kind*: ObservationCellKind
    text*: string
    number*: int64

  TestOutcome* = object
    ## Everything one ``ext_test_execution`` row carries, as a VALUE an
    ## adapter can build without a store, a socket or a daemon.
    ##
    ## Only ``testId``, ``status`` and ``attempt`` correspond to ``not
    ## null`` columns. Every other field has an explicit "known" flag or an
    ## empty-means-absent rule, because a framework that does not have the
    ## fact must record an ABSENCE rather than invent a value — which is
    ## precisely the property M20 exists to demonstrate is real.
    testId*: string
    suite*: string
      ## Empty means "this framework has no suite for this case", written
      ## as SQL NULL. TAP has no suite concept at all, so every row this
      ## package produces today leaves it empty — the case the generic
      ## layer's nullable ``suite`` was designed for.
    status*: TestOutcomeStatus
    durationMs*: int
    durationKnown*: bool
    attempt*: int
    retryOf*: string
    errorMessage*: string
    skipReason*: string
    stdoutLen*: int
    stdoutKnown*: bool
    stderrLen*: int
    stderrKnown*: bool

  TestExecutionDeclaration* = object
    ## The registry triple plus its DDL ladder, exactly as RunQuota's
    ## ``declareExtension`` wants them, and composed only from the shared
    ## constants.
    extensionId*: string
    owner*: string
    schemaVersion*: int64
    migrations*: seq[string]

static:
  # THE ENUM AND THE DDL CANNOT DRIFT. The table's ``check`` constraint is
  # generated from ``TestExecutionStatuses``; an eighth enum member, or a
  # renamed one, would be refused by the store at run time with every row
  # lost and nothing anywhere to say so. Caught here instead, at compile
  # time, in the package that produces the value.
  for status in TestOutcomeStatus:
    var found = false
    for allowed in TestExecutionStatuses:
      if $status == allowed:
        found = true
    doAssert found, "TestOutcomeStatus." & $status &
      " is not in the shared ext_test_execution status vocabulary"
  doAssert ord(high(TestOutcomeStatus)) - ord(low(TestOutcomeStatus)) + 1 ==
    TestExecutionStatuses.len,
    "TestOutcomeStatus and the shared status vocabulary differ in size"

proc nullCell*(): ObservationCell = ObservationCell(kind: ockNull)
proc textCell*(value: string): ObservationCell =
  ## Empty text is an ABSENCE, not a value. See ``ObservationCell``.
  if value.len == 0: nullCell() else: ObservationCell(kind: ockText, text: value)
proc intCell*(value: int64): ObservationCell =
  ObservationCell(kind: ockInt, number: value)

proc testExecutionDeclaration*(): TestExecutionDeclaration =
  ## The declaration this package's adapters register under.
  ##
  ## EVERY FIELD COMES FROM THE SHARED MODULE. If this proc ever spells a
  ## literal, the two declarers have forked and nothing in RunQuota will
  ## report it; ``tests/generic_test_observations_test.nim`` asserts the
  ## absence of those literals from this file.
  TestExecutionDeclaration(
    extensionId: TestExecutionExtensionId,
    owner: TestExecutionExtensionOwner,
    schemaVersion: TestExecutionSchemaVersion,
    migrations: testExecutionMigrations())

proc testExecutionRowColumns*(): seq[string] =
  ## The column names, in the order ``testExecutionRow`` builds values.
  testExecutionColumns()

proc testExecutionRow*(outcome: TestOutcome): seq[ObservationCell] =
  ## One row's values, positionally matched to ``testExecutionRowColumns``.
  ##
  ## A COLUMN LIST AND A VALUE LIST THAT DISAGREE IS A SILENT LOSS: the row
  ## write is one buffered frame with no reply, so a rejected insert is
  ## never reported to anybody. The package's own test asserts the two
  ## sequences have equal length and that the required columns are non-NULL.
  @[
    textCell(outcome.testId),
    textCell(outcome.suite),
    textCell($outcome.status),
    (if outcome.durationKnown: intCell(int64(outcome.durationMs))
     else: nullCell()),
    intCell(int64(outcome.attempt)),
    textCell(outcome.retryOf),
    textCell(outcome.errorMessage),
    textCell(outcome.skipReason),
    (if outcome.stdoutKnown: intCell(int64(outcome.stdoutLen))
     else: nullCell()),
    (if outcome.stderrKnown: intCell(int64(outcome.stderrLen))
     else: nullCell())
  ]

proc recordable*(outcome: TestOutcome): bool =
  ## Whether this outcome can fill every ``not null`` column of the generic
  ## table — i.e. whether it is recordable AT ALL.
  ##
  ## THE OS-8 CLAUSE IN EXECUTABLE FORM: "no CodeTracer-specific column is
  ## required to record a test outcome". This proc reads no CodeTracer
  ## fact because there is none to read; an adapter that can name its case
  ## and say what happened is complete.
  outcome.testId.len > 0 and outcome.attempt >= 1
