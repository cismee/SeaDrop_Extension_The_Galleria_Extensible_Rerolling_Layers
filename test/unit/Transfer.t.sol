// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";
import { IERC721Receiver } from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import { Galleria } from "../../src/Galleria.sol";

/// @dev Accepts ERC721 safe transfers (valid recipient for safeSend).
contract PlainReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev On receipt, re-transfers the token onward once — used to prove the safeSend
///      preserve-guard is consumed in the hook and cannot be reused re-entrantly.
contract ReentrantReceiver is IERC721Receiver {
    Galleria internal token;
    address internal dest;
    bool internal armed;

    function arm(Galleria token_, address dest_) external {
        token = token_;
        dest = dest_;
        armed = true;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (armed) {
            armed = false; // once
            token.transferFrom(address(this), dest, tokenId); // raw move → should reroll
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Minimal stand-in for Seaport's ConduitController: `getKey` returns a
///      registered conduit's key and reverts for anything else, matching the real
///      contract's reverse-lookup semantics.
contract MockConduitController {
    mapping(address => bytes32) internal _keys;

    function register(address conduit, bytes32 key) external {
        _keys[conduit] = key;
    }

    function getKey(address conduit) external view returns (bytes32 key) {
        key = _keys[conduit];
        if (key == bytes32(0)) revert("NoConduit");
    }
}

/// @notice Conduit-preserve vs non-conduit-reroll branch selection, plus the
///         documented self-custody edge.
contract TransferTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal conduit = makeAddr("conduit");

    // Seaport's canonical ConduitController address (constant in Galleria).
    address internal constant CONDUIT_CONTROLLER =
        0x00000000F9490004C11Cef243f5400493c00Ad63;

    function setUp() public {
        // Roomy combo space so a reroll always finds a fresh combo.
        _deployWithCounts(8, 4, 4, 4); // 512 combos
        _setEntropy(0xA11CE);
    }

    /// @dev Install the mock controller at the canonical address so Galleria's
    ///      `_isSeaportConduit` lookup resolves against it.
    function _installController() internal returns (MockConduitController) {
        MockConduitController impl = new MockConduitController();
        vm.etch(CONDUIT_CONTROLLER, address(impl).code);
        return MockConduitController(CONDUIT_CONTROLLER);
    }

    function test_non_conduit_transfer_rerolls() public {
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        _setEntropy(0xBEEF); // change block entropy so the new draw differs
        vm.prank(alice);
        token.transferFrom(alice, bob, id);

        uint256 after_ = token.comboOf(id);
        assertTrue(after_ != before, "combo should reroll on non-conduit move");
        assertEq(token.ownerOf(id), bob);
        // Registry consistency for the new combo; old combo freed.
        assertEq(token.comboToToken(after_), id + 1);
        assertEq(token.comboToToken(before), 0);
    }

    function test_blessed_conduit_transfer_preserves() public {
        token.setBlessedConduit(conduit, true);
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(conduit, true);

        _setEntropy(0xBEEF);
        vm.prank(conduit);
        token.transferFrom(alice, bob, id);

        assertEq(token.comboOf(id), before, "combo must be preserved via conduit");
        assertEq(token.ownerOf(id), bob);
        assertEq(token.comboToToken(before), id + 1);
    }

    function test_opensea_conduit_seeded_blessed() public view {
        assertTrue(token.blessedConduit(token.OPENSEA_CONDUIT()));
    }

    function test_self_custody_move_rerolls_documented_edge() public {
        // Alice moves the token to her own second wallet with a raw transferFrom.
        // Indistinguishable from a sale on-chain → it rerolls. Accepted behavior.
        address aliceWallet2 = makeAddr("aliceWallet2");
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        _setEntropy(0xC0FFEE);
        vm.prank(alice);
        token.transferFrom(alice, aliceWallet2, id);

        assertTrue(token.comboOf(id) != before, "self-custody move rerolls (documented)");
    }

    // Finding #3 fix: ANY Seaport-registered conduit preserves, not just OpenSea's.
    function test_any_seaport_conduit_preserves() public {
        MockConduitController controller = _installController();
        address someConduit = makeAddr("someConduit");
        controller.register(someConduit, bytes32(uint256(1))); // now a known conduit
        assertFalse(token.blessedConduit(someConduit), "not manually blessed");

        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(someConduit, true);

        _setEntropy(0xBEEF);
        vm.prank(someConduit);
        token.transferFrom(alice, bob, id);

        assertEq(token.comboOf(id), before, "any Seaport conduit must preserve");
        assertEq(token.ownerOf(id), bob);
        assertEq(token.comboToToken(before), id + 1);
    }

    // A non-conduit operator still rerolls even while the controller is deployed.
    function test_unregistered_operator_still_rerolls_with_controller_present() public {
        _installController(); // deployed, but does not know `randomOp`
        address randomOp = makeAddr("randomOp");

        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(randomOp, true);

        _setEntropy(0xBEEF);
        vm.prank(randomOp);
        token.transferFrom(alice, bob, id);

        assertTrue(token.comboOf(id) != before, "non-conduit operator must reroll");
    }

    // All Blur + Seaport routers are seeded preserving.
    function test_blur_and_seaport_routers_seeded_blessed() public view {
        assertTrue(token.blessedConduit(token.BLUR_EXECUTION_DELEGATE()), "Blur delegate");
        assertTrue(token.blessedConduit(token.SEAPORT_1_6()), "Seaport 1.6 core");
        assertTrue(token.blessedConduit(token.SEAPORT_1_5()), "Seaport 1.5 core");
    }

    // A Blur sale (msg.sender = ExecutionDelegate) preserves traits.
    function test_blur_sale_preserves() public {
        address blur = token.BLUR_EXECUTION_DELEGATE();
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(blur, true);

        _setEntropy(0xBEEF);
        vm.prank(blur);
        token.transferFrom(alice, bob, id);

        assertEq(token.comboOf(id), before, "Blur sale must preserve");
        assertEq(token.ownerOf(id), bob);
    }

    // A Seaport direct fill (msg.sender = Seaport core) preserves traits.
    function test_seaport_direct_fill_preserves() public {
        address seaport = token.SEAPORT_1_6();
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(seaport, true);

        _setEntropy(0xBEEF);
        vm.prank(seaport);
        token.transferFrom(alice, bob, id);

        assertEq(token.comboOf(id), before, "Seaport direct fill must preserve");
        assertEq(token.ownerOf(id), bob);
    }

    // ------------------------------------------------------------------
    // safeSend: owner-initiated preserving transfer.
    // ------------------------------------------------------------------
    event SafeSent(uint256 indexed tokenId, address indexed from, address indexed to);

    function test_safeSend_preserves_and_transfers() public {
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        _setEntropy(0xBEEF); // even with different entropy, no reroll
        vm.expectEmit(true, true, true, false, address(token));
        emit SafeSent(id, alice, bob);
        vm.prank(alice);
        token.safeSend(bob, id);

        assertEq(token.comboOf(id), before, "safeSend must preserve traits");
        assertEq(token.ownerOf(id), bob, "ownership must move");
        assertEq(token.comboToToken(before), id + 1, "combo still claimed by token");
    }

    function test_safeSend_only_owner_reverts() public {
        _mint(alice, 1);
        vm.prank(bob); // not the owner
        vm.expectRevert(Galleria.NotTokenOwner.selector);
        token.safeSend(bob, 1);
    }

    function test_safeSend_to_receiver_contract_preserves() public {
        PlainReceiver r = new PlainReceiver();
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        _setEntropy(0xBEEF);
        vm.prank(alice);
        token.safeSend(address(r), id);

        assertEq(token.comboOf(id), before, "safeSend to receiver preserves");
        assertEq(token.ownerOf(id), address(r));
    }

    function test_safeSend_to_non_receiver_reverts() public {
        // registry is a contract without onERC721Received → safe transfer must revert.
        _mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        token.safeSend(address(registry), 1);
    }

    function test_safeSend_guard_does_not_leak_to_later_transfer() public {
        _mint(alice, 1);
        uint256 id = 1;

        vm.prank(alice);
        token.safeSend(bob, id); // preserve
        uint256 afterSend = token.comboOf(id);

        // A subsequent raw transferFrom must still reroll — the guard was consumed.
        _setEntropy(0xD00D);
        vm.prank(bob);
        token.transferFrom(bob, alice, id);
        assertTrue(token.comboOf(id) != afterSend, "guard leaked: later move should reroll");
    }

    // Adversarial: a re-entrant recipient that re-transfers on receipt must NOT get
    // the onward move preserved — the guard is consumed in the hook before the
    // receiver callback, so the nested transferFrom rerolls.
    function test_safeSend_reentrant_receiver_cannot_preserve() public {
        ReentrantReceiver r = new ReentrantReceiver();
        address carol = makeAddr("carol");
        r.arm(token, carol);

        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        _setEntropy(0xBEEF);
        vm.prank(alice);
        token.safeSend(address(r), id); // r re-transfers to carol inside the callback

        assertEq(token.ownerOf(id), carol, "onward re-entrant transfer completed");
        assertTrue(token.comboOf(id) != before, "re-entrant onward move must reroll");
    }

    function test_blessed_conduit_admin_editable_and_owner_only() public {
        assertFalse(token.blessedConduit(conduit));
        token.setBlessedConduit(conduit, true);
        assertTrue(token.blessedConduit(conduit));
        token.setBlessedConduit(conduit, false);
        assertFalse(token.blessedConduit(conduit));

        vm.prank(bob);
        vm.expectRevert();
        token.setBlessedConduit(conduit, true);
    }

    // ------------------------------------------------------------------
    // Excluded conduits: force a reroll even when the operator would otherwise be
    // recognised as preserving. The set ships EMPTY — it can only act on the address
    // that actually arrives as `msg.sender`, so a router that delegates to a conduit
    // (e.g. OpenSea's TransferHelper) can never be caught by it. See the note in
    // Galleria.sol and `forceReroll` for the remediation path.
    // ------------------------------------------------------------------

    function test_excluded_set_ships_empty() public view {
        // The historic TransferHelper seeding was inert; nothing is pre-excluded now.
        assertFalse(
            token.excludedConduit(0x0000000000c2d145a2526bD8C716263bFeBe1A72),
            "excluded set must ship empty"
        );
        assertFalse(token.excludedConduit(conduit));
    }

    // Excluded overrides the blessed set: a blessed AND excluded operator rerolls.
    function test_excluded_overrides_blessed_and_rerolls() public {
        token.setBlessedConduit(conduit, true);
        token.setExcludedConduit(conduit, true); // excluded wins
        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(conduit, true);

        _setEntropy(0xBEEF);
        vm.prank(conduit);
        token.transferFrom(alice, bob, id);

        assertTrue(token.comboOf(id) != before, "excluded must reroll despite being blessed");
        assertEq(token.ownerOf(id), bob);
    }

    // Excluded overrides dynamic Seaport-conduit recognition too.
    function test_excluded_overrides_seaport_conduit_recognition() public {
        MockConduitController controller = _installController();
        address someConduit = makeAddr("excludedSeaportConduit");
        controller.register(someConduit, bytes32(uint256(7))); // recognised as a Seaport conduit
        token.setExcludedConduit(someConduit, true); // but excluded → must reroll

        _mint(alice, 1);
        uint256 id = 1;
        uint256 before = token.comboOf(id);

        vm.prank(alice);
        token.setApprovalForAll(someConduit, true);

        _setEntropy(0xBEEF);
        vm.prank(someConduit);
        token.transferFrom(alice, bob, id);

        assertTrue(token.comboOf(id) != before, "excluded overrides Seaport-conduit recognition");
        assertEq(token.ownerOf(id), bob);
    }

    // safeSend (owner one-shot) preserves regardless of the excluded set.
    function test_safeSend_preserves_even_if_owner_excluded() public {
        _mint(alice, 1);
        uint256 id = 1;
        token.setExcludedConduit(alice, true); // owner in excluded set — safeSend must still preserve
        uint256 before = token.comboOf(id);

        _setEntropy(0xBEEF);
        vm.prank(alice);
        token.safeSend(bob, id);

        assertEq(token.comboOf(id), before, "safeSend preserves regardless of excluded set");
        assertEq(token.ownerOf(id), bob);
    }

    function test_setExcludedConduit_admin_editable_and_owner_only() public {
        address op = makeAddr("op");
        assertFalse(token.excludedConduit(op));
        token.setExcludedConduit(op, true);
        assertTrue(token.excludedConduit(op));
        token.setExcludedConduit(op, false);
        assertFalse(token.excludedConduit(op));

        vm.prank(bob);
        vm.expectRevert();
        token.setExcludedConduit(op, true);
    }
}
