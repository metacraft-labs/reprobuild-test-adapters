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
import ./repro_test_adapters/test_runner
export test_runner
