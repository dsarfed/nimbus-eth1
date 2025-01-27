# Fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  metrics,
  eth/common/hashes,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../database/content_db,
  ../history/history_network,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config, ping_extensions],
  ./state_content,
  ./state_validation,
  ./state_gossip

export results, state_content, hashes

logScope:
  topics = "portal_state"

declareCounter state_network_offers_success,
  "Portal state network offers successfully validated", labels = ["protocol_id"]
declareCounter state_network_offers_failed,
  "Portal state network offers which failed validation", labels = ["protocol_id"]

const pingExtensionCapabilities = {CapabilitiesType, BasicRadiusType}

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  processContentLoop: Future[void]
  statusLogLoop: Future[void]
  historyNetwork: Opt[HistoryNetwork]
  validateStateIsCanonical: bool
  contentRequestRetries: int

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc new*(
    T: type StateNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
    historyNetwork = Opt.none(HistoryNetwork),
    validateStateIsCanonical = true,
    contentRequestRetries = 1,
): T =
  let
    cq = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)
    s = streamManager.registerNewStream(cq)
    portalProtocol = PortalProtocol.new(
      baseProtocol,
      getProtocolId(portalNetwork, PortalSubnetwork.state),
      toContentIdHandler,
      createGetHandler(contentDB),
      createStoreHandler(contentDB, portalConfig.radiusConfig),
      createContainsHandler(contentDB),
      createRadiusHandler(contentDB),
      s,
      bootstrapRecords,
      config = portalConfig,
      pingExtensionCapabilities = pingExtensionCapabilities,
    )

  StateNetwork(
    portalProtocol: portalProtocol,
    contentQueue: cq,
    historyNetwork: historyNetwork,
    validateStateIsCanonical: validateStateIsCanonical,
    contentRequestRetries: contentRequestRetries,
  )

proc getContent(
    n: StateNetwork,
    key: ContentKeyType,
    V: type ContentRetrievalType,
    maybeParentOffer: Opt[ContentOfferType],
): Future[Opt[V]] {.async: (raises: [CancelledError]).} =
  let
    contentKeyBytes = key.toContentKey().encode()
    contentId = contentKeyBytes.toContentId()
    maybeLocalContent = n.portalProtocol.getLocalContent(contentKeyBytes, contentId)

  if maybeLocalContent.isSome():
    let contentValue = V.decode(maybeLocalContent.get()).valueOr:
      raiseAssert("Unable to decode state local content value")

    debug "Fetched state local content value"
    return Opt.some(contentValue)

  for i in 0 ..< (1 + n.contentRequestRetries):
    let
      lookupRes = (await n.portalProtocol.contentLookup(contentKeyBytes, contentId)).valueOr:
        warn "Failed fetching state content from the network"
        return Opt.none(V)
      contentValueBytes = lookupRes.content

    let contentValue = V.decode(contentValueBytes).valueOr:
      error "Unable to decode state content value from content lookup"
      continue

    validateRetrieval(key, contentValue).isOkOr:
      error "Validation of retrieved state content failed"
      continue

    debug "Fetched valid state content from the network"
    n.portalProtocol.storeContent(
      contentKeyBytes, contentId, contentValueBytes, cacheContent = true
    )

    if maybeParentOffer.isSome() and lookupRes.nodesInterestedInContent.len() > 0:
      debug "Sending content to interested nodes",
        interestedNodesCount = lookupRes.nodesInterestedInContent.len()

      let offer = contentValue.toOffer(maybeParentOffer.get())
      n.portalProtocol.triggerPoke(
        lookupRes.nodesInterestedInContent, contentKeyBytes, offer.encode()
      )

    return Opt.some(contentValue)

  # Content was requested `1 + requestRetries` times and all failed on validation
  Opt.none(V)

