// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";

/// @notice A batched mint produces distinct combos (per-draw nonce works) and
///         claim-as-you-go prevents intra-batch duplicates.
contract BatchTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployWithCounts(32, 13, 16, 16); // ~106k combos, 32x supply
        _setEntropy(0x5EED);
    }

    function test_batch_mint_distinct_combos() public {
        uint256 qty = 25;
        _mint(alice, qty); // single tx: prevrandao shared across the whole batch

        // Without the per-draw (tokenId, attempt, layer) nonce, all 25 would share
        // the block entropy and collapse to identical combos. Assert all distinct.
        for (uint256 i = 1; i <= qty; ++i) {
            uint256 ci = token.comboOf(i);
            assertEq(token.comboToToken(ci), i + 1, "consistency");
            for (uint256 j = i + 1; j <= qty; ++j) {
                assertTrue(ci != token.comboOf(j), "intra-batch duplicate combo");
            }
        }
    }

    function test_claim_as_you_go_registry_consistent_after_batch() public {
        _mint(alice, 40);
        for (uint256 i = 1; i <= 40; ++i) {
            assertEq(token.ownerOf(i), alice);
            assertEq(token.comboToToken(token.comboOf(i)), i + 1);
        }
        assertEq(token.totalSupply(), 40);
    }
}
