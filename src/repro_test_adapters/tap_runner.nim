## A TAP (Test Anything Protocol) test-runner adapter — the SECOND runner
## RunQuota-Observation-Store §M20 requires, and deliberately nothing to
## do with CodeTracer.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20
##   — "A non-CodeTracer runner via ``reprobuild-test-adapters`` writes
##   ``ext_test_execution`` rows that ``stats flaky``/``duration`` query
##   indistinguishably from CodeTracer's";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Generic
##   test-execution extension", invariant OS-8;
## * TAP version 13, https://testanything.org/tap-version-13-specification.html
##
## **WHY TAP AND NOT A SECOND NIM RUNNER.** OS-8 is about a schema that
## only one runner can populate. A second runner sharing the first one's
## language, its ``std/unittest`` fork, its ``--list-json`` protocol and
## its result-document format would populate the layer the same way for
## the same reasons and prove nothing. TAP is a line protocol from
## outside this ecosystem entirely (perl's ``prove``, ``node:test``,
## libtap, pytest-tap), it is emitted by processes written in any
## language, and — the part that matters here — it is MISSING facts
## CodeTracer's runner has:
##
## * no suite concept, so ``suite`` is genuinely absent rather than empty;
## * no per-case output separation, so ``stdout_len``/``stderr_len`` are
##   genuinely unknown rather than zero;
## * no trace, no recorder, no replay, no checkpoint, no body hash — none
##   of ``ext_codetracer_test``'s columns exist for it, and this runner
##   never declares that extension.
##
## Every one of those absences is a NULL the generic layer already had a
## place for. If any of them had to be faked, the layer would have failed
## OS-8 and this file is where that would have shown up.
##
## **THE VTABLE IS THIS PACKAGE'S OWN CONTRACT.** ``tapTestRunner()``
## returns a ``TestRunner``, so the adapter is installed exactly the way
## every other adapter is, through the active build context's
## ``setTestRunner``. "Via ``reprobuild-test-adapters``" is structural,
## not a description.
##
## **NO STORE, NO SOCKET, NO DAEMON IN THIS FILE.** The runner produces
## ``TestOutcome`` values; the host writes them. See
## ``generic_test_observations`` for why the transport stays out.

import std/[os, osproc, strutils]

import ./test_runner
import ./generic_test_observations

export generic_test_observations

const
  TapRunnerName* = "tap-test-runner"
    ## The adapter identity. Recorded as the RunQuota ``runs.tool`` value
    ## by the host, which is what makes the two runners' RUNS
    ## distinguishable while their generic ROWS are not — the distinction
    ## OS-8 wants preserved is by extension table and by run, never by a
    ## column of the shared layer.
  TapRunnerVersion* = "1"

type
  TapRun* = object
    ## One execution of one TAP-emitting binary.
    exitCode*: ExitCode
    outcomes*: seq[TestOutcome]
    planned*: int
      ## The ``1..N`` plan the producer declared, or -1 when it declared
      ## none. Kept because a producer that emits fewer results than it
      ## planned has DIED MID-RUN, and the cases it never reached are not
      ## passes.
    bailedOut*: bool
      ## ``Bail out!`` — the producer abandoned the run.
    outputBytes*: int
      ## Size of the merged stream. Deliberately NOT written into
      ## ``stdout_len``: it is the size of the whole binary's output, not
      ## of any one case's, and attributing it to a case would be a
      ## measurement of the wrong thing.

proc stripDirective(description: string):
    tuple[text, directive, reason: string] =
  ## Split ``some name # SKIP not on this platform`` into its parts.
  ##
  ## The ``#`` MUST BE UNESCAPED. TAP allows ``\#`` inside a description,
  ## and treating an escaped hash as a directive would turn a case named
  ## ``handles \# in input`` into a skip with a nonsense reason.
  var idx = -1
  var i = 0
  while i < description.len:
    if description[i] == '\\':
      i += 2
      continue
    if description[i] == '#':
      idx = i
      break
    inc i
  if idx < 0:
    return (description.strip(), "", "")
  let head = description[0 ..< idx].strip()
  let tail = description[(idx + 1) .. ^1].strip()
  var directive = ""
  var reason = ""
  let space = tail.find(' ')
  if space < 0:
    directive = tail.toUpperAscii()
  else:
    directive = tail[0 ..< space].toUpperAscii()
    reason = tail[(space + 1) .. ^1].strip()
  (head, directive, reason)

