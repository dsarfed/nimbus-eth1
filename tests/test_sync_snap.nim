# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester

import
  std/[algorithm, distros, hashes, math, os, sets,
       sequtils, strformat, strutils, tables, times],
  chronicles,
  eth/[common/eth_types, p2p, rlp, trie/db],
  rocksdb,
  stint,
  stew/[byteutils, results],
  unittest2,
  ../nimbus/[chain_config, config, genesis],
  ../nimbus/db/[db_chain, select_backend, storage_types],
  ../nimbus/p2p/chain,
  ../nimbus/sync/types,
  ../nimbus/sync/snap/range_desc,
  ../nimbus/sync/snap/worker/accounts_db,
  ../nimbus/sync/snap/worker/db/[hexary_desc, rocky_bulk_load],
  ../nimbus/utils/prettify,
  ./replay/[pp, undump_blocks, undump_proofs]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"/"replay", "tests"/"test_sync_snap",
             "nimbus-eth1-blobs"/"replay"]

  nTestDbInstances = 9

type
  CaptureSpecs = tuple
    name: string   ## sample name, also used as sub-directory for db separation
    network: NetworkId
    file: string   ## name of capture file
    numBlocks: int ## Number of blocks to load

  AccountsSample = object
    name: string   ## sample name, also used as sub-directory for db separation
    file: string
    firstItem: int
    lastItem: int

  TestDbs = object
    ## Provide enough spare empty databases
    persistent: bool
    dbDir: string
    cdb: array[nTestDbInstances,ChainDb]

when defined(linux):
  # The `detectOs(Ubuntu)` directive is not Windows compatible, causes an
  # error when running the system command `lsb_release -d` in the background.
  let isUbuntu32bit = detectOs(Ubuntu) and int.sizeof == 4
else:
  const isUbuntu32bit = false

const
  sampleDirRefFile = "sample0.txt.gz"

  goerliCapture: CaptureSpecs = (
    name: "goerli",
    network: GoerliNet,
    file: "goerli68161.txt.gz",
    numBlocks: 1_000)

  accSample0 = AccountsSample(
    name: "sample0",
    file: "sample0.txt.gz",
    firstItem: 0,
    lastItem: high(int))

let
  # Forces `check()` to print the error (as opposed when using `isOk()`)
  OkHexDb = Result[void,HexaryDbError].ok()

  # There was a problem with the Github/CI which results in spurious crashes
  # when leaving the `runner()` if the persistent BaseChainDB initialisation
  # was present, see `test_custom_network` for more details.
  disablePersistentDB = isUbuntu32bit

var
  xTmpDir: string
  xDbs: TestDbs                   # for repeated storage/overwrite tests
  xTab32: Table[ByteArray32,Blob] # extracted data
  xTab33: Table[ByteArray33,Blob]
  xVal32Sum, xVal32SqSum: float   # statistics
  xVal33Sum, xVal33SqSum: float

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc isOk(rc: ValidationResult): bool =
  rc == ValidationResult.OK

proc findFilePath(file: string;
                  baseDir, repoDir: openArray[string]): Result[string,void] =
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return ok(path)
  err()

proc getTmpDir(sampleDir = sampleDirRefFile): string =
  sampleDir.findFilePath(baseDir,repoDir).value.splitFile.dir

proc pp(d: Duration): string =
  if 40 < d.inSeconds:
    d.ppMins
  elif 200 < d.inMilliseconds:
    d.ppSecs
  elif 200 < d.inMicroseconds:
    d.ppMs
  else:
    d.ppUs

proc pp(d: AccountLoadStats): string =
  "[" & d.size.toSeq.mapIt(it.toSI).join(",") & "," &
        d.dura.toSeq.mapIt(it.pp).join(",") & "]"

proc pp(rc: Result[Account,HexaryDbError]): string =
  if rc.isErr: $rc.error else: rc.value.pp

proc pp(rc: Result[Hash256,HexaryDbError]): string =
  if rc.isErr: $rc.error else: $rc.value.to(NodeTag)

