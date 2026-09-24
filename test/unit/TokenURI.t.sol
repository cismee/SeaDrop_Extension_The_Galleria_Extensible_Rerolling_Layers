// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";
import { Base64 } from "solady/utils/Base64.sol";

/// @notice tokenURI returns valid base64 JSON → base64 SVG → stacked base64 PNGs,
///         with attributes derived from the same unpacked indices as the image.
contract TokenURITest is GalleriaTestBase {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployWithCounts(8, 4, 4, 4);
        _setEntropy(0xF00D);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function test_tokenURI_structure() public {
        _mint(alice, 1);
        string memory uri = token.tokenURI(1);

        // Outer wrapper.
        assertTrue(_contains(uri, "data:application/json;base64,"), "json data uri");

        // Decode the JSON.
        string memory jsonPrefix = "data:application/json;base64,";
        bytes memory b64 = bytes(uri);
        // strip the prefix
        bytes memory payload = new bytes(b64.length - bytes(jsonPrefix).length);
        for (uint256 i = 0; i < payload.length; ++i) {
            payload[i] = b64[i + bytes(jsonPrefix).length];
        }
        string memory json = string(Base64.decode(string(payload)));

        assertTrue(_contains(json, '"name":"The Galleria #1"'), "name");
        assertTrue(_contains(json, '"attributes":['), "attributes array");
        assertTrue(_contains(json, '"trait_type":"Painting"'), "painting trait");
        assertTrue(_contains(json, '"trait_type":"Label"'), "label trait");
        assertTrue(_contains(json, '"trait_type":"Background"'), "background trait");
        assertTrue(_contains(json, '"trait_type":"Frame"'), "frame trait");
        assertTrue(_contains(json, "data:image/svg+xml;base64,"), "svg image field");
    }

    function test_tokenURI_svg_stacks_pngs_in_render_order() public {
        _mint(alice, 1);
        string memory uri = token.tokenURI(1);

        // Decode JSON, pull the image field, decode SVG, check it stacks 4 PNGs.
        string memory json = _decodeDataUri(uri, "data:application/json;base64,");
        // find the image data uri inside json
        string memory svg = _decodeEmbeddedSvg(json);

        assertTrue(_contains(svg, "<svg"), "svg root");
        assertTrue(_contains(svg, "viewBox=\"0 0 140 160\""), "canvas viewBox");
        assertTrue(_contains(svg, "image-rendering:pixelated"), "pixelated");
        // Four stacked <image> layers, each a base64 PNG data uri.
        assertEq(_count(svg, "<image"), 4, "four stacked layers");
        assertTrue(_contains(svg, "data:image/png;base64,"), "png layers");
    }

    function test_attributes_match_unpacked_indices() public {
        _mint(alice, 1);
        (uint8 p, uint8 l, uint8 b, uint8 f) = token.traitsOf(1);
        string memory json = _decodeDataUri(token.tokenURI(1), "data:application/json;base64,");
        // Each option stores a full attributes fragment; assert the fragment for the
        // token's actual option index appears verbatim in the rendered JSON.
        assertTrue(_contains(json, registry.optionAttributesOf(0, p)));
        assertTrue(_contains(json, registry.optionAttributesOf(1, l)));
        assertTrue(_contains(json, registry.optionAttributesOf(2, b)));
        assertTrue(_contains(json, registry.optionAttributesOf(3, f)));
    }

    function test_description_present_settable_and_escaped() public {
        _mint(alice, 1);

        // Default description is present. (Full escaping/markdown coverage for the
        // shipped text lives in Description.t.sol.)
        string memory j1 = _decodeDataUri(token.tokenURI(1), "data:application/json;base64,");
        assertTrue(_contains(j1, '"description":"[The Galleria]('), "default description");

        // Owner updates it for the whole collection — including a quote to prove
        // JSON escaping keeps the metadata valid.
        vm.prank(OWNER);
        registry.setDescription('Gallery of "1-of-1" works');

        string memory j2 = _decodeDataUri(token.tokenURI(1), "data:application/json;base64,");
        assertTrue(_contains(j2, '"description":"Gallery of \\"1-of-1\\" works"'), "escaped + updated");

        // Change propagates to every token (tokenURI reads it live).
        _mint(bob, 1);
        string memory j3 = _decodeDataUri(token.tokenURI(2), "data:application/json;base64,");
        assertTrue(_contains(j3, 'Gallery of \\"1-of-1\\" works'), "applies to all tokens");
    }

    address internal bob = makeAddr("bob");

    /* ----------------------------- helpers ----------------------------- */

    function _decodeDataUri(string memory uri, string memory prefix)
        internal
        pure
        returns (string memory)
    {
        bytes memory u = bytes(uri);
        uint256 off = bytes(prefix).length;
        bytes memory payload = new bytes(u.length - off);
        for (uint256 i = 0; i < payload.length; ++i) payload[i] = u[i + off];
        return string(Base64.decode(string(payload)));
    }

    function _decodeEmbeddedSvg(string memory json) internal pure returns (string memory) {
        // Locate the svg data uri within the json and decode to end-of-field (").
        bytes memory j = bytes(json);
        bytes memory marker = bytes("data:image/svg+xml;base64,");
        uint256 start = _indexOf(j, marker);
        require(start != type(uint256).max, "no svg");
        start += marker.length;
        uint256 end = start;
        // bytes1 of a single-character literal cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        while (end < j.length && j[end] != bytes1('"')) end++;
        bytes memory payload = new bytes(end - start);
        for (uint256 i = 0; i < payload.length; ++i) payload[i] = j[start + i];
        return string(Base64.decode(string(payload)));
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length > h.length) return type(uint256).max;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 k = 0; k < n.length; ++k) {
                if (h[i + k] != n[k]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _count(string memory hay, string memory needle) internal pure returns (uint256 c) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) c++;
        }
    }
}
