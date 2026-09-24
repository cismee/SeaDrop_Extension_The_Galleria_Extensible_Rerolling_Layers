// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/// @notice Canonical-packing unit + fuzz tests. The heavier property versions
///         run in the invariant suite; these pin the library directly.
contract ComboLibTest is Test {
    function test_pack_layout_bit_positions() public pure {
        uint256 combo = ComboLib.pack(1, 2, 3, 4);
        assertEq(combo & 0xFF, 1, "painting in bits[0,8)");
        assertEq((combo >> 8) & 0xFF, 2, "label in bits[8,16)");
        assertEq((combo >> 16) & 0xFF, 3, "background in bits[16,24)");
        assertEq((combo >> 24) & 0xFF, 4, "frame in bits[24,32)");
    }

    function testFuzz_roundtrip_identity(
        uint8 p,
        uint8 l,
        uint8 b,
        uint8 f
    ) public pure {
        uint256 combo = ComboLib.pack(p, l, b, f);
        (uint8 p2, uint8 l2, uint8 b2, uint8 f2) = ComboLib.unpack(combo);
        assertEq(p2, p);
        assertEq(l2, l);
        assertEq(b2, b);
        assertEq(f2, f);
        // pack(unpack(x)) == x
        assertEq(ComboLib.pack(p2, l2, b2, f2), combo);
    }

    function testFuzz_unused_high_bits_always_zero(
        uint8 p,
        uint8 l,
        uint8 b,
        uint8 f
    ) public pure {
        uint256 combo = ComboLib.pack(p, l, b, f);
        // Bits above the 32 used bits must be zero.
        assertEq(combo >> ComboLib.USED_BITS, 0, "unused bits set");
        assertTrue(ComboLib.isCanonical(combo));
    }

    function testFuzz_field_matches_unpack(
        uint8 p,
        uint8 l,
        uint8 b,
        uint8 f
    ) public pure {
        uint256 combo = ComboLib.pack(p, l, b, f);
        assertEq(ComboLib.field(combo, ComboLib.LAYER_PAINTING), p);
        assertEq(ComboLib.field(combo, ComboLib.LAYER_LABEL), l);
        assertEq(ComboLib.field(combo, ComboLib.LAYER_BACKGROUND), b);
        assertEq(ComboLib.field(combo, ComboLib.LAYER_FRAME), f);
    }

    function test_isCanonical_rejects_high_bits() public pure {
        uint256 dirty = ComboLib.pack(1, 1, 1, 1) | (uint256(1) << 33);
        assertFalse(ComboLib.isCanonical(dirty));
    }

    function test_key_is_identity() public pure {
        uint256 combo = ComboLib.pack(9, 8, 7, 6);
        assertEq(ComboLib.key(combo), combo);
    }

    /// @dev Distinct index tuples must map to distinct packed values (injective
    ///      encoding — one encoding per visual combo).
    function testFuzz_injective_encoding(
        uint8 p1,
        uint8 l1,
        uint8 b1,
        uint8 f1,
        uint8 p2,
        uint8 l2,
        uint8 b2,
        uint8 f2
    ) public pure {
        bool sameTuple = (p1 == p2 && l1 == l2 && b1 == b2 && f1 == f2);
        uint256 c1 = ComboLib.pack(p1, l1, b1, f1);
        uint256 c2 = ComboLib.pack(p2, l2, b2, f2);
        if (sameTuple) assertEq(c1, c2);
        else assertTrue(c1 != c2);
    }
}
