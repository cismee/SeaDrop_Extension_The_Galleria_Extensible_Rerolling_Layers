// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

contract RegistryTest is Test {
    bytes internal constant PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant OWNER = address(0xB0B);
    address internal constant STRANGER = address(0xBAD);

    TraitRegistry internal reg;

    function setUp() public {
        vm.prank(OWNER);
        reg = new TraitRegistry(OWNER);
    }

    function _add(uint8 layer, uint32 weight, bool rollable) internal returns (uint256) {
        vm.prank(OWNER);
        return reg.addOption(layer, PNG, "x", weight, rollable);
    }

    function test_addOption_appends_and_sets_flags() public {
        uint256 i0 = _add(ComboLib.LAYER_PAINTING, 100, true);
        uint256 i1 = _add(ComboLib.LAYER_PAINTING, 50, false);
        assertEq(i0, 0);
        assertEq(i1, 1);
        assertEq(reg.optionCountOf(ComboLib.LAYER_PAINTING), 2);

        assertTrue(reg.optionExists(ComboLib.LAYER_PAINTING, 0));
        assertTrue(reg.isRollable(ComboLib.LAYER_PAINTING, 0));
        assertTrue(reg.optionExists(ComboLib.LAYER_PAINTING, 1));
        assertFalse(reg.isRollable(ComboLib.LAYER_PAINTING, 1));

        assertEq(reg.weightOf(ComboLib.LAYER_PAINTING, 0), 100);
        // Non-rollable option contributes zero effective weight.
        assertEq(reg.totalWeight(ComboLib.LAYER_PAINTING), 100);
    }

    function test_cdf_reflects_rollable_only() public {
        _add(ComboLib.LAYER_FRAME, 10, true);
        _add(ComboLib.LAYER_FRAME, 20, false); // zero-width
        _add(ComboLib.LAYER_FRAME, 30, true);
        uint256[] memory cdf = reg.cdfOf(ComboLib.LAYER_FRAME);
        assertEq(cdf.length, 3);
        assertEq(cdf[0], 10);
        assertEq(cdf[1], 10); // unchanged — option 1 not rollable
        assertEq(cdf[2], 40);
    }

    function test_setRollable_updates_cdf() public {
        _add(ComboLib.LAYER_FRAME, 10, true);
        _add(ComboLib.LAYER_FRAME, 20, false);
        vm.prank(OWNER);
        reg.setRollable(ComboLib.LAYER_FRAME, 1, true);
        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), 30);
    }

    function test_setWeight_updates_cdf() public {
        _add(ComboLib.LAYER_FRAME, 10, true);
        vm.prank(OWNER);
        reg.setWeight(ComboLib.LAYER_FRAME, 0, 999);
        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), 999);
    }

    function test_freezeWeights_blocks_further_changes() public {
        _add(ComboLib.LAYER_FRAME, 10, true);
        vm.prank(OWNER);
        reg.freezeWeights();
        assertTrue(reg.weightsFrozen());

        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.WeightsFrozen.selector);
        reg.setWeight(ComboLib.LAYER_FRAME, 0, 5);

        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.WeightsFrozen.selector);
        reg.setRollable(ComboLib.LAYER_FRAME, 0, false);
    }

    function test_finalizeSetup_locks_label_only() public {
        _add(ComboLib.LAYER_LABEL, 10, true);
        _add(ComboLib.LAYER_PAINTING, 10, true);
        vm.prank(OWNER);
        reg.finalizeSetup();

        // label is fixed → cannot append.
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LayerNotGrowable.selector);
        reg.addOption(ComboLib.LAYER_LABEL, PNG, "x", 10, true);

        // painting is growable → append still works.
        _add(ComboLib.LAYER_PAINTING, 10, true);
        assertEq(reg.optionCountOf(ComboLib.LAYER_PAINTING), 2);
    }

    function test_growable_flags() public view {
        assertTrue(reg.isGrowable(ComboLib.LAYER_PAINTING));
        assertTrue(reg.isGrowable(ComboLib.LAYER_BACKGROUND));
        assertTrue(reg.isGrowable(ComboLib.LAYER_FRAME));
        assertFalse(reg.isGrowable(ComboLib.LAYER_LABEL));
    }

    function test_default_render_order() public view {
        uint8[] memory order = reg.renderOrder();
        assertEq(order.length, 4);
        // bottom→top: background, painting, frame, label
        assertEq(order[0], ComboLib.LAYER_BACKGROUND);
        assertEq(order[1], ComboLib.LAYER_PAINTING);
        assertEq(order[2], ComboLib.LAYER_FRAME);
        assertEq(order[3], ComboLib.LAYER_LABEL);
    }

    function test_setRenderOrder_requires_permutation() public {
        uint8[] memory bad = new uint8[](4);
        bad[0] = 0;
        bad[1] = 0; // duplicate
        bad[2] = 2;
        bad[3] = 3;
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.BadRenderOrder.selector);
        reg.setRenderOrder(bad);

        uint8[] memory good = new uint8[](4);
        good[0] = 3;
        good[1] = 2;
        good[2] = 1;
        good[3] = 0;
        vm.prank(OWNER);
        reg.setRenderOrder(good);
        assertEq(reg.renderOrder()[0], 3);
    }

    function test_onlyOwner_gates_mutators() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        reg.addOption(ComboLib.LAYER_PAINTING, PNG, "x", 10, true);

        vm.prank(STRANGER);
        vm.expectRevert();
        reg.freezeWeights();
    }

    function test_pointer_and_read_roundtrip() public {
        _add(ComboLib.LAYER_PAINTING, 10, true);
        assertTrue(reg.pointerOf(ComboLib.LAYER_PAINTING, 0) != address(0));
        bytes memory got = reg.readOption(ComboLib.LAYER_PAINTING, 0);
        assertEq(keccak256(got), keccak256(PNG));
    }

    function test_setCanvas() public {
        (uint16 w, uint16 h) = reg.canvas();
        assertEq(w, 140);
        assertEq(h, 160);
        vm.prank(OWNER);
        reg.setCanvas(320, 288);
        (w, h) = reg.canvas();
        assertEq(w, 320);
        assertEq(h, 288);
    }
}
