// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { IERC721Receiver } from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";
import { Galleria } from "../../src/Galleria.sol";

/// @dev Accepts ERC721 safe transfers (valid recipient for safeSendBatch).
contract BatchReceiver is IERC721Receiver {
    uint256 public received;

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        ++received;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice `safeSendBatch` — the multi-token form of `safeSend`.
///
///         The load-bearing property is that the one-shot `_preservingSend` guard is
///         re-armed per token. The hook CONSUMES it on every transfer, so a batch that
///         armed it once would preserve token 1 and silently reroll the rest. Several
///         tests below exist purely to catch that regression.
contract SafeSendBatchTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event SafeSent(uint256 indexed tokenId, address indexed from, address indexed to);

    function setUp() public {
        _deployWithCounts(8, 4, 4, 4);
        _setEntropy(0xBEEF);
    }

    function _ids(uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) ids[i] = i + 1;
    }

    // ------------------------------------------------------------------
    // THE regression test: every token in the batch must preserve, not just the
    // first. A guard armed once outside the loop fails here on token 2 onward.
    // ------------------------------------------------------------------
    function test_safeSendBatch_preserves_every_token_not_just_the_first() public {
        _mint(alice, 5);
        uint256[] memory ids = _ids(5);

        uint256[] memory before = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) before[i] = token.comboOf(ids[i]);

        vm.prank(alice);
        token.safeSendBatch(bob, ids);

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(token.comboOf(ids[i]), before[i], "every token must preserve");
            assertEq(token.ownerOf(ids[i]), bob, "every token must move");
        }
        assertEq(token.balanceOf(bob), 5);
        assertEq(token.balanceOf(alice), 0);
    }

    // The reverse-index must still point at each token after a preserving batch.
    function test_safeSendBatch_leaves_uniqueness_index_intact() public {
        _mint(alice, 4);
        uint256[] memory ids = _ids(4);

        vm.prank(alice);
        token.safeSendBatch(bob, ids);

        for (uint256 i = 0; i < 4; ++i) {
            assertEq(
                token.comboToToken(token.comboOf(ids[i])),
                ids[i] + 1,
                "combo still claimed by its token"
            );
        }
    }

    // ------------------------------------------------------------------
    // Ownership is enforced per token; a foreign token reverts the WHOLE batch.
    // ------------------------------------------------------------------
    function test_safeSendBatch_reverts_if_any_token_not_owned() public {
        _mint(alice, 2); // 1, 2
        _mint(bob, 1); // 3 — not alice's
        uint256 before1 = token.comboOf(1);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 3; // foreign
        ids[2] = 2;

        vm.prank(alice);
        vm.expectRevert(Galleria.NotTokenOwner.selector);
        token.safeSendBatch(bob, ids);

        // Atomic: nothing moved, nothing rerolled.
        assertEq(token.ownerOf(1), alice, "batch must be atomic");
        assertEq(token.ownerOf(2), alice);
        assertEq(token.comboOf(1), before1);
    }

    // A repeated id reverts: after the first send the caller no longer owns it.
    function test_safeSendBatch_duplicate_id_reverts() public {
        _mint(alice, 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;

        vm.prank(alice);
        vm.expectRevert(Galleria.NotTokenOwner.selector);
        token.safeSendBatch(bob, ids);

        assertEq(token.ownerOf(1), alice, "nothing moved");
    }

    // ------------------------------------------------------------------
    // Receiver semantics: the callback fires once per token.
    // ------------------------------------------------------------------
    function test_safeSendBatch_to_receiver_contract_preserves_all() public {
        BatchReceiver r = new BatchReceiver();
        _mint(alice, 3);
        uint256[] memory ids = _ids(3);

        uint256[] memory before = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) before[i] = token.comboOf(ids[i]);

        vm.prank(alice);
        token.safeSendBatch(address(r), ids);

        assertEq(r.received(), 3, "onERC721Received once per token");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(token.comboOf(ids[i]), before[i], "preserved through callback");
            assertEq(token.ownerOf(ids[i]), address(r));
        }
    }

    // A non-receiver contract reverts the whole batch (standard safe-transfer rule).
    function test_safeSendBatch_to_non_receiver_reverts() public {
        _mint(alice, 2);
        uint256[] memory ids = _ids(2);

        vm.prank(alice);
        vm.expectRevert();
        token.safeSendBatch(address(registry), ids); // registry has no onERC721Received

        assertEq(token.ownerOf(1), alice);
    }

    // ------------------------------------------------------------------
    // The guard must not survive the batch: a plain transfer afterwards rerolls.
    // ------------------------------------------------------------------
    function test_safeSendBatch_guard_does_not_leak_to_later_transfer() public {
        _mint(alice, 3);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;

        vm.prank(alice);
        token.safeSendBatch(bob, ids); // preserving

        // Token 3 is still alice's; a plain transferFrom must REROLL it.
        uint256 before3 = token.comboOf(3);
        vm.prank(alice);
        token.transferFrom(alice, bob, 3);

        assertTrue(token.comboOf(3) != before3, "guard must not leak past the batch");
    }

    // ------------------------------------------------------------------
    // Events + degenerate input.
    // ------------------------------------------------------------------
    function test_safeSendBatch_emits_SafeSent_per_token() public {
        _mint(alice, 2);
        uint256[] memory ids = _ids(2);

        vm.expectEmit(true, true, true, false, address(token));
        emit SafeSent(1, alice, bob);
        vm.expectEmit(true, true, true, false, address(token));
        emit SafeSent(2, alice, bob);

        vm.prank(alice);
        token.safeSendBatch(bob, ids);
    }

    function test_safeSendBatch_empty_is_noop() public {
        _mint(alice, 1);
        uint256 before = token.comboOf(1);

        vm.prank(alice);
        token.safeSendBatch(bob, new uint256[](0));

        assertEq(token.ownerOf(1), alice);
        assertEq(token.comboOf(1), before);
    }

    // Single-element batch must behave exactly like safeSend.
    function test_safeSendBatch_single_matches_safeSend() public {
        _mint(alice, 1);
        uint256 before = token.comboOf(1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(alice);
        token.safeSendBatch(bob, ids);

        assertEq(token.comboOf(1), before, "preserved");
        assertEq(token.ownerOf(1), bob);
    }
}
