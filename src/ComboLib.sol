// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @title  ComboLib
 * @notice Canonical pack/unpack for a Galleria token's four trait indices.
 *
 *         THE PACKED uint256 *IS* THE TOKEN'S IDENTITY. Uniqueness is enforced
 *         on this value directly (see Galleria.comboToToken), so packing must be
 *         canonical: exactly one encoding per visual combo, fixed field widths,
 *         and all unused high bits provably zero. Two of those properties are
 *         property-tested as invariants (round-trip identity + zero unused bits).
 *
 *         Layout (little-end-first, 8 bits per layer, 32 bits used of 256):
 *
 *             bits  [ 0.. 8)  painting     (layer id 0)
 *             bits  [ 8..16)  label        (layer id 1)
 *             bits  [16..24)  background   (layer id 2)
 *             bits  [24..32)  frame        (layer id 3)
 *             bits  [32..256) UNUSED — always zero
 *
 *         Why 8 bits / 256 options per field when the collection ships far fewer:
 *         the width is deliberately over-allocated so new options can be appended
 *         to a growable layer forever WITHOUT shifting any existing packed value.
 *         Because every live token holds indices below the append point, growth
 *         can never alias an existing combo — the space only grows. (TODO: confirm
 *         256 comfortably exceeds the most you'd ever reach in *each* growable
 *         layer — painting, frame, background — not just painting.)
 *
 *         Bit position is decoupled from render (z) order on purpose: render order
 *         is a separate mutable list in the registry, so z-order can be corrected
 *         without ever touching this packing.
 */
library ComboLib {
    /* ------------------------------------------------------------------ */
    /*                          Layout constants                          */
    /* ------------------------------------------------------------------ */

    /// @dev There are exactly four layers, fixed forever.
    uint256 internal constant NUM_LAYERS = 4;

    /// @dev Bits per layer field.
    uint256 internal constant BITS_PER_LAYER = 8;

    /// @dev Max options per layer (2**8). An index must be < this.
    uint256 internal constant MAX_OPTIONS_PER_LAYER = 256;

    /// @dev Single-field mask (0xFF).
    uint256 internal constant FIELD_MASK = 0xFF;

    /// @dev Total meaningful bits (4 * 8 = 32).
    uint256 internal constant USED_BITS = 32;

    /// @dev Mask over all meaningful bits (0xFFFFFFFF). Everything above must be 0.
    uint256 internal constant USED_MASK = 0xFFFFFFFF;

    // Layer ids double as the field position index (id * 8 = bit offset).
    uint8 internal constant LAYER_PAINTING = 0;
    uint8 internal constant LAYER_LABEL = 1;
    uint8 internal constant LAYER_BACKGROUND = 2;
    uint8 internal constant LAYER_FRAME = 3;

    /* ------------------------------------------------------------------ */
    /*                              Pack                                   */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Pack four 8-bit trait indices into one canonical uint256.
     * @dev    Inputs are uint8, so each already fits its field and no input can
     *         spill into a neighbouring field or the unused high bits. The result
     *         therefore satisfies `isCanonical()` by construction.
     */
    function pack(
        uint8 painting,
        uint8 label,
        uint8 background,
        uint8 frame
    ) internal pure returns (uint256 combo) {
        combo =
            (uint256(painting) << (LAYER_PAINTING * BITS_PER_LAYER)) |
            (uint256(label) << (LAYER_LABEL * BITS_PER_LAYER)) |
            (uint256(background) << (LAYER_BACKGROUND * BITS_PER_LAYER)) |
            (uint256(frame) << (LAYER_FRAME * BITS_PER_LAYER));
    }

    /* ------------------------------------------------------------------ */
    /*                             Unpack                                  */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Unpack a combo back into its four indices.
     * @dev    `pack(unpack(x)) == x` for every canonical `x`, and
     *         `unpack(pack(a,b,c,d)) == (a,b,c,d)` for all inputs — round-trip
     *         identity is asserted as an invariant.
     */
    function unpack(uint256 combo)
        internal
        pure
        returns (
            uint8 painting,
            uint8 label,
            uint8 background,
            uint8 frame
        )
    {
        // Masking with FIELD_MASK (0xFF) leaves at most 8 bits set, so the uint8
        // cast is lossless by construction — it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        painting = uint8((combo >> (LAYER_PAINTING * BITS_PER_LAYER)) & FIELD_MASK);
        // Masking with FIELD_MASK (0xFF) leaves at most 8 bits set, so the uint8
        // cast is lossless by construction — it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        label = uint8((combo >> (LAYER_LABEL * BITS_PER_LAYER)) & FIELD_MASK);
        // Masking with FIELD_MASK (0xFF) leaves at most 8 bits set, so the uint8
        // cast is lossless by construction — it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        background = uint8((combo >> (LAYER_BACKGROUND * BITS_PER_LAYER)) & FIELD_MASK);
        // Masking with FIELD_MASK (0xFF) leaves at most 8 bits set, so the uint8
        // cast is lossless by construction — it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        frame = uint8((combo >> (LAYER_FRAME * BITS_PER_LAYER)) & FIELD_MASK);
    }

    /**
     * @notice Extract a single layer's option index from a combo.
     * @param  layer One of LAYER_PAINTING..LAYER_FRAME (0..3).
     */
    function field(uint256 combo, uint8 layer) internal pure returns (uint8) {
        // Same as unpack: FIELD_MASK caps the value at 0xFF before the cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((combo >> (uint256(layer) * BITS_PER_LAYER)) & FIELD_MASK);
    }

    /* ------------------------------------------------------------------ */
    /*                          Canonical check                           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice True iff `combo` has no bits set above the 32 used bits.
     * @dev    The single source of truth for "is this a legal packed value".
     *         Anything the writer stores must pass this; the property test
     *         asserts every stored combo is canonical.
     */
    function isCanonical(uint256 combo) internal pure returns (bool) {
        return combo >> USED_BITS == 0;
    }

    /**
     * @notice The uniqueness key for a combo.
     * @dev    In the 4-layer independent-label model the packed value *is* the
     *         key (identity function). Kept as a named function so uniqueness
     *         logic reads intentionally and so the key derivation has one home
     *         if the label-coupling model ever changes.
     */
    function key(uint256 combo) internal pure returns (uint256) {
        return combo;
    }
}
