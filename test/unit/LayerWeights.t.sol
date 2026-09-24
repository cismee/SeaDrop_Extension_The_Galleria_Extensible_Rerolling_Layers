// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/// @notice Whole-layer weight setters: setPaintingWeights / setLabelWeights /
///         setBackgroundWeights / setFrameWeights.
///
///         Each takes one POSITIONAL array covering the entire layer and must reject
///         any array whose length is not exactly the layer's option count — a short
///         array would silently leave a tail on stale weights, a long one would
///         silently drop the excess. Both are the bugs these tests exist to prevent.
contract LayerWeightsTest is Test {
    bytes internal constant PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant OWNER = address(0xB0B);
    address internal constant STRANGER = address(0xBAD);

    event WeightSet(uint8 indexed layer, uint256 indexed index, uint32 weight);

    TraitRegistry internal reg;

    // Small but distinct per-layer counts so a setter writing the wrong layer is caught.
    uint256 internal constant N_PAINTING = 5;
    uint256 internal constant N_LABEL = 3;
    uint256 internal constant N_BACKGROUND = 4;
    uint256 internal constant N_FRAME = 6;

    function setUp() public {
        vm.startPrank(OWNER);
        reg = new TraitRegistry(OWNER);
        _seed(ComboLib.LAYER_PAINTING, N_PAINTING);
        _seed(ComboLib.LAYER_LABEL, N_LABEL);
        _seed(ComboLib.LAYER_BACKGROUND, N_BACKGROUND);
        _seed(ComboLib.LAYER_FRAME, N_FRAME);
        vm.stopPrank();
    }

    function _seed(uint8 layer, uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) reg.addOption(layer, PNG, "x", 100, true);
    }

    function _ramp(uint256 n, uint32 start, uint32 step) internal pure returns (uint32[] memory a) {
        a = new uint32[](n);
        // i < n, and every caller passes a small layer size, so uint32 is ample.
        // forge-lint: disable-next-line(unsafe-typecast)
        for (uint256 i = 0; i < n; ++i) a[i] = start + uint32(i) * step;
    }

    function _sum(uint32[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; ++i) s += a[i];
    }

    // ------------------------------------------------------------------
    // Happy path, one test per layer — writes every option and rebuilds the CDF.
    // ------------------------------------------------------------------
    function test_setPaintingWeights_writes_whole_layer() public {
        uint32[] memory w = _ramp(N_PAINTING, 10, 7);
        vm.prank(OWNER);
        reg.setPaintingWeights(w);
        _assertLayer(ComboLib.LAYER_PAINTING, w);
    }

    function test_setLabelWeights_writes_whole_layer() public {
        uint32[] memory w = _ramp(N_LABEL, 500, 250);
        vm.prank(OWNER);
        reg.setLabelWeights(w);
        _assertLayer(ComboLib.LAYER_LABEL, w);
    }

    function test_setBackgroundWeights_writes_whole_layer() public {
        uint32[] memory w = _ramp(N_BACKGROUND, 33, 11);
        vm.prank(OWNER);
        reg.setBackgroundWeights(w);
        _assertLayer(ComboLib.LAYER_BACKGROUND, w);
    }

    function test_setFrameWeights_writes_whole_layer() public {
        uint32[] memory w = _ramp(N_FRAME, 9, 3);
        vm.prank(OWNER);
        reg.setFrameWeights(w);
        _assertLayer(ComboLib.LAYER_FRAME, w);
    }

    /// @dev Every stored weight matches, the CDF is the running total, and the layer
    ///      total equals the sum.
    function _assertLayer(uint8 layer, uint32[] memory w) internal view {
        uint256[] memory cdf = reg.cdfOf(layer);
        assertEq(cdf.length, w.length, "cdf length == option count");
        uint256 running;
        for (uint256 i = 0; i < w.length; ++i) {
            assertEq(reg.weightOf(layer, i), w[i], "weight stored");
            running += w[i];
            assertEq(cdf[i], running, "cdf is cumulative");
        }
        assertEq(reg.totalWeight(layer), _sum(w), "layer total");
    }

    // ------------------------------------------------------------------
    // Each setter must touch ONLY its own layer.
    // ------------------------------------------------------------------
    function test_setters_do_not_touch_other_layers() public {
        vm.prank(OWNER);
        reg.setPaintingWeights(_ramp(N_PAINTING, 10, 7));

        assertEq(reg.totalWeight(ComboLib.LAYER_LABEL), N_LABEL * 100, "label untouched");
        assertEq(reg.totalWeight(ComboLib.LAYER_BACKGROUND), N_BACKGROUND * 100, "bg untouched");
        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), N_FRAME * 100, "frame untouched");
    }

    // ------------------------------------------------------------------
    // Length must be an EXACT cover. Too short and too long both revert.
    // ------------------------------------------------------------------
    function test_reverts_when_array_too_short() public {
        uint32[] memory w = _ramp(N_PAINTING - 1, 10, 7);
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LengthMismatch.selector);
        reg.setPaintingWeights(w);
    }

    function test_reverts_when_array_too_long() public {
        uint32[] memory w = _ramp(N_PAINTING + 1, 10, 7);
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LengthMismatch.selector);
        reg.setPaintingWeights(w);
    }

    function test_reverts_on_empty_array_for_populated_layer() public {
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LengthMismatch.selector);
        reg.setPaintingWeights(new uint32[](0));
    }

    /// @dev A rejected call must leave the layer completely untouched.
    function test_rejected_call_leaves_weights_unchanged() public {
        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LengthMismatch.selector);
        reg.setFrameWeights(_ramp(N_FRAME - 2, 5, 5));

        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), N_FRAME * 100, "unchanged after revert");
    }

    /// @dev The length check follows the layer as it grows.
    function test_length_requirement_tracks_option_count_after_append() public {
        uint32[] memory ok = _ramp(N_PAINTING, 10, 7);
        vm.prank(OWNER);
        reg.setPaintingWeights(ok); // fits now

        vm.prank(OWNER);
        reg.addOption(ComboLib.LAYER_PAINTING, PNG, "x", 100, true); // count -> 6

        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.LengthMismatch.selector);
        reg.setPaintingWeights(ok); // same array no longer covers the layer

        vm.prank(OWNER);
        reg.setPaintingWeights(_ramp(N_PAINTING + 1, 10, 7)); // correct length works
        assertEq(reg.optionCountOf(ComboLib.LAYER_PAINTING), N_PAINTING + 1);
    }

    // ------------------------------------------------------------------
    // Access control and the freeze.
    // ------------------------------------------------------------------
    function test_onlyOwner() public {
        uint32[] memory w = _ramp(N_PAINTING, 10, 7);
        vm.prank(STRANGER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        reg.setPaintingWeights(w);
    }

    function test_blocked_by_freezeWeights() public {
        vm.prank(OWNER);
        reg.freezeWeights();

        vm.prank(OWNER);
        vm.expectRevert(TraitRegistry.WeightsFrozen.selector);
        reg.setBackgroundWeights(_ramp(N_BACKGROUND, 33, 11));
    }

    // Weight edits stay legal on the non-growable label layer after finalizeSetup —
    // that lock is about ADDING options, not retuning existing ones.
    function test_label_weights_still_settable_after_finalizeSetup() public {
        vm.prank(OWNER);
        reg.finalizeSetup();

        uint32[] memory w = _ramp(N_LABEL, 500, 250);
        vm.prank(OWNER);
        reg.setLabelWeights(w);
        _assertLayer(ComboLib.LAYER_LABEL, w);
    }

    // ------------------------------------------------------------------
    // Interaction with the rollable flag and zero weights.
    // ------------------------------------------------------------------
    function test_non_rollable_option_stays_zero_width() public {
        vm.prank(OWNER);
        reg.setRollable(ComboLib.LAYER_BACKGROUND, 1, false);

        uint32[] memory w = _ramp(N_BACKGROUND, 33, 11);
        vm.prank(OWNER);
        reg.setBackgroundWeights(w);

        // The raw weight is stored, but it contributes nothing to the CDF.
        assertEq(reg.weightOf(ComboLib.LAYER_BACKGROUND, 1), w[1], "raw weight stored");
        uint256[] memory cdf = reg.cdfOf(ComboLib.LAYER_BACKGROUND);
        assertEq(cdf[1], cdf[0], "non-rollable is a zero-width bucket");
        assertEq(reg.totalWeight(ComboLib.LAYER_BACKGROUND), _sum(w) - w[1], "excluded from total");
    }

    function test_all_zero_weights_leaves_layer_unsampleable() public {
        uint32[] memory zeros = new uint32[](N_FRAME);
        vm.prank(OWNER);
        reg.setFrameWeights(zeros);
        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), 0, "layer has no rollable weight");
    }

    // ------------------------------------------------------------------
    // Events: one WeightSet per option.
    // ------------------------------------------------------------------
    function test_emits_WeightSet_per_option() public {
        uint32[] memory w = _ramp(N_LABEL, 500, 250);
        for (uint256 i = 0; i < N_LABEL; ++i) {
            vm.expectEmit(true, true, false, true, address(reg));
            emit WeightSet(ComboLib.LAYER_LABEL, i, w[i]);
        }
        vm.prank(OWNER);
        reg.setLabelWeights(w);
    }

    // ------------------------------------------------------------------
    // The shipped 2,618 curve applies cleanly at real layer sizes.
    // ------------------------------------------------------------------
    function test_shipped_curve_applies_at_real_layer_size() public {
        TraitRegistry r2;
        vm.startPrank(OWNER);
        r2 = new TraitRegistry(OWNER);
        for (uint256 i = 0; i < 6; ++i) r2.addOption(ComboLib.LAYER_LABEL, PNG, "x", 100, true);

        uint32[] memory label = new uint32[](6);
        label[0] = 2400; label[1] = 2025; label[2] = 1870;
        label[3] = 1571; label[4] = 1444; label[5] = 1178;
        r2.setLabelWeights(label);
        vm.stopPrank();

        assertEq(r2.totalWeight(ComboLib.LAYER_LABEL), 10488, "shipped label total");
        uint256[] memory cdf = r2.cdfOf(ComboLib.LAYER_LABEL);
        assertEq(cdf[5], 10488, "cdf last == total");
        assertEq(cdf[0], 2400, "first bucket");
    }

    // ------------------------------------------------------------------
    // Whole-layer READ getters: paintingWeights / labelWeights /
    // backgroundWeights / frameWeights / weightsOf(layer).
    // ------------------------------------------------------------------

    function _assertEqArr(uint32[] memory got, uint32[] memory want, string memory what) internal pure {
        assertEq(got.length, want.length, what);
        for (uint256 i = 0; i < want.length; ++i) assertEq(got[i], want[i], what);
    }

    function test_getters_return_what_was_set() public {
        uint32[] memory p = _ramp(N_PAINTING, 10, 7);
        uint32[] memory l = _ramp(N_LABEL, 500, 250);
        uint32[] memory b = _ramp(N_BACKGROUND, 33, 11);
        uint32[] memory f = _ramp(N_FRAME, 9, 3);

        vm.startPrank(OWNER);
        reg.setPaintingWeights(p);
        reg.setLabelWeights(l);
        reg.setBackgroundWeights(b);
        reg.setFrameWeights(f);
        vm.stopPrank();

        _assertEqArr(reg.paintingWeights(), p, "painting");
        _assertEqArr(reg.labelWeights(), l, "label");
        _assertEqArr(reg.backgroundWeights(), b, "background");
        _assertEqArr(reg.frameWeights(), f, "frame");
    }

    /// @dev The getter is the exact inverse of the setter: writing back what you read
    ///      changes nothing.
    function test_read_then_write_back_is_a_noop() public {
        uint32[] memory p = _ramp(N_PAINTING, 13, 5);
        vm.prank(OWNER);
        reg.setPaintingWeights(p);

        uint256 totalBefore = reg.totalWeight(ComboLib.LAYER_PAINTING);
        uint32[] memory readBack = reg.paintingWeights();

        vm.prank(OWNER);
        reg.setPaintingWeights(readBack); // round-trip

        _assertEqArr(reg.paintingWeights(), p, "unchanged after round-trip");
        assertEq(reg.totalWeight(ComboLib.LAYER_PAINTING), totalBefore, "total unchanged");
    }

    /// @dev Getters report RAW weights; a retired option still shows its stored value
    ///      even though the CDF excludes it.
    function test_getter_returns_raw_weight_for_non_rollable() public {
        uint32[] memory b = _ramp(N_BACKGROUND, 33, 11);
        vm.startPrank(OWNER);
        reg.setBackgroundWeights(b);
        reg.setRollable(ComboLib.LAYER_BACKGROUND, 2, false);
        vm.stopPrank();

        assertEq(reg.backgroundWeights()[2], b[2], "raw weight still reported");

        uint256[] memory cdf = reg.cdfOf(ComboLib.LAYER_BACKGROUND);
        assertEq(cdf[2], cdf[1], "but effective weight is zero");
        assertEq(reg.totalWeight(ComboLib.LAYER_BACKGROUND), _sum(b) - b[2], "excluded from total");
    }

    /// @dev Length always matches optionCountOf, so a read feeds straight back into
    ///      the setter's exact-cover requirement even after the layer grows.
    function test_getter_length_tracks_option_count() public {
        assertEq(reg.paintingWeights().length, N_PAINTING);

        vm.prank(OWNER);
        reg.addOption(ComboLib.LAYER_PAINTING, PNG, "x", 777, true);

        uint32[] memory got = reg.paintingWeights();
        assertEq(got.length, N_PAINTING + 1, "grew with the layer");
        assertEq(got[N_PAINTING], 777, "new option's weight present");

        vm.prank(OWNER);
        reg.setPaintingWeights(got); // still an exact cover
    }

    function test_weightsOf_generic_matches_named_getters() public {
        uint32[] memory f = _ramp(N_FRAME, 9, 3);
        vm.prank(OWNER);
        reg.setFrameWeights(f);

        _assertEqArr(reg.weightsOf(ComboLib.LAYER_FRAME), reg.frameWeights(), "frame via generic");
        _assertEqArr(reg.weightsOf(ComboLib.LAYER_PAINTING), reg.paintingWeights(), "painting via generic");
    }

    function test_weightsOf_rejects_bad_layer() public {
        vm.expectRevert(TraitRegistry.BadLayer.selector);
        reg.weightsOf(4);
    }

    function test_getter_on_empty_layer_returns_empty_array() public {
        vm.prank(OWNER);
        TraitRegistry fresh = new TraitRegistry(OWNER);
        assertEq(fresh.paintingWeights().length, 0, "empty layer -> empty array");
    }

    /// @dev Readable by anyone — these are views, not owner-gated.
    function test_getters_are_public_reads() public {
        vm.prank(STRANGER);
        assertEq(reg.paintingWeights().length, N_PAINTING);
    }
}
