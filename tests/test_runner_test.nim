## Contract tests for the ``TestRunner`` shared types.
##
## These exercise the builder/validator and the std-only default runner so
## that the dependency-free guarantee (and the vtable completeness checks the
## reprobuild engine relies on when wiring the slot) stay intact.

import std/[os, unittest]
import repro_test_adapters

suite "TestRunner contract":
  test "newTestRunner populates every vtable field":
    let r = newTestRunner(
      name = "unit",
      run = proc(b: TestBinary; f: string): ExitCode = 0,
      list = proc(b: TestBinary): seq[TestCase] = @[],
      enumerate = proc(b: TestBinary): seq[QualifiedName] = @[])
    check r.name == "unit"
    check r.run != nil
    check r.list != nil
    check r.enumerate != nil
    # A fully-populated runner must pass validation.
    r.validate()

  test "validate rejects a nil runner":
    var r: TestRunner = nil
    expect AssertionDefect:
      r.validate()

  test "validate rejects an empty identity":
    let r = TestRunner(
      name: "",
      run: proc(b: TestBinary; f: string): ExitCode = 0,
      list: proc(b: TestBinary): seq[TestCase] = @[],
      enumerate: proc(b: TestBinary): seq[QualifiedName] = @[])
    expect AssertionDefect:
      r.validate()

  test "validate rejects an incomplete vtable":
    let r = TestRunner(name: "partial")  # run/list/enumerate left nil
    expect AssertionDefect:
      r.validate()

suite "default direct-binary runner":
  test "defaultTestRunner is a complete, named runner":
    let r = defaultTestRunner()
    check r.name == "default-test-runner"
    r.validate()

  test "list/enumerate synthesise the binary basename":
    let r = defaultTestRunner()
    let bin = TestBinary(path: "/tmp/some" / "suite_binary")
    let listed = r.list(bin)
    check listed.len == 1
    check listed[0].qualifiedName == "suite_binary"
    check r.enumerate(bin) == @["suite_binary"]

  test "empty path yields empty enumeration and a failure exit code":
    let r = defaultTestRunner()
    let empty = TestBinary(path: "")
    check r.list(empty).len == 0
    check r.enumerate(empty).len == 0
    check r.run(empty, "") == -1