proc ppKvPc(w: openArray[(string,int)]): string =
  w.mapIt(&"{it[0]}={it[1]}%").join(", ")

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc setTraceLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc to(sample: AccountsSample; T: type seq[UndumpProof]): T =
  ## Convert test data into usable format
  let file = sample.file.findFilePath(baseDir,repoDir).value
  var
    n = -1
    root: Hash256
  for w in file.undumpNextProof:
    n.inc
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to(b: openArray[byte]; T: type ByteArray32): T =
  ## Convert to other representation (or exception)
  if b.len == 32:
    (addr result[0]).copyMem(unsafeAddr b[0], 32)
  else:
    doAssert b.len == 32

proc to(b: openArray[byte]; T: type ByteArray33): T =
  ## Convert to other representation (or exception)
  if b.len == 33:
    (addr result[0]).copyMem(unsafeAddr b[0], 33)
  else:
    doAssert b.len == 33

proc to(b: ByteArray32|ByteArray33; T: type Blob): T =
  b.toSeq

proc to(b: openArray[byte]; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(b).T

proc to(w: (byte, NodeTag); T: type Blob): T =
  let (b,t) = w
  @[b] & toSeq(t.UInt256.toBytesBE)

proc to(t: NodeTag; T: type Blob): T =
  toSeq(t.UInt256.toBytesBE)

proc flushDbDir(s: string; subDir = "") =
  if s != "":
    let baseDir = s / "tmp"
    for n in 0 ..< nTestDbInstances:
      let instDir = if subDir == "": baseDir / $n else: baseDir / subDir / $n
      if (instDir / "nimbus" / "data").dirExists:
        # Typically under Windows: there might be stale file locks.
        try: instDir.removeDir except: discard
    try: (baseDir / subDir).removeDir except: discard
    block dontClearUnlessEmpty:
      for w in baseDir.walkDir:
        break dontClearUnlessEmpty
      try: baseDir.removeDir except: discard

proc testDbs(workDir = ""; subDir = ""): TestDbs =
  if disablePersistentDB or workDir == "":
    result.persistent = false
    result.dbDir = "*notused*"
  else:
    result.persistent = true
    if subDir != "":
      result.dbDir = workDir / "tmp" / subDir
    else:
      result.dbDir = workDir / "tmp"
  if result.persistent:
    result.dbDir.flushDbDir
    for n in 0 ..< result.cdb.len:
      result.cdb[n] = (result.dbDir / $n).newChainDB

proc lastTwo(a: openArray[string]): seq[string] =
  if 1 < a.len: @[a[^2],a[^1]] else: a.toSeq

proc thisRecord(r: rocksdb_iterator_t): (Blob,Blob) =
  var kLen, vLen:  csize_t
  let
    kData = r.rocksdb_iter_key(addr kLen)
    vData = r.rocksdb_iter_value(addr vLen)
  if not kData.isNil and not vData.isNil:
    let
      key = string.fromBytes(toOpenArrayByte(kData,0,int(kLen)-1))
      value = string.fromBytes(toOpenArrayByte(vData,0,int(vLen)-1))
    return (key.mapIt(it.byte),value.mapIt(it.byte))

proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
  if 0 < length:
    result[0] = sum / length.float
    result[1] = sqrt(sqSum / length.float - result[0] * result[0])

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc accountsRunner(noisy = true;  persistent = true; sample = accSample0) =
  let
    peer = Peer.new
    testItemLst = sample.to(seq[UndumpProof])
    root = testItemLst[0].root
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(sample.name) else: testDbs()
    dbDir = db.dbDir.split($DirSep).lastTwo.join($DirSep)
    info = if db.persistent: &"persistent db on \"{dbDir}\""
           else: "in-memory db"

  defer:
    if db.persistent:
      tmpDir.flushDbDir(sample.name)

  suite &"SyncSnap: {sample.file} accounts and proofs for {info}":
    var
      desc: AccountsDbSessionRef
      accKeys: seq[Hash256]

    test &"Snap-proofing {testItemLst.len} items for state root ..{root.pp}":
      let dbBase = if persistent: AccountsDbRef.init(db.cdb[0])
                   else: AccountsDbRef.init(newMemoryDB())
      for n,w in testItemLst:
        check dbBase.importAccounts(
          peer, root, w.base, w.data, storeData = persistent) == OkHexDb
      noisy.say "***", "import stats=", dbBase.dbImportStats.pp

    test &"Merging {testItemLst.len} proofs for state root ..{root.pp}":
      let dbBase = if persistent: AccountsDbRef.init(db.cdb[1])
                   else: AccountsDbRef.init(newMemoryDB())
      desc = AccountsDbSessionRef.init(dbBase, root, peer)

      # Load/accumulate `proofs` data from several samples
      for w in testItemLst:
        check desc.merge(w.data.proof) == OkHexDb

      # Load/accumulate accounts (needs some unique sorting)
      let lowerBound = testItemLst.mapIt(it.base).sortMerge
      var accounts = testItemLst.mapIt(it.data.accounts).sortMerge
      check desc.merge(lowerBound, accounts) == OkHexDb
      desc.assignPrettyKeys() # for debugging, make sure that state root ~ "$0"

      # Build/complete hexary trie for accounts
      check desc.interpolate() == OkHexDb

      # Save/bulk-store hexary trie on disk
      check desc.dbImports() == OkHexDb
      noisy.say "***", "import stats=",  desc.dbImportStats.pp

      # Update list of accounts. There might be additional accounts in the set
      # of proof nodes, typically before the `lowerBound` of each block. As
      # there is a list of account ranges (that were merged for testing), one
      # need to check for additional records only on either end of a range.
      var keySet = accounts.mapIt(it.accHash).toHashSet
      for w in testItemLst:
        var key = desc.prevChainDbKey(w.data.accounts[0].accHash)
        while key.isOk and key.value notin keySet:
          keySet.incl key.value
          let newKey = desc.prevChainDbKey(key.value)
          check newKey != key
          key = newKey
        key = desc.nextChainDbKey(w.data.accounts[^1].accHash)
        while key.isOk and key.value notin keySet:
          keySet.incl key.value
          let newKey = desc.nextChainDbKey(key.value)
          check newKey != key
          key = newKey
      accKeys = toSeq(keySet).mapIt(it.to(NodeTag)).sorted(cmp)
                             .mapIt(it.to(Hash256))
      check accounts.len <= accKeys.len

    test &"Revisiting {accKeys.len} items stored items on BaseChainDb":
      var
        nextAccount = accKeys[0]
        prevAccount: Hash256
        count = 0
      for accHash in accKeys:
        count.inc
        let
          pfx = $count & "#"
          byChainDB = desc.getChainDbAccount(accHash)
          byNextKey = desc.nextChainDbKey(accHash)
          byPrevKey = desc.prevChainDbKey(accHash)
          byBulker = desc.getBulkDbXAccount(accHash)
        noisy.say "*** find",
          "<", count, "> byChainDb=", byChainDB.pp, " inBulker=", byBulker.pp
        check byChainDB.isOk

        # Check `next` traversal funcionality. If `byNextKey.isOk` fails, the
        # `nextAccount` value is still the old one and will be different from
        # the account in the next for-loop cycle (if any.)
        check pfx & accHash.pp(false) == pfx & nextAccount.pp(false)
        if byNextKey.isOk:
          nextAccount = byNextKey.value
        else:
          nextAccount = Hash256.default

        # Check `prev` traversal funcionality
        if prevAccount != Hash256.default:
          check byPrevKey.isOk
          if byPrevKey.isOk:
            check pfx & byPrevKey.value.pp(false) == pfx & prevAccount.pp(false)
        prevAccount = accHash

        if desc.dbBackendRocksDb():
          check byBulker.isOk
          check byChainDB == byBulker

      # Hexary trie memory database dump. These are key value pairs for
      # ::
      #   Branch:    ($1,b(<$2,$3,..,$17>,))
      #   Extension: ($18,e(832b5e..06e697,$19))
      #   Leaf:      ($20,l(cc9b5d..1c3b4,f84401..f9e5129d[#70]))
      #
      # where keys are typically represented as `$<id>` or `¶<id>` or `ø`
      # depending on whether a key is final (`$<id>`), temporary (`¶<id>`)
      # or unset/missing (`ø`).
      #
      # The node types are indicated by a letter after the first key before
      # the round brackets
      # ::
      #   Branch:    'b', 'þ', or 'B'
      #   Extension: 'e', '€', or 'E'
      #   Leaf:      'l', 'ł', or 'L'
      #
      # Here a small letter indicates a `Static` node which was from the
      # original `proofs` list, a capital letter indicates a `Mutable` node
      # added on the fly which might need some change, and the decorated
      # letters stand for `Locked` nodes which are like `Static` ones but
      # added later (typically these nodes are update `Mutable` nodes.)
      #
      # Beware: dumping a large database is not recommended
      #noisy.say "***", "database dump\n    ", desc.dumpProofsDB.join("\n    ")


proc importRunner(noisy = true;  persistent = true; capture = goerliCapture) =

  let
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value
    tmpDir = getTmpDir()
    db = if persistent: tmpDir.testDbs(capture.name) else: testDbs()
    numBlocksInfo = if capture.numBlocks == high(int): ""
                    else: $capture.numBlocks & " "
    loadNoise = noisy

  defer:
    if db.persistent:
      tmpDir.flushDbDir(capture.name)

  suite &"SyncSnap: using {fileInfo} capture for testing db timings":
    var
      ddb: BaseChainDB         # perstent DB on disk
      chn: Chain

    test &"Create persistent BaseChainDB on {tmpDir}":
      let chainDb = if db.persistent: db.cdb[0].trieDB
                    else: newMemoryDB()

      # Constructor ...
      ddb = newBaseChainDB(
        chainDb,
        id = capture.network,
        pruneTrie = true,
        params = capture.network.networkParams)

      ddb.initializeEmptyDb
      chn = ddb.newChain

    test &"Storing {numBlocksInfo}persistent blocks from dump":
      for w in filePath.undumpNextGroup:
        let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)
        if fromBlock == 0.u256:
          doAssert w[0][0] == ddb.getBlockHeader(0.u256)
          continue
        # Message if [fromBlock,toBlock] contains a multiple of 700
        if fromBlock + (toBlock mod 900) <= toBlock:
          loadNoise.say "***", &"processing ...[#{fromBlock},#{toBlock}]..."
        check chn.persistBlocks(w[0], w[1]).isOk
        if capture.numBlocks.toBlockNumber <= w[0][^1].blockNumber:
          break

    test "Extract key-value records into memory tables via rocksdb iterator":
      # Implicit test: if not persistent => db.cdb[0] is nil
      if db.cdb[0].rocksStoreRef.isNil:
        skip()
      else:
        let
          rdb = db.cdb[0].rocksStoreRef
          rop = rdb.store.readOptions
          rit = rdb.store.db.rocksdb_create_iterator(rop)
        check not rit.isNil

        xTab32.clear
        xTab33.clear

        rit.rocksdb_iter_seek_to_first()
        while rit.rocksdb_iter_valid() != 0:
          let (key,val) = rit.thisRecord()
          rit.rocksdb_iter_next()
          if key.len == 32:
            xTab32[key.to(ByteArray32)] = val
            xVal32Sum += val.len.float
            xVal32SqSum += val.len.float * val.len.float
            check key.to(ByteArray32).to(Blob) == key
          elif key.len == 33:
            xTab33[key.to(ByteArray33)] = val
            xVal33Sum += val.len.float
            xVal33SqSum += val.len.float * val.len.float
            check key.to(ByteArray33).to(Blob) == key
          else:
            noisy.say "***", "ignoring key=", key.toHex

        rit.rocksdb_iter_destroy()

        var
          (mean32, stdv32) = meanStdDev(xVal32Sum, xVal32SqSum, xTab32.len)
          (mean33, stdv33) = meanStdDev(xVal33Sum, xVal33SqSum, xTab33.len)
        noisy.say "***",
          "key 32 table: ",
          &"size={xTab32.len} valLen={(mean32+0.5).int}({(stdv32+0.5).int})",
          ", key 33 table: ",
          &"size={xTab33.len} valLen={(mean33+0.5).int}({(stdv33+0.5).int})"


