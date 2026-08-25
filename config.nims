import std/[os, strutils]

# ``repro_test_adapters`` has exactly ONE dependency beyond the Nim standard
# library, and it is deliberate: ``ct_test_interface`` — reprobuild's leaf
# contract package that declares the ``ext_test_execution`` registry triple,
# its DDL ladder and its column list.
#
# WHY AN EDGE RATHER THAN A COPY. RunQuota-Observation-Store §"Domain
# Extensions" registers ONE generic test extension for every runner. Two
# runners that spell the ``extension_id`` / ``owner`` / ``schema_version``
# triple separately will eventually spell it differently, and RunQuota cannot
# tell them apart: ``declareExtension`` writes ``owner`` at FIRST registration
# and never compares it again, so a drifted owner is accepted in silence and a
# drifted id simply creates a second table that no query joins. A copied
# constant is therefore a defect with no detector. The edge removes the
# possibility instead of testing for it.
#
# WHY THIS EDGE DOES NOT REINSTATE THE CYCLE THE README DESCRIBES.
# ``ct_test_interface`` is not the reprobuild ENGINE: its whole content is
# import-free data (identifiers, DDL text, column names) and its ``.nimble``
# requires nothing but Nim. The cycle the package exists to avoid is
# ``adapter -> engine -> adapter``; ``adapter -> leaf-contract`` closes no
# loop. What it DOES cost is stated plainly in the README: this repository's
# own test suite now needs a ``reprobuild`` checkout beside it.
#
# Resolution mirrors reprobuild's own sibling-resolution convention:
# an explicit env value first, then a sibling checkout.
let adaptersRoot = currentSourcePath().parentDir()

let reprobuildRoot = block:
  let fromEnv = getEnv("REPROBUILD_SRC")
  if fromEnv.len > 0:
    fromEnv
  else:
    adaptersRoot / ".." / "reprobuild"

let ctTestInterfaceSrc = reprobuildRoot / "libs" / "ct_test_interface" / "src"
if dirExists(ctTestInterfaceSrc):
  switch("path", ctTestInterfaceSrc)

switch("path", adaptersRoot / "src")
