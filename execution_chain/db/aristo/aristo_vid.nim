# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Handle vertex IDs on the layered Aristo DB delta architecture
## =============================================================
##
{.push raises: [].}

import
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoTxRef, n = 1): VertexID =
  ## Fetch next vertex ID.
  ##
  if db.vTop  == 0:
    db.vTop = VertexID(LEAST_FREE_VID)
  var ret = db.vTop
  ret.inc
  db.vTop.inc(n)
  ret

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
