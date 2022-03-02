# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stint, 
  stew/[byteutils, results], 
  eth/[common/eth_types, rlp],
  ../network/history/history_network

let blockBytes = "0xf910baf90218a07d7701cadd868037f2d6e2898fcaa03e9e892dfac9f85d046b00bcf6bb786ad9a0bf34d0addf61b0e6cd483d6396cadaae438346dc5d8e0a0f3d9135b52a0f11a1944bb96091ee9d802ed039c4d1a5f6216f90f81b01a030e3d6c1021ecb806a1022e07f6e1491a5a2c17f3aaa9efbe1afe2325f9ba241a0fcf98a24af539c43988cec8e157ceec62b6c3ffa7ccc62c41e6b5d63d7af9e24a058656d3e1b463465ded49b02b74ec7dc6700870b5fafee285b49ac5789c39f46b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000860acef5f96bd8830f1b40832fefd883075e308456bd199d98d783010400844765746887676f312e352e31856c696e7578a0ea6f705561212f5523522114b40c77fc735a159eafb0d2c9f134ae33b8e4915088e67c3494e678ba87f90c7ef86e8204ee85746a528800825208944d15e32435180fa21907e0d23a4c0021415fc21f88016345785d8a0000801ba04eeb6205a94672c865a68f7962ab0a4f4d5e152ea0b2ce3fa9821776a6e4d7fea0597fa300bf2dfa6b5631062d119a3b1c407e3a2ca5b2e3c4af4cd597f8aab0e8f907ed8227ac85104c533c00830f4240941194e966965418c7d73a42cceeb254d87586035601b90784d5064ed1000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000005200000000000000000000000000000000000000000000000000000000000000012455552555344000000000000000000000000000000000000000000000000000047425055534400000000000000000000000000000000000000000000000000005553444a505900000000000000000000000000000000000000000000000000005841555553440000000000000000000000000000000000000000000000000000584147555344000000000000000000000000000000000000000000000000000053503530300000000000000000000000000000000000000000000000000000004e415344415100000000000000000000000000000000000000000000000000004141504c00000000000000000000000000000000000000000000000000000000474f4f47000000000000000000000000000000000000000000000000000000004d53465400000000000000000000000000000000000000000000000000000000474d0000000000000000000000000000000000000000000000000000000000004745000000000000000000000000000000000000000000000000000000000000574d54000000000000000000000000000000000000000000000000000000000046000000000000000000000000000000000000000000000000000000000000005400000000000000000000000000000000000000000000000000000000000000555344545f455448000000000000000000000000000000000000000000000000555344545f4254430000000000000000000000000000000000000000000000004254435f45544800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000001144b400000000000000000000000000000000000000000000000000000000001617dc0000000000000000000000000000000000000000000000000000000006b3d5e8000000000000000000000000000000000000000000000000000000004a324b740000000000000000000000000000000000000000000000000000000000f0ebc8000000000000000000000000000000000000000000000000000000006d058bc0000000000000000000000000000000000000000000000000000000007fffffff000000000000000000000000000000000000000000000000000000000595bfa00000000000000000000000000000000000000000000000000000000028b76e700000000000000000000000000000000000000000000000000000000002f6359000000000000000000000000000000000000000000000000000000000019a76200000000000000000000000000000000000000000000000000000000001a2da900000000000000000000000000000000000000000000000000000000003e4b43f0000000000000000000000000000000000000000000000000000000000aa70d0000000000000000000000000000000000000000000000000000000000228855000000000000000000000000000000000000000000000000000000000005b8d80000000000000000000000000000000000000000000000000000000001724398f0000000000000000000000000000000000000000000000000000000000003e5000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19780000000000000000000000000000000000000000000000000000000056bd19800000000000000000000000000000000000000000000000000000000056bd19800000000000000000000000000000000000000000000000000000000056bd19801ca01c66b2eb640b6af2df8c10de464eb08dd3a7ebfa808a9a3e285ba4efc98eabc7a00ee135bb46d3e99077e623aac3c5d9a5d46bf7665a75f2cf8cb561eb18a71895f86f820fee850ba43b740082562294fbd95cee484181c01b519906a953624acffb7172890fb5eaaf9d05c44800801ca0a20d248c7cf304b6464d5814c856b547ebf769fccf0080a0910d477f78f758fca00ee62d774a181a917e8555b60e418e496aed05421ed1ec8bed45ede7c1967474f87083028717850ba43b740083015f9094354662bcd38883b6e67497f06fc4fee20339e57488540791be2c8a5c00801ba067550f26c0bbf939532d93c25418dbb58324c8adc4d131683332d84b79a50bafa07bd92d2ac686de38635bd30d8445f08a0c2c1fdbf4d26f05e05035abb4574313f86e820fef850ba43b740082562294fd3a935174aeb79b8d5d3935de1188e37427561f888aa39c121a270000801ca00168095256eaec4fdd074470d02f32c017947010813ca51568d42c720ad439f7a03b2fe84a971e46a83011fddc66acd225c05b8ae75de1b41ccfb2946413a7e111f87083028718850ba43b740083015f909407d71bfc263af5758225fab79e1656a22ac9824a8854195f5b7434e800801ba041e5a49b9db51829041ea32fd0fbf4da8b79b7933c25f513aee8a678bffb3ac1a06758def764e58b71bca0f8507b93631a9980fb73d193e6073dd5aa71187f5720f87083028719850ba43b740083015f909477f190fc96c507f40dc13aadc48d2cafcde5358b882239e735fb73a400801ca049be4e119b1f25f2e7d8d1c8c0ba38b2f90e5a800d18a3d34fee51244d4e7fbca04c1748a1aae6a4316039aa89a43f46908d4a4b3eb53f435a81d003db136ced2bf9010c825907850a7a3582008307a120943375ee30428b2a71c428afa5e89e427905f95f7e80b8a47d242ae5000000000000000000000000000000000000000000000000000097951b766aaa000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000221220b38db07e10542ae76234e4efbde58897c8502b3bed7c5740129f173fa97c000e0000000000000000000000000000000000000000000000000000000000001ca0f8486eb8fe36b4e5e300346fc6d2ca71366dbe8bd4492e94adf7bfe6093f76aba05294c7096a206200f59a341ba2f730a6b2b2b77ed995e1c4684c1fd28b503314f86a827ae00a83015f90948b687892c6cf88925ddd772718782a864e5353df8844b5a0318a73d038801ba054df5dcb8c2bf3e09b6a4a783e2933164351d5bfd5e2abbc4b585524b0c13c9ea035df380bafa2beb16543c70b216d3d9bbd663f4ff61c5c35d2837eaf44513b35f86a827ae10a83015f90948850522874c32a49c3a2c65035c5dfb049334caf8844c99175caf20000801ba079195b9ec5b735de194ac4811bb7270c405d865ef285b63c2b8565ad912f1df9a0647f97c5ec482301853330ce69e9f545f54592ad488b3712cac7d752bf1a883ef9021bf90218a07a6e5d44a6651ff0d954584b3c481c71887361e9b50ee07ff981b9e363042bc4a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347942a65aca4d5fc5b5c859090a6c34d164135398226a04e9811a2f1329b469835d279dfbbaea95095ffcedd3f55eb16dc68c82f343d7da027e7fa8561b7f12072d5685196a5669b5586e16c4144ca2ab882d161f92eb95da06914d51d84d4a47310bb541056d64c913a7e5ddce99fb7fbf317ca15b4e0a864b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000860ad304994503830f1b3d832fefd8830148208456bd193c98d783010303844765746887676f312e352e31856c696e7578a0f5b92fa9266dd54f08bea6cf98e4bce3af23d874fd20ea4a850d8454e552712d88e66214db217b12f6"
var rlpBytes = rlpFromHex(blockBytes)
let ethBlock = rlpBytes.read(EthBlock)
let blockHeader = ethBlock.header
let blockBody = BlockBody(transactions: ethBlock.txs, uncles: ethBlock.uncles)

