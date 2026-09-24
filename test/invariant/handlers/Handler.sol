// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { IERC721Receiver } from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import { Galleria } from "../../../src/Galleria.sol";
import { TraitRegistry } from "../../../src/TraitRegistry.sol";

/**
 * @notice Invariant handler. The fuzzer calls the target selectors below in
 *         random sequences; each drives mint / reroll-transfer / conduit-transfer
 *         / burn through the real contract. The handler tracks the live token set
 *         so the invariant contract can assert injectivity and map-consistency.
 *
 *         Every action varies block entropy (vm.difficulty) so draws differ across
 *         calls — otherwise a whole run would share one PREVRANDAO.
 */
contract Handler is CommonBase, StdCheats, StdUtils, IERC721Receiver {
    // Test harness field; lower-case mirrors the contracts under test.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Galleria public immutable token;
    // Test harness field; lower-case mirrors the contracts under test.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    TraitRegistry public immutable registry;
    // Test harness field; lower-case mirrors the contracts under test.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable seaDrop;
    // Test harness field; lower-case mirrors the contracts under test.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable conduit;

    uint256 public constant MAX_SUPPLY_TEST = 400; // keep runs bounded

    address[] internal actors;
    uint256[] public liveTokens;
    mapping(uint256 => bool) public isLive;
    mapping(uint256 => uint256) internal _liveIndex; // tokenId => index+1 in liveTokens

    // Coverage counters (handy when debugging a run).
    uint256 public mints;
    uint256 public rerolls;
    uint256 public conduitMoves;
    uint256 public burns;
    uint256 public capMisses;

    constructor(
        Galleria token_,
        TraitRegistry registry_,
        address seaDrop_,
        address conduit_
    ) {
        token = token_;
        registry = registry_;
        seaDrop = seaDrop_;
        conduit = conduit_;
        actors.push(makeAddr("h_alice"));
        actors.push(makeAddr("h_bob"));
        actors.push(makeAddr("h_carol"));
        actors.push(makeAddr("h_dave"));
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _entropy(uint256 seed) internal {
        vm.difficulty(uint256(keccak256(abi.encode(seed, block.number, liveTokens.length))));
    }

    function _track(uint256 tokenId) internal {
        if (!isLive[tokenId]) {
            isLive[tokenId] = true;
            liveTokens.push(tokenId);
            _liveIndex[tokenId] = liveTokens.length; // index+1
        }
    }

    function _untrack(uint256 tokenId) internal {
        if (isLive[tokenId]) {
            isLive[tokenId] = false;
            uint256 idx = _liveIndex[tokenId] - 1;
            uint256 last = liveTokens[liveTokens.length - 1];
            liveTokens[idx] = last;
            _liveIndex[last] = idx + 1;
            liveTokens.pop();
            delete _liveIndex[tokenId];
        }
    }

    /* --------------------------- target selectors --------------------------- */

    /// @notice Mint 1..4 tokens to a pseudo-random actor.
    function mint(uint256 actorSeed, uint256 qtySeed) external {
        if (token.totalSupply() >= MAX_SUPPLY_TEST) return;
        uint256 qty = bound(qtySeed, 1, 4);
        if (token.totalSupply() + qty > MAX_SUPPLY_TEST) {
            qty = MAX_SUPPLY_TEST - token.totalSupply();
        }
        _entropy(actorSeed);

        // ERC721A assigns sequential ids by total-minted (startTokenId == 1); burns
        // never reuse ids, so the next id is always totalMinted + 1.
        uint256 startId = _totalMintedProxy() + 1;
        vm.prank(seaDrop);
        token.mintSeaDrop(_actor(actorSeed), qty);

        for (uint256 i = 0; i < qty; ++i) {
            _track(startId + i);
        }
        mints++;
    }

    /// @notice Non-conduit transfer of a live token → reroll.
    function rerollTransfer(uint256 tokenSeed, uint256 toSeed) external {
        if (liveTokens.length == 0) return;
        uint256 tokenId = liveTokens[tokenSeed % liveTokens.length];
        address from = token.ownerOf(tokenId);
        address to = _actor(toSeed);
        _entropy(tokenSeed);

        uint256 comboBefore = token.comboOf(tokenId);
        vm.prank(from);
        token.transferFrom(from, to, tokenId); // msg.sender = from (not blessed) → reroll

        if (token.comboOf(tokenId) == comboBefore) capMisses++;
        else rerolls++;
    }

    /// @notice Blessed-conduit transfer of a live token → preserve.
    function conduitTransfer(uint256 tokenSeed, uint256 toSeed) external {
        if (liveTokens.length == 0) return;
        uint256 tokenId = liveTokens[tokenSeed % liveTokens.length];
        address from = token.ownerOf(tokenId);
        address to = _actor(toSeed);

        vm.prank(from);
        token.setApprovalForAll(conduit, true);
        _entropy(tokenSeed);
        vm.prank(conduit);
        token.transferFrom(from, to, tokenId); // blessed operator → preserve
        conduitMoves++;
    }

    /// @notice Burn a live token.
    function burn(uint256 tokenSeed) external {
        if (liveTokens.length == 0) return;
        uint256 tokenId = liveTokens[tokenSeed % liveTokens.length];
        address from = token.ownerOf(tokenId);
        _entropy(tokenSeed);
        vm.prank(from);
        token.burn(tokenId);
        _untrack(tokenId);
        burns++;
    }

    /* ------------------------------- views -------------------------------- */

    function liveCount() external view returns (uint256) {
        return liveTokens.length;
    }

    function liveAt(uint256 i) external view returns (uint256) {
        return liveTokens[i];
    }

    function _totalMintedProxy() internal view returns (uint256) {
        // getMintStats returns (minterNumMinted, currentTotalSupply, maxSupply)
        // where currentTotalSupply == _totalMinted(). Use it to find next id.
        (, uint256 totalMinted, ) = token.getMintStats(address(0));
        return totalMinted;
    }
}
