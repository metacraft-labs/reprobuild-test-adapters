version = "0.1.0"
author = "Metacraft Labs"
description = "Shared types for building reprobuild test-runner adapters"
license = "MIT"
srcDir = "src"
requires "nim >= 2.2.0"

# RunQuota-Observation-Store M20: ``generic_test_observations`` imports
# reprobuild's ``ct_test_interface`` leaf contract for the
# ``ext_test_execution`` registry triple, DDL ladder and column order. It is
# NOT a nimble ``requires`` because ``ct_test_interface`` is not published as
# a standalone package — it is a directory of reprobuild's repository — and
# declaring an unresolvable requirement would break resolution for every
# consumer in order to document one path. It is resolved by ``config.nims``
# from ``$REPROBUILD_SRC`` or a sibling ``../reprobuild`` checkout, the same
# convention reprobuild already uses to resolve this package in the other
# direction.
#
# The cost is stated in the README: this repository's own test suite now needs
# that sibling checkout. The alternative — copying the triple — is a defect
# RunQuota cannot detect; see ``generic_test_observations``.
