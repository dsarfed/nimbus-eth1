# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[strutils, syncio],
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../common,
  ./worker/update/[metrics, ticker],
  ./worker/[blocks_staged, headers_staged, headers_unproc, start_stop, update],
  ./worker_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc headersToFetchOk(buddy: BeaconBuddyRef): bool =
  0 < buddy.ctx.headersUnprocAvail() and
    buddy.ctrl.running and
    not buddy.ctx.poolMode

proc bodiesToFetchOk(buddy: BeaconBuddyRef): bool =
  buddy.ctx.blocksStagedFetchOk() and
    buddy.ctrl.running and
    not buddy.ctx.poolMode

proc napUnlessSomethingToFetch(
    buddy: BeaconBuddyRef;
      ): Future[bool] {.async: (raises: []).} =
  ## When idle, save cpu cycles waiting for something to do.
  if buddy.ctx.pool.blkImportOk or               # currently importing blocks
     buddy.ctx.hibernate or                      # not activated yet?
     not (buddy.headersToFetchOk() or            # something on TODO list
          buddy.bodiesToFetchOk()):
    try:
      await sleepAsync workerIdleWaitInterval
    except CancelledError:
      buddy.ctrl.zombie = true
    return true
  else:
    # Returning `false` => no need to check for shutdown
    return false

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Global set up
  ctx.setupServices info

  # Load initial state from database if there is any
  ctx.setupDatabase info
  true

proc release*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global clean up
  ctx.destroyServices()


proc start*(buddy: BeaconBuddyRef; info: static[string]): bool =
  ## Initialise worker peer
  let
    peer = buddy.peer
    ctx = buddy.ctx

  if runsThisManyPeersOnly <= buddy.ctx.pool.nBuddies:
    if not ctx.hibernate: debug info & ": peers limit reached", peer
    return false

  if not ctx.pool.seenData and buddy.peerID in ctx.pool.failedPeers:
    if not ctx.hibernate: debug info & ": useless peer already tried", peer
    return false

  if not buddy.startBuddy():
    if not ctx.hibernate: debug info & ": failed", peer
    return false

  if not ctx.hibernate: debug info & ": new peer", peer
  true

proc stop*(buddy: BeaconBuddyRef; info: static[string]) =
  ## Clean up this peer
  if not buddy.ctx.hibernate: debug info & ": release peer", peer=buddy.peer,
    ctrl=buddy.ctrl.state, nLaps=buddy.only.nMultiLoop,
    lastIdleGap=buddy.only.multiRunIdle.toStr
  buddy.stopBuddy()

# --------------------

proc initalScrumFromFile*(
    ctx: BeaconCtxRef;
    file: string;
    info: static[string];
      ): Result[void,string] =
  ## Set up inital sprint from argument file (itended for debugging)
  var
    mesg: SyncClMesg
  try:
    var f = file.open(fmRead)
    defer: f.close()
    var rlp = rlpFromHex(f.readAll().strip)
    mesg = rlp.read(SyncClMesg)
  except CatchableError as e:
    return err("Error decoding file: \"" & file & "\"" &
      " (" & $e.name & ": " & e.msg & ")")
  ctx.clReq.mesg = mesg
  ctx.clReq.locked = true
  ctx.clReq.changed = true
  debug info & ": Initialised from file", file, consHead=mesg.consHead.bnStr,
    finalHash=mesg.finalHash.short
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runTicker*(ctx: BeaconCtxRef; info: static[string]) =
  ## Global background job that is started every few seconds. It is to be
  ## intended for updating metrics, debug logging etc.
  ctx.updateMetrics()
  ctx.updateTicker()

proc runDaemon*(
    ctx: BeaconCtxRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true` which corresponds to `ctx.hibernating` set
  ## to false`.
  ##
  ## On a fresh start, the flag `ctx.daemon` will not be set `true` before the
  ## first usable request from the CL (via RPC) stumbles in.
  ##
  # Check for a possible header layout and body request changes
  ctx.updateSyncState info
  if ctx.hibernate:
    return

  # Execute staged block records.
  if ctx.blocksStagedCanImportOk():

    block:
      # Set flag informing peers to go into idle mode while importing takes
      # place. It has been observed that importing blocks and downloading
      # at the same time does not work very well, most probably due to high
      # system activity while importing. Peers will get lost pretty soon after
      # downloading starts if they continue downloading.
      ctx.pool.blkImportOk = true
      defer: ctx.pool.blkImportOk = false

      # Import from staged queue.
      while await ctx.blocksStagedImport(info):
        if not ctx.daemon or   # Implied by external sync shutdown?
           ctx.poolMode:       # Oops, re-org needed?
          return

  # At the end of the cycle, leave time to trigger refill headers/blocks
  try: await sleepAsync daemonWaitInterval
  except CancelledError: discard


proc runPool*(
    buddy: BeaconBuddyRef;
    last: bool;
    laps: int;
    info: static[string];
      ): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as long as this function returns `false`. There will be no other
  ## `runPeer()` functions activated while `runPool()` is active.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) The flag will be automatically reset before
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `laps` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  buddy.ctx.headersStagedReorg info
  buddy.ctx.blocksStagedReorg info
  true # stop


proc runPeer*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## This peer worker method is repeatedly invoked (exactly one per peer) while
  ## the `buddy.ctrl.poolMode` flag is set `false`.
  ##
  if 0 < buddy.only.nMultiLoop:                 # statistics/debugging
    buddy.only.multiRunIdle = Moment.now() - buddy.only.stoppedMultiRun
  buddy.only.nMultiLoop.inc                     # statistics/debugging

  # Wake up from hibernating if there is a new `CL` scrum target available.
  # Note that this check must be done on a peer and the `Daemon` is not
  # running while thr system is hibernating.
  buddy.updateFromHibernatingForNextScrum info

  if not await buddy.napUnlessSomethingToFetch():

    # Download and process headers and blocks
    while buddy.headersToFetchOk():

      # Collect headers and either stash them on the header chain cache
      # directly, or stage then on the header queue to get them serialised,
      # later.
      if await buddy.headersStagedCollect info:

        # Store headers from the `staged` queue onto the header chain cache.
        buddy.headersStagedProcess info

    # Fetch bodies and combine them with headers to blocks to be staged. These
    # staged blocks are then excuted by the daemon process (no `peer` needed.)
    while buddy.bodiesToFetchOk():
      discard await buddy.blocksStagedCollect info

    # Note that it is important **not** to leave this function to be
    # re-invoked by the scheduler unless necessary. While the time gap
    # until restarting is typically a few millisecs, there are always
    # outliers which well exceed several seconds. This seems to let
    # remote peers run into timeouts so they eventually get lost early.

  buddy.only.stoppedMultiRun = Moment.now()     # statistics/debugging

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
