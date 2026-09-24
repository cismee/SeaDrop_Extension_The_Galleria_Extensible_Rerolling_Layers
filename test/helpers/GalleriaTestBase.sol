// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Galleria } from "../../src/Galleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/**
 * @notice Shared fixture: deploys a TraitRegistry with a configurable number of
 *         uniform-weight options per layer, plus a Galleria whose single allowed
 *         SeaDrop is the constant `SEADROP` EOA — so tests mint by pranking as
 *         `SEADROP` and calling `mintSeaDrop` directly.
 */
contract GalleriaTestBase is Test {
    // Minimal valid 1x1 transparent PNG reused for every option in tests.
    bytes internal constant PIXEL_PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";

    // The (fake) SeaDrop the token trusts; tests prank as this to mint.
    address internal constant SEADROP = address(0x5EAD);
    address internal constant OWNER = address(0xB0B); // token + registry owner

    Galleria internal token;
    TraitRegistry internal registry;

    /// @dev Deploy a registry seeded with the given per-layer option counts
    ///      (uniform weight 100, all rollable) and a token wired to it.
    function _deployWithCounts(
        uint256 nPainting,
        uint256 nLabel,
        uint256 nBackground,
        uint256 nFrame
    ) internal {
        vm.startPrank(OWNER);
        registry = new TraitRegistry(OWNER);
        _seed(ComboLib.LAYER_PAINTING, nPainting);
        _seed(ComboLib.LAYER_LABEL, nLabel);
        _seed(ComboLib.LAYER_BACKGROUND, nBackground);
        _seed(ComboLib.LAYER_FRAME, nFrame);
        registry.finalizeSetup();
        vm.stopPrank();

        address[] memory seaDrops = new address[](1);
        seaDrops[0] = SEADROP;
        token = new Galleria("The Galleria", "GALLERIA", seaDrops, registry);
    }

    function _seed(uint8 layer, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            registry.addOption(layer, PIXEL_PNG, _attr(layer, i), 100, true);
        }
    }

    /// @dev A valid single-object attributes fragment for tests, with trait_type set
    ///      to the layer name so tokenURI assertions on those names still hold.
    function _attr(uint8 layer, uint256 i) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type":"', _layerName(layer), '","value":"', _name(layer, i), '"}'
            )
        );
    }

    function _name(uint8 layer, uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked("L", vm.toString(uint256(layer)), "#", vm.toString(i)));
    }

    function _layerName(uint8 layer) internal pure returns (string memory) {
        if (layer == ComboLib.LAYER_PAINTING) return "Painting";
        if (layer == ComboLib.LAYER_LABEL) return "Label";
        if (layer == ComboLib.LAYER_BACKGROUND) return "Background";
        return "Frame";
    }

    /// @dev Mint `qty` tokens to `to` by pranking as the trusted SeaDrop.
    function _mint(address to, uint256 qty) internal {
        vm.prank(SEADROP);
        token.mintSeaDrop(to, qty);
    }

    /// @dev Set block entropy (PREVRANDAO / block.difficulty) for deterministic
    ///      but varied draws. Our EVM target is pre-Paris, so we use vm.difficulty.
    function _setEntropy(uint256 v) internal {
        vm.difficulty(v);
    }
}
