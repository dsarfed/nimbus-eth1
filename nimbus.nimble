# nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

mode = ScriptMode.Verbose

packageName   = "nimbus"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices"
license       = "Apache License 2.0"
skipDirs      = @["tests", "examples"]
# we can't have the result of a custom task in the "bin" var - https://github.com/nim-lang/nimble/issues/542
# bin           = @["build/nimbus"]

requires "nim >= 1.6.0",
  "bncurve",
  "chronicles",
  "chronos",
  "eth",
  "json_rpc",
  "libbacktrace",
  "nimcrypto",
  "stew",
  "stint",
  "rocksdb",
  "ethash",
  "blscurve",
  "evmc",
  "web3",
  "minilru"

binDir = "build"

when declared(namedBin):
  namedBin = {
    "nimbus/nimbus": "nimbus",
    "fluffy/fluffy": "fluffy",
    "nimbus_verified_proxy/nimbus_verified_proxy": "nimbus_verified_proxy",
  }.toTable()

import std/os

proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(path: string, name: string, params = "", lang = "c") =
  # Verify stack usage is kept low by setting 1mb stack limit in tests.
  const stackLimitKiB = 1024
  when not defined(windows):
    const (buildOption, runPrefix) = ("", "ulimit -s " & $stackLimitKiB & " && ")
  else:
    # No `ulimit` in Windows.  `ulimit -s` in Bash is accepted but has no effect.
    # See https://public-inbox.org/git/alpine.DEB.2.21.1.1709131448390.4132@virtualbox/
    # Also, the command passed to NimScript `exec` on Windows is not a shell script.
    # Instead, we can set stack size at link time.
    const (buildOption, runPrefix) =
      (" -d:windowsNoSetStack --passL:-Wl,--stack," & $(stackLimitKiB * 2048), "")

  buildBinary name, (path & "/"), params & buildOption
  exec runPrefix & "build/" & name

task test, "Run tests":
  test "tests", "all_tests", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

task test_rocksdb, "Run rocksdb tests":
  test "tests/db", "test_kvstore_rocksdb", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

task test_import, "Run block import test":
  let tmp = getTempDir() / "nimbus-eth1-block-import"
  if dirExists(tmp):
    echo "Remove directory before running test: " & tmp
    quit(QuitFailure)

  const nimbus = when defined(windows):
    "build/nimbus.exe"
  else:
    "build/nimbus"

  if not fileExists(nimbus):
    echo "Build nimbus before running this test"
    quit(QuitFailure)

  # Test that we can resume import
  exec "build/nimbus import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:1"
  exec "build/nimbus import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:1023"
  # There should only be 8k blocks
  exec "build/nimbus import --data-dir:" & tmp & " --era1-dir:tests/replay --max-blocks:10000"

task test_evm, "Run EVM tests":
  test "tests", "evm_tests", "-d:chronicles_log_level=ERROR -d:unittest2DisableParamFiltering"

## Fluffy tasks

task fluffy, "Build fluffy":
  buildBinary "fluffy", "fluffy/", "-d:chronicles_log_level=TRACE"

task fluffy_test, "Run fluffy tests":
  # Need the nimbus_db_backend in state network tests as we need a Hexary to
  # start from, even though it only uses the MemoryDb.
  test "fluffy/tests/portal_spec_tests/mainnet", "all_fluffy_portal_spec_tests", "-d:chronicles_log_level=ERROR -d:nimbus_db_backend=sqlite"
  # Seperate build for these tests as they are run with a low `mergeBlockNumber`
  # to make the tests faster. Using the real mainnet merge block number is not
  # realistic for these tests.
  test "fluffy/tests", "all_fluffy_tests", "-d:chronicles_log_level=ERROR -d:nimbus_db_backend=sqlite -d:mergeBlockNumber:38130"

task utp_test_app, "Build uTP test app":
  buildBinary "utp_test_app", "fluffy/tools/utp_testing/", "-d:chronicles_log_level=TRACE"

task utp_test, "Run uTP integration tests":
  test "fluffy/tools/utp_testing", "utp_test", "-d:chronicles_log_level=ERROR"

task test_portal_testnet, "Build test_portal_testnet":
  buildBinary "test_portal_testnet", "fluffy/scripts/", "-d:chronicles_log_level=DEBUG -d:unittest2DisableParamFiltering"

## Nimbus Verified Proxy tasks

task nimbus_verified_proxy, "Build Nimbus verified proxy":
  buildBinary "nimbus_verified_proxy", "nimbus_verified_proxy/", "-d:chronicles_log_level=TRACE"

task nimbus_verified_proxy_test, "Run Nimbus verified proxy tests":
  test "nimbus_verified_proxy/tests", "test_proof_validation", "-d:chronicles_log_level=ERROR -d:nimbus_db_backend=sqlite"
