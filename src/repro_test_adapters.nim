## ``repro_test_adapters`` — the shared contract for building reprobuild
## test-runner adapter libraries.
##
## An adapter library (e.g. ``reprobuild-ct-test-runner``) imports this
## package to *construct* a ``TestRunner`` value; the reprobuild project
## that installs the adapter imports the same package to *recognize* and
## install that value via the active build context's ``setTestRunner``.
## Sharing the type through this dependency-free package is what lets the
## adapter and its consumer agree on one definition without a cycle
## through the reprobuild engine.
##
## RunQuota-Observation-Store M20 adds a second surface to this package:
## ``generic_test_observations`` (the framework-neutral
## ``ext_test_execution`` declaration and row, imported from reprobuild's
## ``ct_test_interface`` leaf contract rather than copied) and
## ``tap_runner`` (a TAP 13 adapter — the non-CodeTracer runner OS-8
## requires). Neither links a store, a socket or a daemon; both produce
## plain values a host writes.
import ./repro_test_adapters/test_runner
import ./repro_test_adapters/generic_test_observations
import ./repro_test_adapters/tap_runner
export test_runner, generic_test_observations, tap_runner