proc storeRunner(noisy = true;  persistent = true; cleanUp = true) =
  let
    fullNoise = false
  var
    emptyDb = "empty"

  # Allows to repeat storing on existing data
  if not xDbs.cdb[0].isNil:
    emptyDb = "pre-loaded"
  elif persistent:
    xTmpDir = getTmpDir()
    xDbs = xTmpDir.testDbs("store-runner")
  else:
    xDbs = testDbs()

  defer:
    if xDbs.persistent and cleanUp:
      xTmpDir.flushDbDir("store-runner")
      xDbs.reset

  suite &"SyncSnap: storage tests on {emptyDb} databases":
    #
    # `xDbs` instance slots layout:
    #
    # * cdb[0] -- direct db, key length 32, no transaction
    # * cdb[1] -- direct db, key length 32 as 33, no transaction
    #
    # * cdb[2] -- direct db, key length 32, transaction based
    # * cdb[3] -- direct db, key length 32 as 33, transaction based
    #
    # * cdb[4] -- direct db, key length 33, no transaction
    # * cdb[5] -- direct db, key length 33, transaction based
    #
    # * cdb[6] -- rocksdb, key length 32
    # * cdb[7] -- rocksdb, key length 32 as 33
    # * cdb[8] -- rocksdb, key length 33
    #
    doAssert 9 <= nTestDbInstances

    if xTab32.len == 0 or xTab33.len == 0:
      test &"Both tables with 32 byte keys(size={xTab32.len}), " &
          &"33 byte keys(size={xTab32.len}) must be non-empty":
        skip()
    else:
      # cdb[0] -- direct db, key length 32, no transaction
      test &"Directly store {xTab32.len} records " &
          &"(key length 32) into {emptyDb} trie database":
        var ela: Duration
        let tdb = xDbs.cdb[0].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(keyLen 32)", ela):
          for (key,val) in xTab32.pairs:
            tdb.put(key, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab32.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab32.len, ", ",
            "perRecord=", perRec.pp

      # cdb[1] -- direct db, key length 32 as 33, no transaction
      test &"Directly store {xTab32.len} records " &
          &"(key length 33) into {emptyDb} trie database":
        var ela = initDuration()
        let tdb = xDbs.cdb[1].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(keyLen 32 as 33)", ela):
          for (key,val) in xTab32.pairs:
            tdb.put(@[99.byte] & key.toSeq, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab32.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab32.len, ", ",
            "perRecord=", perRec.pp

      # cdb[2] -- direct db, key length 32, transaction based
      test &"Transactionally store {xTab32.len} records " &
          &"(key length 32) into {emptyDb} trie database":
        var ela: Duration
        let tdb = xDbs.cdb[2].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(tx,keyLen 32)", ela):
          let dbTx = tdb.beginTransaction
          defer: dbTx.commit

          for (key,val) in xTab32.pairs:
            tdb.put(key, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab32.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab32.len, ", ",
            "perRecord=", perRec.pp

      # cdb[3] -- direct db, key length 32 as 33, transaction based
      test &"Transactionally store {xTab32.len} records " &
          &"(key length 33) into {emptyDb} trie database":
        var ela: Duration
        let tdb = xDbs.cdb[3].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(tx,keyLen 32 as 33)", ela):
          let dbTx = tdb.beginTransaction
          defer: dbTx.commit

          for (key,val) in xTab32.pairs:
            tdb.put(@[99.byte] & key.toSeq, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab32.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab32.len, ", ",
            "perRecord=", perRec.pp

      # cdb[4] -- direct db, key length 33, no transaction
      test &"Directly store {xTab33.len} records " &
          &"(key length 33) into {emptyDb} trie database":
        var ela: Duration
        let tdb = xDbs.cdb[4].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(keyLen 33)", ela):
          for (key,val) in xTab33.pairs:
            tdb.put(key, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab33.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab33.len, ", ",
            "perRecord=", perRec.pp

      # cdb[5] -- direct db, key length 33, transaction based
      test &"Transactionally store {xTab33.len} records " &
          &"(key length 33) into {emptyDb} trie database":
        var ela: Duration
        let tdb = xDbs.cdb[5].trieDB

        if noisy: echo ""
        noisy.showElapsed("Standard db loader(tx,keyLen 33)", ela):
          let dbTx = tdb.beginTransaction
          defer: dbTx.commit

          for (key,val) in xTab33.pairs:
            tdb.put(key, val)

        if ela.inNanoseconds != 0:
          let
            elaNs = ela.inNanoseconds.float
            perRec = ((elaNs / xTab33.len.float) + 0.5).int.initDuration
          noisy.say "***",
            "nRecords=", xTab33.len, ", ",
            "perRecord=", perRec.pp

      if xDbs.cdb[0].rocksStoreRef.isNil:
        test "The rocksdb interface must be available": skip() 
      else:
        # cdb[6] -- rocksdb, key length 32
        test &"Store {xTab32.len} records " &
            "(key length 32) into empty rocksdb table":
          var
            ela: array[4,Duration]
            size: int64
          let
            rdb = xDbs.cdb[6].rocksStoreRef

          # Note that 32 and 33 size keys cannot be usefiully merged into the
          # same SST file. The keys must be added in a sorted mode. So playing
          # safe, key sizes should be of
          # equal length.

          if noisy: echo ""
          noisy.showElapsed("Rocky bulk loader(keyLen 32)", ela[0]):
            let bulker = RockyBulkLoadRef.init(rdb)
            defer: bulker.destroy()
            check bulker.begin("rocky-bulk-cache")

            var
              keyList = newSeq[NodeTag](xTab32.len)

            fullNoise.showElapsed("Rocky bulk loader/32, sorter", ela[1]):
              var inx = 0
              for key in xTab32.keys:
                keyList[inx] = key.to(NodeTag)
                inx.inc
              keyList.sort(cmp)

            fullNoise.showElapsed("Rocky bulk loader/32, append", ela[2]):
              for n,nodeTag in keyList:
                let key = nodeTag.to(Blob)
                check bulker.add(key, xTab32[key.to(ByteArray32)])

            fullNoise.showElapsed("Rocky bulk loader/32, slurp", ela[3]):
              let rc = bulker.finish()
              if rc.isOk:
                 size = rc.value
              else:
                check bulker.lastError == "" # force printing error

          fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
          if ela[0].inNanoseconds != 0:
            let
              elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
              elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
              perRec = ((elaNs[0] / xTab32.len.float) + 0.5).int.initDuration
            noisy.say "***",
              "nRecords=", xTab32.len, ", ",
              "perRecord=", perRec.pp, ", ",
              "sstSize=", size.uint64.toSI, ", ",
              "perRecord=", ((size.float / xTab32.len.float) + 0.5).int, ", ",
             ["Total","Sorter","Append","Ingest"].zip(elaPc).ppKvPc

        # cdb[7] -- rocksdb, key length 32 as 33
        test &"Store {xTab32.len} records " &
            "(key length 33) into empty rocksdb table":
          var
            ela: array[4,Duration]
            size: int64
          let
            rdb = xDbs.cdb[7].rocksStoreRef

          # Note that 32 and 33 size keys cannot be usefiully merged into the
          # same SST file. The keys must be added in a sorted mode. So playing
          # safe, key sizes should be of
          # equal length.

          if noisy: echo ""
          noisy.showElapsed("Rocky bulk loader(keyLen 32 as 33)", ela[0]):
            let bulker = RockyBulkLoadRef.init(rdb)
            defer: bulker.destroy()
            check bulker.begin("rocky-bulk-cache")

            var
              keyList = newSeq[NodeTag](xTab32.len)

            fullNoise.showElapsed("Rocky bulk loader/32 as 33, sorter", ela[1]):
              var inx = 0
              for key in xTab32.keys:
                keyList[inx] = key.to(NodeTag)
                inx.inc
              keyList.sort(cmp)

            fullNoise.showElapsed("Rocky bulk loader/32 as 33, append", ela[2]):
              for n,nodeTag in keyList:
                let key = nodeTag.to(Blob)
                check bulker.add(@[99.byte] & key, xTab32[key.to(ByteArray32)])

            fullNoise.showElapsed("Rocky bulk loader/32 as 33, slurp", ela[3]):
              let rc = bulker.finish()
              if rc.isOk:
                 size = rc.value
              else:
                check bulker.lastError == "" # force printing error

          fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
          if ela[0].inNanoseconds != 0:
            let
              elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
              elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
              perRec = ((elaNs[0] / xTab32.len.float) + 0.5).int.initDuration
            noisy.say "***",
              "nRecords=", xTab32.len, ", ",
              "perRecord=", perRec.pp, ", ",
              "sstSize=", size.uint64.toSI, ", ",
              "perRecord=", ((size.float / xTab32.len.float) + 0.5).int, ", ",
             ["Total","Sorter","Append","Ingest"].zip(elaPc).ppKvPc


        # cdb[8] -- rocksdb, key length 33
        test &"Store {xTab33.len} records " &
            &"(key length 33) into {emptyDb} rocksdb table":
          var
            ela: array[4,Duration]
            size: int64
          let rdb = xDbs.cdb[8].rocksStoreRef

          # Note that 32 and 33 size keys cannot be usefiully merged into the
          # same SST file. The keys must be added in a sorted mode. So playing
          # safe, key sizes should be of equal length.

          if noisy: echo ""
          noisy.showElapsed("Rocky bulk loader(keyLen 33)", ela[0]):
            let bulker = RockyBulkLoadRef.init(rdb)
            defer: bulker.destroy()
            check bulker.begin("rocky-bulk-cache")

            var
              kKeys: seq[byte] # need to cacscade
              kTab: Table[byte,seq[NodeTag]]

            fullNoise.showElapsed("Rocky bulk loader/33, sorter", ela[1]):
              for key in xTab33.keys:
                if kTab.hasKey(key[0]):
                  kTab[key[0]].add key.toOpenArray(1,32).to(NodeTag)
                else:
                  kTab[key[0]] = @[key.toOpenArray(1,32).to(NodeTag)]

              kKeys = toSeq(kTab.keys).sorted
              for w in kKeys:
                kTab[w].sort(cmp)

            fullNoise.showElapsed("Rocky bulk loader/33, append", ela[2]):
              for w in kKeys:
                fullNoise.say "***", " prefix=", w, " entries=", kTab[w].len
                for n,nodeTag in kTab[w]:
                  let key = (w,nodeTag).to(Blob)
                  check bulker.add(key, xTab33[key.to(ByteArray33)])

            fullNoise.showElapsed("Rocky bulk loader/33, slurp", ela[3]):
              let rc = bulker.finish()
              if rc.isOk:
                 size = rc.value
              else:
                check bulker.lastError == "" # force printing error

          fullNoise.say "***", " ela[]=", $ela.toSeq.mapIt(it.pp)
          if ela[0].inNanoseconds != 0:
            let
              elaNs = ela.toSeq.mapIt(it.inNanoseconds.float)
              elaPc = elaNs.mapIt(((it / elaNs[0]) * 100 + 0.5).int)
              perRec = ((elaNs[0] / xTab33.len.float) + 0.5).int.initDuration
            noisy.say "***",
              "nRecords=", xTab33.len, ", ",
              "perRecord=", perRec.pp, ", ",
              "sstSize=", size.uint64.toSI, ", ",
              "perRecord=", ((size.float / xTab33.len.float) + 0.5).int, ", ",
              ["Total","Cascaded-Sorter","Append","Ingest"].zip(elaPc).ppKvPc

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc syncSnapMain*(noisy = defined(debug)) =
  # Caveat: running `accountsRunner(persistent=true)` twice will crash as the
  #         persistent database might not be fully cleared due to some stale
  #         locks.
  noisy.accountsRunner(persistent=true)
  noisy.accountsRunner(persistent=false)
  noisy.importRunner() # small sample, just verify functionality
  noisy.storeRunner()

when isMainModule:
  const
    noisy = defined(debug) or true

    # Some 20 `snap/1` reply equivalents
    snapTest0 =
      accSample0

    # Only the the first `snap/1` reply from the sample
    snapTest1 = AccountsSample(
      name: "test1",
      file: snapTest0.file,
      lastItem: 0)

    # Ditto for sample1
    snapTest2 = AccountsSample(
      name: "test2",
      file: "sample1.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapTest3 = AccountsSample(
      name: "test3",
      file: snapTest2.file,
      lastItem: 0)

    # Other samples from bulk folder
    snapOther0a = AccountsSample(
      name: "Other0a",
      file: "account0_00_06_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapOther0b = AccountsSample(
      name: "Other0b",
      file: "account0_07_08_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapOther1a = AccountsSample(
      name: "Other1a",
      file: "account1_09_09_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapOther1b = AccountsSample(
      name: "Other1b",
      file: "account1_10_17_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapOther2 = AccountsSample(
      name: "Other2",
      file: "account2_18_25_dump.txt.gz",
      firstItem: 1,
      lastItem: high(int))
    snapOther3 = AccountsSample(
      name: "Other3",
      file: "account3_26_33_dump.txt.gz",
      firstItem: 2,
      lastItem: high(int))
    snapOther4 = AccountsSample(
      name: "Other4",
      file: "account4_34_41_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))
    snapOther5 = AccountsSample(
      name: "Other5",
      file: "account5_42_49_dump.txt.gz",
      firstItem: 2,
      lastItem: high(int))
    snapOther6 = AccountsSample(
      name: "Other6",
      file: "account6_50_54_dump.txt.gz",
      firstItem: 0,
      lastItem: high(int))

    bulkTest0 = goerliCapture
    bulkTest1: CaptureSpecs = (
      name:      "full-goerli",
      network:   goerliCapture.network,
      file:      goerliCapture.file,
      numBlocks: high(int))
    bulkTest2: CaptureSpecs = (
      name:      "more-goerli",
      network:   GoerliNet,
      file:      "goerli482304.txt.gz",
      numBlocks: high(int))
    bulkTest3: CaptureSpecs = (
      name:      "mainnet",
      network:   MainNet,
      file:      "mainnet332160.txt.gz",
      numBlocks: high(int))

  #setTraceLevel()
  setErrorLevel()

  # The `accountsRunner()` tests a snap sync functionality for storing chain
  # chain data directly rather than derive them by executing the EVM. Here,
  # only accounts are considered.
  #
  # The `snap/1` protocol allows to fetch data for a certain account range. The
  # following boundary conditions apply to the received data:
  #
  # * `State root`: All data are relaive to the same state root.
  #
  # * `Accounts`: There is an accounts interval sorted in strictly increasing
  #   order. The accounts are required consecutive, i.e. without holes in
  #   between although this cannot be verified immediately.
  #
  # * `Lower bound`: There is a start value which might be lower than the first
  #   account hash. There must be no other account between this start value and
  #   the first account (not verifyable yet.) For all practicat purposes, this
  #   value is mostly ignored but carried through.
  #
  # * `Proof`: There is a list of hexary nodes which allow to build a partial
  #   Patricia-Mercle trie starting at the state root with all the account
  #   leaves. There are enough nodes that show that there is no account before
  #   the least account (which is currently ignored.)
  #    
  # There are test data samples on the sub-directory `test_sync_snap`. These
  # are complete replies for some (admittedly smapp) test requests from a `kiln`
  # session.
  #
  # The `accountsRunner()` does three tests:
  #
  # 1. Run the `importAccounts()` function which is the all-in-one production
  #    function processoing the data described above. The test applies it
  #    sequentially to about 20 data sets.
  #
  # 2. Test individual functional items which are hidden in test 1. while
  #    merging the sample data. 
  #    * Load/accumulate `proofs` data from several samples
  #    * Load/accumulate accounts (needs some unique sorting)
  #    * Build/complete hexary trie for accounts
  #    * Save/bulk-store hexary trie on disk. If rocksdb is available, data
  #      are bulk stored via sst. An additional data set is stored in a table
  #      with key prefix 200 using transactional `put()` (for time comparison.)
  #      If there is no rocksdb, standard transactional `put()` is used, only
  #      (no key prefix 200 storage.)
  #
  # 3. Traverse trie nodes stored earlier. The accounts from test 2 are
  #    re-visted using the account hash as access path.
  #

  noisy.showElapsed("accountsRunner()"):
    #false.accountsRunner(persistent=true, snapOther0a)
    false.accountsRunner(persistent=true, snapOther0b)
    #false.accountsRunner(persistent=true, snapOther1a)
    #false.accountsRunner(persistent=true, snapOther1b)
    #false.accountsRunner(persistent=true, snapOther2)
    #false.accountsRunner(persistent=true, snapOther3)
    #false.accountsRunner(persistent=true, snapOther4)
    #false.accountsRunner(persistent=true, snapOther5)
    #false.accountsRunner(persistent=true, snapOther6)

    false.accountsRunner(persistent=true,  snapTest0)
    #noisy.accountsRunner(persistent=true,  snapTest1)
    false.accountsRunner(persistent=true,  snapTest2)
    #noisy.accountsRunner(persistent=true,  snapTest3)
    discard

  when true: # and false:
    # ---- database storage timings -------

    noisy.showElapsed("importRunner()"):
      noisy.importRunner(capture = bulkTest0)

    noisy.showElapsed("storeRunner()"):
      true.storeRunner(cleanUp = false)
      true.storeRunner()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
