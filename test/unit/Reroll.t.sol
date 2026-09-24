// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ForcedCollisionGalleria } from "../helpers/ForcedCollisionGalleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";
import { Galleria } from "../../src/Galleria.sol";

/// @notice Reroll semantics under a forced-collision harness: capmiss-is-noop,
///         lock-until-success ordering, and "a reroll can never re-land its own
///         combo".
contract RerollTest is Test {
    bytes internal constant PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant SEADROP = address(0x5EAD);
    address internal constant OWNER = address(0xB0B);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // Local copies of the token events for vm.expectEmit (0.8.17 can't emit an
    // event declared in another contract).
    event Reroll(uint256 indexed tokenId, uint256 oldCombo, uint256 newCombo);
    event CapMiss(uint256 indexed tokenId);
    // EIP-4906 (inherited from ERC721ContractMetadata; redeclared locally for
    // vm.expectEmit under 0.8.17).
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    ForcedCollisionGalleria internal token;
    TraitRegistry internal reg;

    function setUp() public {
        vm.startPrank(OWNER);
        reg = new TraitRegistry(OWNER);
        _seed(ComboLib.LAYER_PAINTING, 8);
        _seed(ComboLib.LAYER_LABEL, 4);
        _seed(ComboLib.LAYER_BACKGROUND, 4);
        _seed(ComboLib.LAYER_FRAME, 4);
        reg.finalizeSetup();
        vm.stopPrank();

        address[] memory seaDrops = new address[](1);
        seaDrops[0] = SEADROP;
        token = new ForcedCollisionGalleria("The Galleria", "G", seaDrops, reg);
        vm.difficulty(0x1234);
    }

    function _seed(uint8 layer, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            reg.addOption(layer, PNG, "x", 100, true);
        }
    }

    function _mint(address to, uint256 qty) internal {
        vm.prank(SEADROP);
        token.mintSeaDrop(to, qty);
    }

    function _script(uint256[] memory arr) internal {
        token.setScript(arr);
    }

    // ------------------------------------------------------------------
    // Rule 3: capmiss keeps the old traits and does NOT revert.
    // ------------------------------------------------------------------
    function test_capmiss_keeps_old_and_does_not_revert() public {
        _mint(alice, 1); // token 1
        _mint(bob, 1); // token 2
        uint256 c1 = token.comboOf(1);
        uint256 c2 = token.comboOf(2);
        assertTrue(c1 != c2);

        // Every reroll attempt for token 1 will draw c2 — which token 2 holds.
        uint256[] memory s = new uint256[](1);
        s[0] = c2;
        _script(s);

        vm.expectEmit(true, false, false, false, address(token));
        emit CapMiss(1);

        vm.prank(alice);
        token.transferFrom(alice, bob, 1); // non-conduit → reroll → capmiss

        // Old traits kept, no revert, ownership still moved.
        assertEq(token.comboOf(1), c1, "capmiss must keep old combo");
        assertEq(token.ownerOf(1), bob);
        assertEq(token.comboToToken(c1), 1 + 1, "token 1 still claims c1");
        assertEq(token.comboToToken(c2), 2 + 1, "token 2 still owns c2 (not stolen)");
    }

    // ------------------------------------------------------------------
    // Rule 2: lock-until-success — old stays claimed until a winner exists, so a
    // reroll can never re-land its own combo. Script the own combo first, then a
    // free combo: correct code skips own and lands the free one.
    // ------------------------------------------------------------------
    function test_lock_until_success_skips_own_then_claims_free() public {
        _mint(alice, 1); // token 1
        uint256 c1 = token.comboOf(1);

        // A canonical combo that is guaranteed free (nothing else minted).
        uint256 free = ComboLib.pack(7, 3, 3, 3);
        if (free == c1) free = ComboLib.pack(6, 3, 3, 3);
        assertEq(token.comboToToken(free), 0, "precondition: free combo unclaimed");

        uint256[] memory s = new uint256[](2);
        s[0] = c1; // attempt 0: own combo → must read as taken and be skipped
        s[1] = free; // attempt 1: free → winner
        _script(s);

        vm.expectEmit(true, false, false, true, address(token));
        emit Reroll(1, c1, free);

        vm.prank(alice);
        token.transferFrom(alice, bob, 1);

        assertEq(token.comboOf(1), free, "must land the free combo, not its own");
        assertEq(token.comboToToken(c1), 0, "old combo released");
        assertEq(token.comboToToken(free), 1 + 1, "new combo claimed");
    }

    // ------------------------------------------------------------------
    // Reroll releases old and claims new (successful swap, first attempt).
    // ------------------------------------------------------------------
    function test_reroll_releases_old_claims_new() public {
        _mint(alice, 1);
        uint256 c1 = token.comboOf(1);
        uint256 target = ComboLib.pack(5, 2, 2, 2);
        if (target == c1) target = ComboLib.pack(4, 2, 2, 2);

        uint256[] memory s = new uint256[](1);
        s[0] = target;
        _script(s);

        vm.prank(alice);
        token.transferFrom(alice, bob, 1);

        assertEq(token.comboOf(1), target);
        assertEq(token.comboToToken(c1), 0);
        assertEq(token.comboToToken(target), 2);
    }

    // ------------------------------------------------------------------
    // EIP-4906: a successful reroll changes traits, so it MUST emit
    // BatchMetadataUpdate(tokenId, tokenId) to make marketplaces (e.g. OpenSea)
    // refresh the cached image/attributes without a manual refresh.
    // ------------------------------------------------------------------
    function test_reroll_emits_eip4906_metadata_update() public {
        _mint(alice, 1);
        uint256 c1 = token.comboOf(1);
        uint256 target = ComboLib.pack(5, 2, 2, 2);
        if (target == c1) target = ComboLib.pack(4, 2, 2, 2);

        uint256[] memory s = new uint256[](1);
        s[0] = target;
        _script(s);

        // Both params are non-indexed → check data only (from==to==tokenId==1).
        vm.expectEmit(false, false, false, true, address(token));
        emit BatchMetadataUpdate(1, 1);

        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
    }

    // A capmiss keeps the old traits (nothing changed), so it must NOT emit a
    // metadata update — otherwise every stuck-transfer would spam a needless refresh.
    function test_capmiss_does_not_emit_metadata_update() public {
        _mint(alice, 1); // token 1
        _mint(bob, 1); // token 2
        uint256 c2 = token.comboOf(2);

        uint256[] memory s = new uint256[](1);
        s[0] = c2; // every attempt collides with token 2 → capmiss
        _script(s);

        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(alice, bob, 1); // non-conduit → reroll → capmiss

        bytes32 sig = keccak256("BatchMetadataUpdate(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != sig, "capmiss must not emit metadata update");
            }
        }
    }

    // ------------------------------------------------------------------
    // Admin-misconfig backstop: if a layer is retired to zero rollable weight,
    // sampling would revert. A reroll must NOT brick the transfer — it degrades to
    // capmiss (old traits kept, ownership still moves), never soulbinding a token.
    // ------------------------------------------------------------------
    function test_zeroWeightLayer_reroll_degrades_to_capmiss_not_brick() public {
        _mint(alice, 1); // token 1, real sampling (script not set)
        uint256 c1 = token.comboOf(1);

        // Retire EVERY frame option → frame layer has zero rollable weight, so a
        // draw would revert in SamplingLib.sampleBucket.
        vm.startPrank(OWNER);
        for (uint256 i = 0; i < 4; ++i) {
            reg.setRollable(ComboLib.LAYER_FRAME, i, false);
        }
        vm.stopPrank();
        assertEq(reg.totalWeight(ComboLib.LAYER_FRAME), 0, "frame now unsampleable");

        vm.expectEmit(true, false, false, false, address(token));
        emit CapMiss(1);

        vm.prank(alice);
        token.transferFrom(alice, bob, 1); // non-conduit → reroll → must not revert

        assertEq(token.comboOf(1), c1, "capmiss keeps old combo");
        assertEq(token.ownerOf(1), bob, "transfer still succeeded");
        assertEq(token.comboToToken(c1), 1 + 1, "token 1 still claims its combo");
    }

    // A mint into a zero-weight-layer config reverts cleanly (nothing minted,
    // nothing soulbound) instead of surfacing a low-level sampling revert.
    function test_zeroWeightLayer_mint_reverts_cleanly() public {
        vm.startPrank(OWNER);
        for (uint256 i = 0; i < 4; ++i) {
            reg.setRollable(ComboLib.LAYER_FRAME, i, false);
        }
        vm.stopPrank();

        vm.prank(SEADROP);
        vm.expectRevert(Galleria.MintCapMiss.selector);
        token.mintSeaDrop(alice, 1);
    }
}