proc parseTap*(text: string): TapRun =
  ## Parse a TAP 13 stream into framework-neutral outcomes.
  ##
  ## Handles: the ``1..N`` plan (leading or trailing), ``ok``/``not ok``
  ## with an optional number and description, the ``SKIP`` and ``TODO``
  ## directives, ``Bail out!``, and the YAML diagnostic block's
  ## ``message:`` and ``duration_ms:`` keys. Everything else is a comment
  ## and is ignored, which is what the protocol says a consumer must do.
  result.planned = -1
  result.outputBytes = text.len
  var pendingYaml = false
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if pendingYaml:
      if line == "...":
        pendingYaml = false
        continue
      if result.outcomes.len > 0:
        # THE DIAGNOSTIC BELONGS TO THE PRECEDING RESULT, which is what
        # the protocol says; attaching it to the next one would move every
        # failure message one case along.
        let last = result.outcomes.len - 1
        if line.startsWith("message:"):
          result.outcomes[last].errorMessage =
            line["message:".len .. ^1].strip().strip(chars = {'\'', '"'})
        elif line.startsWith("duration_ms:"):
          try:
            result.outcomes[last].durationMs =
              int(parseFloat(line["duration_ms:".len .. ^1].strip()))
            result.outcomes[last].durationKnown = true
          except ValueError:
            discard
      continue
    if line == "---":
      pendingYaml = true
      continue
    if line.startsWith("Bail out!"):
      result.bailedOut = true
      continue
    if line.startsWith("1.."):
      try:
        result.planned = parseInt(line[3 .. ^1].strip().split(' ')[0])
      except ValueError:
        discard
      continue
    var ok = false
    var rest = ""
    if line.startsWith("not ok"):
      ok = false
      rest = line["not ok".len .. ^1]
    elif line.startsWith("ok"):
      ok = true
      rest = line["ok".len .. ^1]
    else:
      continue
    rest = rest.strip()
    # An optional test number, then an optional ``-`` separator.
    var numEnd = 0
    while numEnd < rest.len and rest[numEnd] in {'0' .. '9'}:
      inc numEnd
    if numEnd > 0:
      rest = rest[numEnd .. ^1].strip()
    if rest.startsWith("-"):
      rest = rest[1 .. ^1].strip()
    let parts = stripDirective(rest)
    var outcome = TestOutcome(
      testId: parts.text,
      # TAP HAS NO SUITE. Left empty so the host writes SQL NULL; the
      # empty string would be the claim "the suite is named ''".
      suite: "",
      attempt: 1,
      # AND NO PER-CASE OUTPUT SIZES. Unknown, therefore NULL — see
      # ``TapRun.outputBytes`` for why the binary's own size is not
      # substituted here.
      stdoutKnown: false,
      stderrKnown: false)
    case parts.directive
    of "SKIP":
      outcome.status = tsSkip
      outcome.skipReason = parts.reason
    of "TODO":
      # A TODO that FAILED is an expected failure; a TODO that PASSED is
      # an unexpected pass. Collapsing both to "pass" would hide the
      # second, which is the one that means the TODO is stale.
      outcome.status = if ok: tsXpass else: tsXfail
    else:
      outcome.status = if ok: tsPass else: tsFail
    if outcome.testId.len == 0:
      # A DESCRIPTION-LESS RESULT STILL NEEDS AN IDENTIFIER, because
      # ``test_id`` is ``not null`` and a row without one is refused. TAP
      # numbers results, so the ordinal is the identity the producer gave
      # it.
      outcome.testId = "tap-case-" & $(result.outcomes.len + 1)
    result.outcomes.add(outcome)
  # A PRODUCER THAT PLANNED MORE THAN IT REPORTED DIED MID-RUN, and the
  # cases it never reached must not be silently absent from the history:
  # "the run recorded nothing about case 7" and "case 7 passed" are the
  # two readings an absent row cannot be told apart from. Each missing
  # case is recorded as a timeout-class outcome with the reason, which is
  # a fact this runner OBSERVED (it counted them) rather than a guess.
  #
  # DONE HERE RATHER THAN IN ``runTapBinary`` because it is a property of
  # the STREAM. A consumer handed a captured stream by some other means
  # would otherwise get the silently-short answer, and the arm that
  # exercises it would be asserting against a code path the shipped
  # runner does not share.
  if result.planned > result.outcomes.len:
    for n in (result.outcomes.len + 1) .. result.planned:
      result.outcomes.add(TestOutcome(
        testId: "tap-case-" & $n,
        attempt: 1,
        status: tsTimeout,
        errorMessage:
          if result.bailedOut: "producer bailed out before this case"
          else: "producer exited before reporting this case"))

proc runTapBinary*(binary: TestBinary; filter: string): TapRun =
  ## Execute a TAP-emitting binary and parse what it said.
  ##
  ## THE STREAMS ARE MERGED, which is why the outcomes report unknown
  ## output sizes rather than zero: a merged stream preserves the
  ## interleaving a reader of a failure needs, at the cost of the split
  ## sizes. Both facts are recorded honestly — the interleaving is kept,
  ## the split is NULL.
  if binary.path.len == 0:
    result.exitCode = -1
    result.planned = -1
    return
  let args = if filter.len > 0: @[filter] else: @[]
  var output = ""
  var code = -1
  try:
    (output, code) = execCmdEx(quoteShell(binary.path) &
      (if args.len > 0: " " & quoteShell(args[0]) else: ""))
  except OSError, IOError:
    result.exitCode = -1
    result.planned = -1
    return
  result = parseTap(output)
  result.exitCode = code

proc tapList(binary: TestBinary): seq[TestCase] =
  ## TAP IS NOT INTROSPECTABLE: a producer announces its cases only by
  ## running. Listing therefore RUNS the binary and reports what it said,
  ## which is the honest answer for this protocol; a synthesised list
  ## would name cases that may not exist.
  for outcome in runTapBinary(binary, "").outcomes:
    result.add(TestCase(qualifiedName: outcome.testId,
      displayName: outcome.testId))

proc tapEnumerate(binary: TestBinary): seq[QualifiedName] =
  for entry in tapList(binary):
    result.add(entry.qualifiedName)

proc tapRun(binary: TestBinary; filter: string): ExitCode =
  runTapBinary(binary, filter).exitCode

proc tapTestRunner*(): TestRunner =
  ## The adapter, as this package's own vtable.
  newTestRunner(
    name = TapRunnerName,
    run = tapRun,
    list = tapList,
    enumerate = tapEnumerate)
