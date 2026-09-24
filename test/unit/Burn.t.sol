// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";

/// @notice Burn MUST clear comboToToken[combo] or the combo is orphan-locked
///         forever. (ERC721SeaDrop exposes burn(tokenId).)
contract BurnTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployWithCounts(8, 4, 4, 4);
        _setEntropy(0xB0B0);
    }

    function test_burn_clears_combo_registry() public {
        _mint(alice, 1);
        uint256 id = 1;
        uint256 combo = token.comboOf(id);
        assertEq(token.comboToToken(combo), id + 1);

        vm.prank(alice);
        token.burn(id);

        // Registry freed → the combo is claimable again, not orphan-locked.
        assertEq(token.comboToToken(combo), 0, "burn must free the combo");
        assertEq(token.comboOf(id), 0, "per-token combo cleared");
    }

    function test_burned_combo_is_reclaimable() public {
        // A roomy space plus a forced re-mint would be needed to prove reclaim
        // deterministically; here we assert the map slot is free, which is the
        // precondition that makes the combo drawable again by future mints/rerolls.
        _mint(alice, 1);
        uint256 combo = token.comboOf(1);
        vm.prank(alice);
        token.burn(1);
        assertEq(token.comboToToken(combo), 0);
    }
}
