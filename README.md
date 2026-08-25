# reprobuild-test-adapters

Shared types for building [reprobuild](https://github.com/metacraft-labs/reprobuild)
test-runner adapters. The Nim package it provides is `repro_test_adapters`
(matching reprobuild's `repro_*` library naming).

This package declares the `TestRunner` cross-cutting contract — the vtable-style
record (`TestRunner`, plus `TestBinary`, `TestCase`, `newTestRunner`, `validate`,
`defaultTestRunner`) that a test-runner adapter library *instantiates* and that
the reprobuild project installing the adapter *recognizes*.

## Why a separate package

An adapter library (for example
[`reprobuild-ct-test-runner`](https://github.com/metacraft-labs/reprobuild-ct-test-runner))
constructs a `TestRunner` value; the reprobuild project that installs it must
recognize the same type to wire it into the active build context. If that type
lived inside the reprobuild engine, the adapter would depend on the engine and
the engine's own test project would depend on the adapter — a dependency cycle.

Hosting the contract here, in a package that does not depend on the reprobuild
**engine**, lets both sides share one definition with no cycle:

```
reprobuild-test-adapters    (this package)
        ▲                         ▲
   reprobuild engine     reprobuild-ct-test-runner (adapter)
```

## The one dependency, and what it costs

`generic_test_observations` imports **`ct_test_interface`** — reprobuild's
leaf contract package — for the `ext_test_execution` registry triple
(`extension_id`, `owner`, `schema_version`), its DDL ladder and its column
order.

That triple is shared by every runner that writes RunQuota's generic test
layer. Copying it here instead would be a defect **RunQuota cannot detect**:
`declareExtension` records `owner` at first registration and never compares it
again, and the row-write path passes no owner at all, so a drifted `owner` is
accepted in silence; a drifted `extension_id` simply creates a second table
into which this runner's rows disappear while every query keeps answering,
healthily, from the other runner's table. The import forecloses the drift
rather than testing for it.

`ct_test_interface` is not the reprobuild **engine** — its content is
import-free data and its `.nimble` requires nothing but Nim — so the edge
closes no cycle. It is resolved by `config.nims` from `$REPROBUILD_SRC` or a
sibling `../reprobuild` checkout, mirroring how reprobuild resolves this
package in the other direction. It is deliberately **not** a nimble
`requires`, because `ct_test_interface` is a directory of another repository
rather than a published package.

The cost, stated plainly: **this repository's test suite now needs a
`reprobuild` checkout beside it.** Without one, the package's own modules do
not compile — by design, since a missing shared constant must not degrade into
a locally-invented one.

RunQuota's client is deliberately **not** a dependency. The adapters here
produce declaration and row *values*; writing them over RQSP is the host's
job (reprobuild's `repro_generic_test_recorder`). Linking the observation
transport into this package would impose it on every adapter that only wanted
the `TestRunner` vtable.

## Usage

Adapter side — construct a runner:

```nim
import repro_test_adapters

let runner = newTestRunner(
  name = "my-runner",
  run = proc(binary: TestBinary; filter: string): ExitCode = ...,
  list = proc(binary: TestBinary): seq[TestCase] = ...,
  enumerate = proc(binary: TestBinary): seq[QualifiedName] = ...)
```

Consumer side (a reprobuild project) — recognize and install it via the active
build context's `setTestRunner`.

### The TAP adapter (RunQuota-Observation-Store M20)

`tap_runner` is a TAP 13 adapter: a runner for producers written in any
language, with no suite concept, no per-case output separation, and none of
CodeTracer's trace facts. It exists to satisfy OS-8 — "the generic test layer
MUST be populated by at least two different runners" — from outside
CodeTracer's ecosystem, so that the absences the generic schema made nullable
are exercised by a runner that genuinely has them.

```nim
import repro_test_adapters

let runner = tapTestRunner()
let run = runTapBinary(TestBinary(path: "./suite.sh"), filter = "")
for outcome in run.outcomes:
  assert outcome.recordable()          # every not-null column is filled
  let cells = testExecutionRow(outcome) # positionally matched to
                                        # testExecutionRowColumns()
```

## License

MIT
