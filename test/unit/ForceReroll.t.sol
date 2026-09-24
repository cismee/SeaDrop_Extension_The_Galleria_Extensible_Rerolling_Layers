// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TwoStepOwnable } from "utility-contracts/TwoStepOwnable.sol";
import { ForcedCollisionGalleria } from "../helpers/ForcedCollisionGalleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";
import { ComboLib } from "../../src/ComboLib.sol";

/// @notice `forceReroll` — the owner-only, off-chain-driven remediation lever for
///         transfers that preserved traits but should not have (e.g. a wallet "send"
///         routed through OpenSea's TransferHelper, which reaches the token as a
///         Seaport conduit and is therefore indistinguishable from a real sale).
///
///         The contract under test is deployed by THIS test contract, so
///         `token.owner() == address(this)` and un-pranked calls are owner calls.
contract ForceRerollTest is Test {
    bytes internal constant PNG =
        hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b4944415478da6364f8cf500f00038601805a347d6b0000000049454e44ae426082";
    address internal constant SEADROP = address(0x5EAD);
    address internal constant OWNER = address(0xB0B); // registry owner
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // Local copies for vm.expectEmit (0.8.17 cannot emit another contract's event).
    event Reroll(uint256 indexed tokenId, uint256 oldCombo, uint256 newCombo);
    event CapMiss(uint256 indexed tokenId);
    event ForcedReroll(uint256 indexed tokenId);
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

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    // ------------------------------------------------------------------
    // The core promise: traits change, the token does NOT move.
    // ------------------------------------------------------------------
    function test_forceReroll_changes_combo_without_moving_token() public {
        _mint(alice, 1);
        uint256 before = token.comboOf(1);

        token.forceReroll(_ids(1));

        assertTrue(token.comboOf(1) != before, "combo must change");
        assertEq(token.ownerOf(1), alice, "ownership must not move");
        assertEq(token.balanceOf(alice), 1, "balance unchanged");
        assertEq(token.getApproved(1), address(0), "approvals untouched");
    }

    // ------------------------------------------------------------------
    // Uniqueness bookkeeping: old combo released, new combo claimed.
    // ------------------------------------------------------------------
    function test_forceReroll_releases_old_claims_new() public {
        _mint(alice, 1);
        uint256 old = token.comboOf(1);

        uint256 target = ComboLib.pack(5, 2, 2, 2);
        if (target == old) target = ComboLib.pack(4, 2, 2, 2);
        uint256[] memory s = new uint256[](1);
        s[0] = target;
        token.setScript(s);

        vm.expectEmit(true, false, false, true, address(token));
        emit Reroll(1, old, target);

        token.forceReroll(_ids(1));

        assertEq(token.comboOf(1), target, "new combo stored");
        assertEq(token.comboToToken(old), 0, "old combo released");
        assertEq(token.comboToToken(target), 1 + 1, "new combo claimed");
    }

    // ------------------------------------------------------------------
    // Access control.
    // ------------------------------------------------------------------
    function test_forceReroll_onlyOwner() public {
        _mint(alice, 1);
        uint256 before = token.comboOf(1);

        vm.prank(alice); // the HOLDER is not the contract owner
        vm.expectRevert(TwoStepOwnable.OnlyOwner.selector);
        token.forceReroll(_ids(1));

        assertEq(token.comboOf(1), before, "combo untouched after failed call");
    }

    // ------------------------------------------------------------------
    // Batch behaviour: every token rerolls, and all stay mutually unique
    // (claim-as-you-go — Rule 5 — across the batch).
    // ------------------------------------------------------------------
    function test_forceReroll_batch_keeps_all_combos_unique() public {
        _mint(alice, 5);

        uint256[] memory ids = new uint256[](5);
        uint256[] memory before = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            ids[i] = i + 1;
            before[i] = token.comboOf(ids[i]);
        }

        token.forceReroll(ids);

        for (uint256 i = 0; i < 5; ++i) {
            uint256 c = token.comboOf(ids[i]);
            assertTrue(c != before[i], "each token must actually reroll");
            assertEq(token.comboToToken(c), ids[i] + 1, "reverse index consistent");
            assertEq(token.ownerOf(ids[i]), alice, "no token moved");
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(c != token.comboOf(ids[j]), "combos must stay injective");
            }
        }
    }

    // ------------------------------------------------------------------
    // Robustness for an off-chain-assembled batch: ids that do not exist are
    // skipped rather than reverting the whole call.
    // ------------------------------------------------------------------
    function test_forceReroll_skips_nonexistent_and_burned_ids() public {
        _mint(alice, 2); // tokens 1, 2
        uint256 burnedCombo = token.comboOf(2);
        vm.prank(alice);
        token.burn(2);

        uint256 before1 = token.comboOf(1);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 999; // never minted
        ids[1] = 2; // burned between detection and execution
        ids[2] = 1; // live — must still be processed

        token.forceReroll(ids); // must not revert

        assertTrue(token.comboOf(1) != before1, "live token still rerolled");
        assertEq(token.comboOf(2), 0, "burned token stays cleared");
        assertEq(token.comboToToken(burnedCombo), 0, "burned combo stays free");
    }

    // ------------------------------------------------------------------
    // EIP-4906: a successful forced reroll must signal marketplaces to refresh,
    // with no extra owner call needed.
    // ------------------------------------------------------------------
    function test_forceReroll_emits_eip4906_metadata_update() public {
        _mint(alice, 1);
        uint256 old = token.comboOf(1);
        uint256 target = ComboLib.pack(5, 2, 2, 2);
        if (target == old) target = ComboLib.pack(4, 2, 2, 2);
        uint256[] memory s = new uint256[](1);
        s[0] = target;
        token.setScript(s);

        vm.expectEmit(false, false, false, true, address(token));
        emit BatchMetadataUpdate(1, 1);

        token.forceReroll(_ids(1));
    }

    // ------------------------------------------------------------------
    // Audit trail: ForcedReroll marks the admin action itself.
    // ------------------------------------------------------------------
    function test_forceReroll_emits_forcedReroll_marker() public {
        _mint(alice, 1);

        vm.expectEmit(true, false, false, false, address(token));
        emit ForcedReroll(1);

        token.forceReroll(_ids(1));
    }

    // ------------------------------------------------------------------
    // Rule 3 still holds on this path: if every candidate collides, keep the old
    // traits and do NOT revert. The admin sweep must never brick on one token.
    // ------------------------------------------------------------------
    function test_forceReroll_capmiss_is_noop_and_does_not_revert() public {
        _mint(alice, 1); // token 1
        _mint(bob, 1); // token 2
        uint256 c1 = token.comboOf(1);
        uint256 c2 = token.comboOf(2);

        uint256[] memory s = new uint256[](1);
        s[0] = c2; // every attempt draws token 2's combo → capmiss
        token.setScript(s);

        vm.expectEmit(true, false, false, false, address(token));
        emit CapMiss(1);

        token.forceReroll(_ids(1)); // must not revert

        assertEq(token.comboOf(1), c1, "capmiss keeps the old combo");
        assertEq(token.comboToToken(c1), 1 + 1, "token 1 still claims c1");
        assertEq(token.comboToToken(c2), 2 + 1, "token 2's combo not stolen");
    }

    // A capmiss changed nothing, so it must not emit a metadata refresh.
    function test_forceReroll_capmiss_does_not_emit_metadata_update() public {
        _mint(alice, 1);
        _mint(bob, 1);
        uint256[] memory s = new uint256[](1);
        s[0] = token.comboOf(2);
        token.setScript(s);

        vm.recordLogs();
        token.forceReroll(_ids(1));

        bytes32 sig = keccak256("BatchMetadataUpdate(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != sig, "capmiss must not emit refresh");
            }
        }
    }

    // ------------------------------------------------------------------
    // Admin-misconfig backstop: a zero-weight layer degrades to capmiss here too,
    // rather than reverting the sweep.
    // ------------------------------------------------------------------
    function test_forceReroll_zeroWeightLayer_degrades_to_capmiss() public {
        _mint(alice, 1);
        uint256 c1 = token.comboOf(1);

        vm.startPrank(OWNER);
        for (uint256 i = 0; i < 4; ++i) {
            reg.setRollable(ComboLib.LAYER_FRAME, i, false);
        }
        vm.stopPrank();

        vm.expectEmit(true, false, false, false, address(token));
        emit CapMiss(1);

        token.forceReroll(_ids(1)); // must not revert

        assertEq(token.comboOf(1), c1, "old traits kept");
        assertEq(token.ownerOf(1), alice, "token unaffected");
    }

    // ------------------------------------------------------------------
    // An empty batch is a clean no-op (a sweep with nothing to do).
    // ------------------------------------------------------------------
    function test_forceReroll_empty_batch_is_noop() public {
        _mint(alice, 1);
        uint256 before = token.comboOf(1);
        token.forceReroll(new uint256[](0));
        assertEq(token.comboOf(1), before);
    }
}
