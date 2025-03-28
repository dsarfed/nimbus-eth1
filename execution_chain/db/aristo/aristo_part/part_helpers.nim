# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sets, sequtils],
  eth/common,
  results,
  ".."/[aristo_desc, aristo_get, aristo_vid],
  ./part_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc read(rlp: var Rlp; T: type PrfNode): T {.gcsafe, raises: [RlpError].} =
  ## Mixin for RLP reader. The decoder with error return code in a `Leaf`
  ## node if needed.
  ##
  func readError(error: AristoError): PrfNode =
    ## Prettify return code expression
    PrfNode(vtx: VertexRef(vType: Leaf), prfType: isError, error: error)

  if not rlp.isList:
    # Otherwise `rlp.items` would raise a `Defect`
    return readError(PartRlp2Or17ListEntries)

  var
    blobs = newSeq[seq[byte]](2)         # temporary, cache
    links: array[16,HashKey]        # reconstruct branch node
    top = 0                         # count entries and positions

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return readError(PartRlpBlobExpected)
      blobs[top] = rlp.read(seq[byte])
    of 2 .. 15:
      let blob = rlp.read(seq[byte])
      links[top] = HashKey.fromBytes(blob).valueOr:
        return readError(PartRlpBranchHashKeyExpected)
    of 16:
      if not w.isBlob or 0 < rlp.read(seq[byte]).len:
        return readError(PartRlpEmptyBlobExpected)
    else:
      return readError(PartRlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return readError(PartRlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = NibblesBuf.fromHexPrefix blobs[0]
    if isLeaf:
      return PrfNode(
        prfType:   ignore, )

        # TODO interpret the blob (?)
        # vtx: VertexRef(
        #   vType:     Leaf,
        #   pfx:      pathSegment,
        #   lData:     LeafPayload(
        #     pType:   RawData,
        #     rawBlob: blobs[1])))
    else:
      var node = PrfNode(
        prfType: isExtension,
        vtx: VertexRef(
          vType:   Branch,
          pfx:    pathSegment))
      node.key[0] = HashKey.fromBytes(blobs[1]).valueOr:
        return readError(PartRlpExtHashKeyExpected)
      return node
  of 17:
    for n in [0,1]:
      links[n] = HashKey.fromBytes(blobs[n]).valueOr:
        return readError(PartRlpBranchHashKeyExpected)
    return PrfNode(
      vtx: VertexRef(
        vType:   Branch),
      prfType: ignore,
      key:     links)
  else:
    discard

  readError(PartRlp2Or17ListEntries)

proc read(rlp: var Rlp; T: type PrfPayload): T {.gcsafe, raises: [RlpError].} =
  ## Mixin for RLP reader decoding `Account` or storage slot payload.
  ##
  case rlp.listLen:
  of 1:
    result.prfType = isStoValue
    result.num = rlp.read UInt256
  of 4:
    result.prfType = isAccount
    result.acc = rlp.read Account
  else:
    result.prfType = isError
    result.error = PartRlp1r4ListEntries

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func toNodesTab*(
    proof: openArray[seq[byte]];                # List of RLP encoded nodes
    mode: PartStateMode;                        # How to decode `Leaf` nodes
      ): Result[TableRef[HashKey,PrfNode],AristoError] =
  ## Convert RLP encoded argument list `proof` to a nodes table indexed by
  ## the `HashKey` values of the `proof` list entries.
  var
    exts: Table[HashKey,PrfNode] # need to be processed separately
    nodes = newTable[HashKey,PrfNode]()

  # populate tables
  for w in proof:
    # Decode blob `w`
    let nd = block:
      try: rlp.decode(w, PrfNode)
      except RlpError:
        return err(PartRlpNodeException)

    case nd.prfType:
    of isExtension:
      # For a moment, hold extensions on a separate cache
      exts[w.digestTo HashKey] = nd

    of ignore:
      # Store `Branch` and `Leaf` nodes in final lookup table
      nodes[w.digestTo HashKey] = nd

      # Special decoding for account `Leaf` nodes
      if nd.vtx.vType == Leaf and mode != ForceGenericPayload:
        # Decode payload to deficated format for storage or accounts
        var pyl: PrfPayload
        try:
          # TODO interpret the blob
          # pyl = rlp.decode(nd.vtx.lData.rawBlob, PrfPayload)
          pyl = PrfPayload(prfType: isError, error: PartRlpPayloadException)
        except RlpError:
          pyl = PrfPayload(prfType: isError, error: PartRlpPayloadException)

        case pyl.prfType:
        of isStoValue:
          # Single value encoding might not be unique so it cannot be
          # automatically detected
          if mode != AutomaticPayload:
            nd.vtx.lData = LeafPayload(pType: StoData, stoData: pyl.num)
        of isAccount:
          nd.key[0] = pyl.acc.storageRoot.to(HashKey)
          nd.vtx.lData = LeafPayload(
            pType:   AccountData,
            account: AristoAccount(
              nonce:    pyl.acc.nonce,
              balance:  pyl.acc.balance,
              codeHash: pyl.acc.codeHash))
        elif mode == AutomaticPayload:
          discard
        else:
          return err(pyl.error)
    else:
      return err(nd.error)

  # Postprocess extension nodes
  for (xKey,xNode) in exts.pairs:
    # Combine `xNode + nodes[w.ePfx]`
    let nd = nodes.getOrDefault xNode.key[0]
    if nd.isNil:
      # Need to store raw extension
      nodes[xKey] = xNode
      continue
    if nd.vtx.pfx.len != 0:
      return err(PartGarbledExtsInProofs)
    # Move extended `nd` branch node
    nd.prfType = ignore
    nd.vtx.pfx = xNode.vtx.pfx
    nodes.del xNode.key[0]
    nodes[xKey] = nd

  ok nodes


proc backLinks*(nTab: TableRef[HashKey,PrfNode]): PrfBackLinks =
  ## tuple[chains: seq[seq[HashKey]], links: Table[HashKey,HashKey]] =
  ## Classify argument table
  ##
  ## * chains: key list of back chains
  ## * links: `(child,parent)` lookup table
  ##
  new result

  # Collect predecessor list
  for (key,nd) in nTab.pairs:
    if nd.vtx.vType == Leaf:
      if nd.vtx.lData.pType == AccountData and nd.key[0].isValid:
        result.links[nd.key[0]] = key
    elif nd.prfType == isExtension:
      result.links[nd.key[0]] = key
    else:
      for w in nd.key:
        if w.isValid:
          result.links[w] = key

  # Compute leafs list, i.e. keys without children in `nTab[]`
  var leafs = nTab.keys.toSeq.toHashSet
  for (child,parent) in result.links.pairs:
    if child in nTab:
      leafs.excl parent # `parent` has `child` => not a leaf

  # Compute chains starting at leafs
  for leaf in leafs:
    var q = @[leaf]
    while true:
      let up = result.links.getOrVoid q[^1]
      if up.isValid:
        q.add up
      else:
        break
    result.chains.add q


proc getTreeRootVid*(
    ps: PartStateRef;
    key: HashKey;
      ): Result[VertexID,AristoError] =
  ## Find root ID in `ps[]` or create a new ID
  ##
  # Use root from `ps` descriptor
  let rvid = ps[key]
  if rvid.isValid:
    return ok(rvid.vid)

  # Try next free VID
  for n in 2 .. LEAST_FREE_VID:
    let rvid = (VertexID(n),VertexID(n))
    if not ps.db.getVtx(rvid).isValid:
      ps[key] = rvid
      return ok(VertexID n)

  err(PartNoMoreRootVidsLeft)


proc getRvid*(
    ps: PartStateRef;
    root: VertexID;
    key: HashKey;
      ): Result[tuple[rvid: RootedVertexID, fromLedger: bool],AristoError] =
  ## Find key in `ps[]` or create a new key. the value `onStateDb` is
  ## return `false` if a new entry was created.
  ##
  var (rvid, fromLedger) = (ps[key], true)
  if not rvid.isValid:
    # Create new one
    (rvid, fromLedger) = ((root, ps.db.vidFetch()), false)
    ps[key] = rvid
  elif root != rvid.root:
    # Oops
    return err(PartRootVidsDontMatch)
  ok((rvid, fromLedger))


proc updateAccountsTree*(
    ps: PartStateRef;                         # Partial database descriptor
    nodes: TableRef[HashKey,PrfNode];         # Node lookup table
    bl: PrfBackLinks;                         # Uplink lists
    mode: PartStateMode;                      # Try accounts, otherwise generic
     ): Result[void,AristoError] =
  ## Check wether the chain has an accounts leaf node and update the
  ## argument descriptor `ps` accordingly.
  ##
  if mode == ForceGenericPayload or VertexID(1) in ps.core:
    return ok()

  var accRootKey = VOID_HASH_KEY
  for chain in bl.chains:
    for key in chain:
      nodes[].withValue(key,node):
        if node.vtx.vType == Leaf and node.vtx.lData.pType == AccountData:

          # Ok, got an accounts leaf node
          if not accRootKey.isValid:
            # Register accounts root
            accRootKey = chain[^1]
            ps[accRootKey] = (VertexID(1),VertexID(1))
          elif accRootKey != chain[^1]:
            # Two account chains with different root keys
            return err(PartRootKeysDontMatch)

          # Register storage root (if any)
          if node.key[0].isValid:
            let vid = ps.db.vidFetch()
            ps[node.key[0]] = (vid,vid)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
