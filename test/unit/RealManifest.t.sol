// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { Galleria } from "../../src/Galleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/// @notice End-to-end over the REAL art/manifest.json: seed a registry from the
///         actual per-option attribute fragments, mint, render tokenURI, and prove
///         the metadata is well-formed multi-attribute JSON — paintings carry
///         Demake + Master + Year, labels use trait_type "Plaque".
contract RealManifestTest is Test {
    bytes internal constant PIXEL_PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant SEADROP = address(0x5EAD);
    address internal constant OWNER = address(0xB0B);
    address internal alice = makeAddr("alice");

    function _seed(TraitRegistry reg, uint8 layer, string[] memory frags) internal {
        for (uint256 i = 0; i < frags.length; ++i) {
            reg.addOption(layer, PIXEL_PNG, frags[i], 100, true);
        }
    }

    function test_real_manifest_renders_valid_multi_attribute_json() public {
        // This test exists precisely to validate the real on-disk manifest.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory manifest = vm.readFile("art/manifest.json");
        string[] memory paintings = vm.parseJsonStringArray(manifest, ".painting.attributes");
        string[] memory labels = vm.parseJsonStringArray(manifest, ".label.attributes");
        string[] memory backgrounds = vm.parseJsonStringArray(manifest, ".background.attributes");
        string[] memory frames = vm.parseJsonStringArray(manifest, ".frame.attributes");

        // Counts match the collection.
        assertEq(paintings.length, 36, "paintings");
        assertEq(labels.length, 6, "labels");
        assertEq(backgrounds.length, 27, "backgrounds");
        assertEq(frames.length, 27, "frames");

        vm.startPrank(OWNER);
        TraitRegistry reg = new TraitRegistry(OWNER);
        _seed(reg, ComboLib.LAYER_PAINTING, paintings);
        _seed(reg, ComboLib.LAYER_LABEL, labels);
        _seed(reg, ComboLib.LAYER_BACKGROUND, backgrounds);
        _seed(reg, ComboLib.LAYER_FRAME, frames);
        reg.finalizeSetup();
        vm.stopPrank();

        address[] memory sd = new address[](1);
        sd[0] = SEADROP;
        Galleria token = new Galleria("The Galleria", "GALLERIA", sd, reg);

        vm.difficulty(0xA11CE);
        vm.prank(SEADROP);
        token.mintSeaDrop(alice, 1);

        string memory json = _decode(token.tokenURI(1));

        // The whole rendered JSON must be well-formed — vm.parseJson reverts if not.
        vm.parseJson(json);

        // The painting layer contributed three distinct traits, and the label uses
        // "Plaque" — i.e. per-option attribute sets flow through end to end.
        assertTrue(_has(json, '"trait_type":"Demake"'), "Demake");
        assertTrue(_has(json, '"trait_type":"Master"'), "Master");
        assertTrue(_has(json, '"trait_type":"Year"'), "Year");
        assertTrue(_has(json, '"trait_type":"Plaque"'), "Plaque");
        assertTrue(_has(json, '"trait_type":"Background"'), "Background");
        assertTrue(_has(json, '"trait_type":"Frame"'), "Frame");
        assertTrue(_has(json, '"attributes":['), "attributes array");
    }

    /* ----------------------------- helpers ----------------------------- */

    function _decode(string memory uri) internal pure returns (string memory) {
        string memory prefix = "data:application/json;base64,";
        bytes memory u = bytes(uri);
        uint256 off = bytes(prefix).length;
        bytes memory payload = new bytes(u.length - off);
        for (uint256 i = 0; i < payload.length; ++i) payload[i] = u[i + off];
        return string(Base64.decode(string(payload)));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
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
}