proc getAccountTrieNode*(
    n: StateNetwork,
    key: AccountTrieNodeKey,
    maybeParentOffer = Opt.none(AccountTrieNodeOffer),
): Future[Opt[AccountTrieNodeRetrieval]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  n.getContent(key, AccountTrieNodeRetrieval, maybeParentOffer)

proc getContractTrieNode*(
    n: StateNetwork,
    key: ContractTrieNodeKey,
    maybeParentOffer = Opt.none(ContractTrieNodeOffer),
): Future[Opt[ContractTrieNodeRetrieval]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  n.getContent(key, ContractTrieNodeRetrieval, maybeParentOffer)

proc getContractCode*(
    n: StateNetwork,
    key: ContractCodeKey,
    maybeParentOffer = Opt.none(ContractCodeOffer),
): Future[Opt[ContractCodeRetrieval]] {.async: (raw: true, raises: [CancelledError]).} =
  n.getContent(key, ContractCodeRetrieval, maybeParentOffer)

proc getBlockHeaderByBlockNumOrHash*(
    n: StateNetwork, blockNumOrHash: uint64 | Hash32
): Future[Opt[Header]] {.async: (raises: [CancelledError]).} =
  let hn = n.historyNetwork.valueOr:
    warn "History network is not available"
    return Opt.none(Header)

  let header = (await hn.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
    warn "Failed to get block header from history", blockNumOrHash
    return Opt.none(Header)

  Opt.some(header)

proc processOffer*(
    n: StateNetwork,
    maybeSrcNodeId: Opt[NodeId],
    contentKeyBytes: ContentKeyByteList,
    contentValueBytes: seq[byte],
    contentKey: AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey,
    V: type ContentOfferType,
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let
    contentValue = V.decode(contentValueBytes).valueOr:
      return err("Unable to decode offered content value")
    validationRes =
      if n.validateStateIsCanonical:
        let header = (await n.getBlockHeaderByBlockNumOrHash(contentValue.blockHash)).valueOr:
          return err("Failed to get block header by hash")
        validateOffer(Opt.some(header.stateRoot), contentKey, contentValue)
      else:
        # Skip state root validation
        validateOffer(Opt.none(Hash32), contentKey, contentValue)

  if validationRes.isErr():
    return err("Offered content failed validation: " & validationRes.error())

  let contentId = n.portalProtocol.toContentId(contentKeyBytes).valueOr:
    return err("Received offered content with invalid content key")

  n.portalProtocol.storeContent(
    contentKeyBytes, contentId, contentValue.toRetrieval().encode()
  )

  await gossipOffer(
    n.portalProtocol, maybeSrcNodeId, contentKeyBytes, contentValueBytes
  )

  ok()

proc processContentLoop(n: StateNetwork) {.async: (raises: []).} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentValues) = await n.contentQueue.popFirst()

      for i, contentBytes in contentValues:
        let
          contentKeyBytes = contentKeys[i]
          contentKey = ContentKey.decode(contentKeyBytes).valueOr:
            error "Unable to decode offered content key", contentKeyBytes
            continue

          offerRes =
            case contentKey.contentType
            of unused:
              error "Received content with unused content type"
              continue
            of accountTrieNode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes, contentKey.accountTrieNodeKey,
                AccountTrieNodeOffer,
              )
            of contractTrieNode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes,
                contentKey.contractTrieNodeKey, ContractTrieNodeOffer,
              )
            of contractCode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes, contentKey.contractCodeKey,
                ContractCodeOffer,
              )

        if offerRes.isOk():
          state_network_offers_success.inc(labelValues = [$n.portalProtocol.protocolId])
          debug "Received offered content validated successfully",
            srcNodeId, contentKeyBytes
        else:
          state_network_offers_failed.inc(labelValues = [$n.portalProtocol.protocolId])
          error "Received offered content failed validation",
            srcNodeId, contentKeyBytes, error = offerRes.error()
  except CancelledError:
    trace "processContentLoop canceled"

proc statusLogLoop(n: StateNetwork) {.async: (raises: []).} =
  try:
    while true:
      info "State network status",
        routingTableNodes = n.portalProtocol.routingTable.len()

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: StateNetwork) =
  info "Starting Portal execution state network",
    protocolId = n.portalProtocol.protocolId

  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)
  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: StateNetwork) {.async: (raises: []).} =
  info "Stopping Portal execution state network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  if not n.processContentLoop.isNil():
    futures.add(n.processContentLoop.cancelAndWait())
  if not n.statusLogLoop.isNil():
    futures.add(n.statusLogLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  n.processContentLoop = nil
  n.statusLogLoop = nil
