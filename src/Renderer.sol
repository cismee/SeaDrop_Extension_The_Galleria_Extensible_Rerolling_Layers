// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Base64 } from "solady/utils/Base64.sol";
import { LibString } from "solady/utils/LibString.sol";
import { TraitRegistry } from "./TraitRegistry.sol";
import { ComboLib } from "./ComboLib.sol";

/**
 * @title  Renderer
 * @notice tokenURI assembly: EXTCODECOPY the option PNGs → base64 → stacked SVG
 *         → base64 → JSON → base64. Pure view assembly on the caller's node.
 *
 *         ONE SOURCE OF TRUTH: both the stacked image and the `attributes` array
 *         are derived from the SAME unpacked indices, so art and metadata can
 *         never drift apart.
 *
 *         Z-ORDER: images are emitted in the registry's mutable render-order list
 *         (bottom→top). Document order == z-order; PNGs carry alpha so lower
 *         layers show through. Render order is decoupled from bit position, so it
 *         can be corrected without touching packing.
 */
library Renderer {
    using LibString for uint256;

    /**
     * @notice Build the full `data:application/json;base64,...` token URI.
     * @param registry The shared art/attribute library.
     * @param tokenId  For the `name` field.
     * @param combo    The token's packed four-layer combo.
     */
    function tokenURI(
        TraitRegistry registry,
        uint256 tokenId,
        uint256 combo
    ) public view returns (string memory) {
        string memory svg = _svg(registry, combo);

        // Collection-wide description from the registry (owner-settable, live),
        // JSON-escaped so free text can't break the metadata JSON.
        string memory desc = LibString.escapeJSON(registry.description(), false);

        string memory json = string(
            abi.encodePacked(
                '{"name":"The Galleria #',
                tokenId.toString(),
                '","description":"',
                desc,
                '","image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '","attributes":',
                _attributes(registry, combo),
                "}"
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(bytes(json))
                )
            );
    }

    /* ------------------------------------------------------------------ */
    /*                                SVG                                  */
    /* ------------------------------------------------------------------ */

    /// @dev Assemble the stacked-PNG SVG. Each layer's PNG is EXTCODECOPY'd out of
    ///      its SSTORE2 blob, base64'd, and emitted as an <image> covering the
    ///      full canvas, in render (z) order.
    function _svg(TraitRegistry registry, uint256 combo)
        internal
        view
        returns (string memory)
    {
        (uint16 w, uint16 h) = registry.canvas();
        string memory wStr = uint256(w).toString();
        string memory hStr = uint256(h).toString();

        // Open tag: pixelated scaling with a crisp-edges fallback.
        string memory out = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" ',
                'viewBox="0 0 ',
                wStr,
                " ",
                hStr,
                '" width="',
                wStr,
                '" height="',
                hStr,
                '" shape-rendering="crispEdges" ',
                'style="image-rendering:pixelated;image-rendering:crisp-edges">'
            )
        );

        uint8[] memory order = registry.renderOrder();
        for (uint256 i = 0; i < order.length; ) {
            uint8 layer = order[i];
            uint8 optionIndex = ComboLib.field(combo, layer);
            // exists is permanent, so this ALWAYS resolves for any held option,
            // even one retired from sampling (rollable == false).
            bytes memory png = registry.readOption(layer, optionIndex);
            out = string(
                abi.encodePacked(
                    out,
                    '<image x="0" y="0" width="',
                    wStr,
                    '" height="',
                    hStr,
                    '" image-rendering="pixelated" href="data:image/png;base64,',
                    Base64.encode(png),
                    '"/>'
                )
            );
            unchecked {
                ++i;
            }
        }

        return string(abi.encodePacked(out, "</svg>"));
    }

    /* ------------------------------------------------------------------ */
    /*                             Attributes                             */
    /* ------------------------------------------------------------------ */

    /// @dev Build the attributes JSON array by concatenating each layer option's
    ///      stored attributes fragment. Each fragment is one or more
    ///      `{"trait_type":...,"value":...}` objects (no surrounding brackets, no
    ///      trailing comma), so a single option can contribute several traits — e.g.
    ///      a painting emits Demake + Master + Year. Fragments are owner-supplied
    ///      valid JSON (values pre-escaped in the registry) and are emitted verbatim.
    ///      Derived from the SAME unpacked indices as the image, so art and metadata
    ///      can never drift apart.
    function _attributes(TraitRegistry registry, uint256 combo)
        internal
        view
        returns (string memory)
    {
        string memory out = "[";
        for (uint8 layer = 0; layer < uint8(ComboLib.NUM_LAYERS); ) {
            uint8 optionIndex = ComboLib.field(combo, layer);
            out = string(
                abi.encodePacked(
                    out,
                    layer == 0 ? "" : ",",
                    registry.optionAttributesOf(layer, optionIndex)
                )
            );
            unchecked {
                ++layer;
            }
        }
        return string(abi.encodePacked(out, "]"));
    }
}
