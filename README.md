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

Hosting the contract here, in a package that depends on **nothing but the Nim
standard library**, lets both sides share one definition with no cycle:

```
reprobuild-test-adapters    (this package — no deps)
        ▲                         ▲
   reprobuild engine     reprobuild-ct-test-runner (adapter)
```

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

## License

MIT
