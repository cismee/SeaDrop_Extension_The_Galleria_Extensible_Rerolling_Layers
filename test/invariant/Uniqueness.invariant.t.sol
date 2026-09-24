// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Handler } from "./handlers/Handler.sol";
import { Galleria } from "../../src/Galleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/**
 * @title  Uniqueness invariants — THE priority suite.
 * @notice The uniqueness invariant is property-tested here, not just unit-tested.
 *         The fuzzer drives mint / reroll-transfer / conduit-transfer / burn as
 *         target selectors on the Handler; after every call sequence these
 *         invariants must hold:
 *
 *           1. comboToToken consistency: for every LIVE token t,
 *              comboToToken[comboOf(t)] == t + 1.
 *           2. injectivity: the map live-token → combo is injective (no two live
 *              tokens share a packed value).
 *           3. canonical packing: every live token's combo has zero unused bits.
 */
contract UniquenessInvariant is StdInvariant, Test {
    bytes internal constant PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant SEADROP = address(0x5EAD);
    address internal constant OWNER = address(0xB0B);
    address internal constant CONDUIT = address(uint160(0xC0DE));

    Galleria internal token;
    TraitRegistry internal registry;
    Handler internal handler;

    function setUp() public {
        vm.startPrank(OWNER);
        registry = new TraitRegistry(OWNER);
        // A modest space (8*4*4*4 = 512) intentionally close to the ~400-token
        // test cap: high occupancy (~78%) stresses collisions HARD, which is
        // exactly where an injectivity bug would surface.
        _seed(ComboLib.LAYER_PAINTING, 8);
        _seed(ComboLib.LAYER_LABEL, 4);
        _seed(ComboLib.LAYER_BACKGROUND, 4);
        _seed(ComboLib.LAYER_FRAME, 4);
        registry.finalizeSetup();
        vm.stopPrank();

        address[] memory seaDrops = new address[](1);
        seaDrops[0] = SEADROP;
        token = new Galleria("The Galleria", "GALLERIA", seaDrops, registry);
        token.setBlessedConduit(CONDUIT, true);

        handler = new Handler(token, registry, SEADROP, CONDUIT);

        // Only fuzz the handler's action selectors.
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Handler.mint.selector;
        selectors[1] = Handler.rerollTransfer.selector;
        selectors[2] = Handler.conduitTransfer.selector;
        selectors[3] = Handler.burn.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function _seed(uint8 layer, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            registry.addOption(layer, PNG, "x", 100, true);
        }
    }

    /// @notice Invariant 1 + 3: every live token is consistently claimed and its
    ///         combo is canonically packed (no unused high bits).
    function invariant_comboConsistencyAndCanonical() public view {
        uint256 n = handler.liveCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 tokenId = handler.liveAt(i);
            uint256 combo = token.comboOf(tokenId);
            assertEq(token.comboToToken(combo), tokenId + 1, "comboToToken inconsistent");
            assertTrue(ComboLib.isCanonical(combo), "combo has unused bits set");
            // Ownership sanity: a live token must exist.
            assertEq(token.ownerOf(tokenId), token.ownerOf(tokenId));
        }
    }

    /// @notice Invariant 2: injectivity of live-token → combo. No two live tokens
    ///         share a packed value.
    function invariant_injectivity() public view {
        uint256 n = handler.liveCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 ci = token.comboOf(handler.liveAt(i));
            for (uint256 j = i + 1; j < n; ++j) {
                assertTrue(ci != token.comboOf(handler.liveAt(j)), "two live tokens share a combo");
            }
        }
    }

    /// @notice Surface handler coverage in `-vvv` runs.
    function invariant_callSummary() public view {
        // no assertion — a place to eyeball action coverage
    }
}