suite "History network content validation":
  test "Correct header should pass validation":
    let correctHeaderBytes = rlp.encode(blockHeader)
    
    let maybeHeader = validateHeaderBytes(correctHeaderBytes, blockHeader.blockHash())

    check:
      maybeHeader.isSome()

  test "Malformed header bytes should not pass validation":
    let correctHeaderBytes = rlp.encode(blockHeader)
    
    let malformedBytes = correctHeaderBytes[10..correctHeaderBytes.high]

    let maybeHeader = validateHeaderBytes(malformedBytes, blockHeader.blockHash())

    check:
      maybeHeader.isNone()

  test "Header different than expected should not pass validation":
    var modifiedHeader = blockHeader

    modifiedHeader.gasUsed = modifiedHeader.gasUsed + 1

    let differentHeaderBytes = rlp.encode(modifiedHeader)
  
    let maybeHeader = validateHeaderBytes(differentHeaderBytes, blockHeader.blockHash())

    check:
      maybeHeader.isNone()

  test "Correct block body should pass validation":
    let correctBodyBytes = rlp.encode(blockBody)

    let maybeBody = validateBodyBytes(correctBodyBytes, blockHeader.txRoot, blockHeader.ommersHash)

    check:
      maybeBody.isSome()

  test "Malformed block body bytes should pass validation":
    let correctBodyBytes = rlp.encode(blockBody)

    let malformedBytes = correctBodyBytes[10..correctBodyBytes.high]

    let maybeBody = validateBodyBytes(malformedBytes, blockHeader.txRoot, blockHeader.ommersHash)

    check:
      maybeBody.isNone()

  test "Block body with modified transactions list should not pass validation":
    var modifiedBody = blockBody

    # drop first transaction
    let modifiedTransactionList = blockBody.transactions[1..blockBody.transactions.high]

    modifiedBody.transactions = modifiedTransactionList

    let modifiedBodyBytes = rlp.encode(modifiedBody)

    let maybeBody = validateBodyBytes(modifiedBodyBytes, blockHeader.txRoot, blockHeader.ommersHash)

    check:
      maybeBody.isNone()

  test "Block body with modified uncles list should not pass validation":
    var modifiedBody = blockBody

    modifiedBody.uncles = @[]

    let modifiedBodyBytes = rlp.encode(modifiedBody)

    let maybeBody = validateBodyBytes(modifiedBodyBytes, blockHeader.txRoot, blockHeader.ommersHash)

    check:
      maybeBody.isNone()
