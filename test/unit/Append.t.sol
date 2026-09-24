// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/// @notice Appending an option (tested for painting, frame, AND background):
///         existing packed values are unchanged, indices are append-only, and the
///         exists/rollable flags behave as specified.
contract AppendTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployWithCounts(8, 4, 4, 4);
        _setEntropy(0xA9);
    }

    function _appendGrowableAndCheck(uint8 layer) internal {
        // Snapshot existing tokens' packed values.
        _mint(alice, 5);
        uint256[6] memory before;
        for (uint256 i = 1; i <= 5; ++i) {
            before[i] = token.comboOf(i);
        }

        uint256 countBefore = registry.optionCountOf(layer);

        // Append a new option (pre-staged: exists=true, rollable=false).
        vm.prank(OWNER);
        uint256 newIndex = registry.addOption(layer, PIXEL_PNG, "NewArt", 100, false);

        // Append-only: registered at the next index for that layer.
        assertEq(newIndex, countBefore, "must register at next index");
        assertEq(registry.optionCountOf(layer), countBefore + 1);

        // exists is permanent; rollable is off (pre-staged), so sampling can't
        // draw it yet.
        assertTrue(registry.optionExists(layer, newIndex));
        assertFalse(registry.isRollable(layer, newIndex));

        // Existing packed values did not move — no repack.
        for (uint256 i = 1; i <= 5; ++i) {
            assertEq(token.comboOf(i), before[i], "existing packed value moved!");
        }

        // Reveal: flipping rollable adds it to the sampleable set.
        uint256 totalBefore = registry.totalWeight(layer);
        vm.prank(OWNER);
        registry.setRollable(layer, newIndex, true);
        assertEq(registry.totalWeight(layer), totalBefore + 100);
    }

    function test_append_painting() public {
        _appendGrowableAndCheck(ComboLib.LAYER_PAINTING);
    }

    function test_append_frame() public {
        _appendGrowableAndCheck(ComboLib.LAYER_FRAME);
    }

    function test_append_background() public {
        _appendGrowableAndCheck(ComboLib.LAYER_BACKGROUND);
    }

    function test_label_append_blocked_after_finalize() public {
        // Setup was finalized in the fixture; label is fixed.
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LayerNotGrowable.selector);
        registry.addOption(ComboLib.LAYER_LABEL, PIXEL_PNG, "x", 100, true);
    }

    function test_new_option_combos_disjoint_from_existing() public {
        _mint(alice, 3);
        vm.prank(OWNER);
        uint256 newIdx = registry.addOption(ComboLib.LAYER_PAINTING, PIXEL_PNG, "New", 100, true);

        // Any combo carrying the new painting index differs from every existing
        // token's combo (which all hold painting index < newIdx).
        // newIdx is an option index bounded by MAX_OPTIONS_PER_LAYER (256).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 newCombo = ComboLib.pack(uint8(newIdx), 0, 0, 0);
        for (uint256 i = 1; i <= 3; ++i) {
            assertTrue(token.comboOf(i) != newCombo);
            assertTrue(ComboLib.field(token.comboOf(i), ComboLib.LAYER_PAINTING) < newIdx);
        }
    }
}
