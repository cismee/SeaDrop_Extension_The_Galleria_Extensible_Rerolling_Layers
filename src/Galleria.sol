// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDrop } from "seadrop/ERC721SeaDrop.sol";
import { TraitRegistry } from "./TraitRegistry.sol";
import { ComboLib } from "./ComboLib.sol";
import { SamplingLib } from "./SamplingLib.sol";
import { Renderer } from "./Renderer.sol";

/**
 * @dev Minimal view of Seaport's canonical ConduitController. `getKey` is a
 *      reverse lookup: for an address the controller deployed as a conduit it
 *      returns that conduit's (non-zero) key; for anything else it reverts. We use
 *      it to recognise ANY Seaport conduit as a trait-preserving operator, not just
 *      OpenSea's. See https://github.com/ProjectOpenSea/seaport.
 */
interface IConduitController {
    function getKey(address conduit) external view returns (bytes32 conduitKey);
}

/**
 * @title  Galleria
 * @notice A fully on-chain, generative 1-of-1 collection built as an OpenSea
 *         SeaDrop extension (extends the canonical ERC721SeaDrop).
 *
 *         Art is NEVER stored or composited on-chain. Each token stores only a
 *         packed uint256 combo of four trait indices; the image is assembled
 *         lazily at read time (tokenURI) from a shared static PNG library in
 *         TraitRegistry. A token's traits REGENERATE ("reroll") when it moves
 *         outside a blessed conduit. Every combo is 1-of-1, enforced here.
 *
 *  ────────────────────────────────────────────────────────────────────────────
 *  TODO: confirm — open parameters (defaults chosen; behaviour flagged):
 *   1. Field width = 8 bits (256 max) per growable layer (painting/frame/
 *      background). Confirm 256 exceeds the most you'd ever reach in EACH.
 *   2. Resample cap N = 10 (RESAMPLE_CAP).
 *   3. Reroll entropy = PREVRANDAO folded into a per-draw nonce (isolated in
 *      SamplingLib._entropyBase for a later VRF swap). It is not caller-controlled,
 *      but PREVRANDAO is known during execution and the reroll is retryable across
 *      blocks, so a holder CAN grind for a desired combo — revert on an unwanted
 *      result in a wrapper and retry next block — and keep the win by holding or
 *      selling through a blessed conduit (which preserves). This is INTENDED and
 *      permitted: grinding out rares is an accepted game mechanic here, not an
 *      attack we defend against. To make combos grind-resistant, swap _entropyBase
 *      for a VRF — nothing else in the repo moves.
 *   4. Uniqueness key = all FOUR layers (label is independent decorative — the
 *      chosen label-coupling model). N_eff is a four-layer product.
 *   5. New options enter only via reroll once mint is closed (mint window is the
 *      SeaDrop drop; after it ends, appended options seep in via rerolls only).
 *   6. Cross-layer compatibility: every option freely combines with every other
 *      (no "this frame only fits that painting"). Combo space is the full product.
 *  ────────────────────────────────────────────────────────────────────────────
 *
 *  UNIQUENESS — enforced by five rules, each tagged inline where it lives:
 *   1. Single writer        — _writeCombo is the ONLY function that mutates
 *                             _comboToToken on the settle path.
 *   2. Lock-until-success   — on reroll the OLD combo stays claimed until a new
 *                             winner exists; release-old happens only then.
 *   3. Capmiss-is-noop      — after N failed attempts a reroll keeps the old
 *                             traits and does NOT revert (never soulbind).
 *   4. Canonical packing    — see ComboLib.
 *   5. Claim-as-you-go      — each combo is written before the next draw, so
 *                             later draws in a batch see earlier ones.
 */
contract Galleria is ERC721SeaDrop {
    /* ------------------------------------------------------------------ */
    /*                              Config                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Fixed supply.
    uint256 public constant SUPPLY = 2_618;

    /// @notice Resample cap. If all N candidate combos collide, a reroll keeps
    ///         the old traits (Rule 3). At the shipped config (2,618 supply against
    ///         an N_eff of 144,342 — 1.81% occupancy) a capmiss has probability
    ///         ~4e-18; this branch exists for correctness, not because it will fire.
    uint256 public constant RESAMPLE_CAP = 10;

    /// @notice OpenSea's canonical conduit — seeded into the blessed set so
    ///         standard OpenSea transfers preserve traits. Admin-editable. Note
    ///         this is now redundant with the ConduitController recognition below
    ///         (the OpenSea conduit is a registered Seaport conduit); it is kept as
    ///         a static fallback that works even on a chain where the controller
    ///         lookup is unavailable.
    address public constant OPENSEA_CONDUIT =
        0x1E0049783F008A0085193E00003D00cd54003c71;

    /// @notice Seaport's canonical ConduitController, deployed at the same
    ///         deterministic address on every Seaport-supported chain. Any conduit
    ///         it created is treated as a trait-preserving operator, so a sale
    ///         routed through ANY Seaport conduit (not only OpenSea's) preserves.
    ///         If the controller is not deployed on the target chain the lookup is
    ///         skipped and only the manual `blessedConduit` set applies.
    IConduitController public constant SEAPORT_CONDUIT_CONTROLLER =
        IConduitController(0x00000000F9490004C11Cef243f5400493c00Ad63);

    /// @notice Known marketplace routers seeded into the blessed set so ALL Blur
    ///         and Seaport sales preserve traits — not only conduit-routed ones.
    ///
    ///         - Blur moves NFTs through its ExecutionDelegate, so that contract is
    ///           `msg.sender` for a Blur sale/loan.
    ///         - A Seaport DIRECT fill (conduitKey == 0) bypasses the conduit, so
    ///           the Seaport CORE contract is `msg.sender`. (Conduit-routed Seaport
    ///           fills are already recognised dynamically above.)
    ///
    ///         All are admin-editable via setBlessedConduit, so newer Seaport
    ///         versions / a future Blur delegate can be added without a redeploy.
    ///         Addresses verified against Etherscan (Ethereum mainnet). On another
    ///         chain re-check them; a wrong/missing address only fails safe (that
    ///         sale would reroll) and is fixable post-deploy.
    address public constant BLUR_EXECUTION_DELEGATE =
        0x00000000000111AbE46ff893f3B2fdF1F759a8A8;
    address public constant SEAPORT_1_6 =
        0x0000000000000068F116a894984e2DB1123eB395;
    address public constant SEAPORT_1_5 =
        0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC;

    // NOTE — do NOT add OpenSea's TransferHelper (0x0000000000c2d145a2526bD8C716263bFeBe1A72)
    // to the excluded set. It looks like it should belong there: some wallet "send" flows
    // route a plain transfer through it, and those SHOULD reroll. But excluding it does
    // nothing, because the helper never reaches this contract as `msg.sender`.
    // `TransferHelper.bulkTransfer` with a non-zero conduitKey delegates the actual
    // `transferFrom` to a Seaport CONDUIT, so the token sees the conduit — byte for byte
    // what a genuine conduit-routed sale looks like. Verified on Base with tx
    // 0xd2c12301b89a81e1f0eef551638cc90dc80557626bc1495a84b7163aaef3e7b0: three tokens
    // moved through the helper and not one `Reroll` was emitted.
    // Excluding the conduit itself WOULD close it, but would equally make every
    // conduit-routed OpenSea sale reroll. That trade-off cannot be resolved here — the
    // information needed to tell a send from a sale exists only in full transaction
    // context, i.e. off-chain. `forceReroll` is the remediation lever for it.

    /// @notice The shared art + weight library. Immutable wiring.
// Deliberately lower-case: this is a PUBLIC immutable, so its name IS the ABI
// getter. Renaming to REGISTRY would rename registry() and break the deploy
// scripts, the docs and any deployed integration.
// forge-lint: disable-next-line(screaming-snake-case-immutable)
    TraitRegistry public immutable registry;

    /* ------------------------------------------------------------------ */
    /*                          Uniqueness state                          */
    /* ------------------------------------------------------------------ */

    /// @notice tokenId => packed combo (the token's entire per-token storage).
    mapping(uint256 => uint256) internal _tokenCombo;

    /// @notice packed combo => tokenId + 1. `0` means the combo is free, which
    ///         also gives a reverse lookup and a free existence check. Storing
    ///         tokenId+1 (not tokenId) is what lets combo value `0` — the all-zero
    ///         index combo — be a legal, distinguishable key.
    mapping(uint256 => uint256) internal _comboToToken;

    /// @notice Operators whose moves PRESERVE traits (no reroll). Seeded with the
    ///         known Blur + Seaport marketplace routers (see constants); admin-
    ///         editable. A move preserves if its operator is in this set OR is a
    ///         Seaport conduit (recognised dynamically).
    mapping(address => bool) public blessedConduit;

    /// @notice Operators explicitly forced to REROLL, overriding BOTH the blessed set
    ///         and dynamic Seaport-conduit recognition. Lets a router that would
    ///         otherwise be treated as preserving be treated as a plain transfer.
    ///         Takes precedence over `blessedConduit`/`_isSeaportConduit`; `safeSend`
    ///         still preserves regardless. Admin-editable, and seeded EMPTY — it only
    ///         works on the address that actually arrives as `msg.sender`, which rules
    ///         out routers that delegate to a conduit (see the TransferHelper note above).
    mapping(address => bool) public excludedConduit;

    /// @dev One-shot guard set by `safeSend` for the duration of its own transfer,
    ///      telling `_beforeTokenTransfers` to preserve instead of reroll. It is
    ///      CONSUMED (reset) inside the hook — which runs before any ERC721 receiver
    ///      callback — so a malicious `to` contract can never reuse it to preserve a
    ///      re-entrant transfer. Never persists across transactions (reset on use,
    ///      and any revert rolls it back).
    bool private _preservingSend;

    /* ------------------------------------------------------------------ */
    /*                              Errors                                 */
    /* ------------------------------------------------------------------ */

    /// @notice A mint could not settle a unique combo: either every one of the
    ///         RESAMPLE_CAP candidates collided, or a layer has zero rollable weight.
    ///         A mint reverts (nothing minted, nothing soulbound) where a reroll
    ///         degrades to a no-op — see Rule 3.
    error MintCapMiss();

    /// @notice `safeSend` / `safeSendBatch` require the CALLER to be the token's
    ///         current owner. An approved operator is deliberately not enough.
    error NotTokenOwner();

    /* ------------------------------------------------------------------ */
    /*                              Events                                 */
    /* ------------------------------------------------------------------ */

    event ComboSettled(uint256 indexed tokenId, uint256 combo, bool isMint);
    event Reroll(uint256 indexed tokenId, uint256 oldCombo, uint256 newCombo);
    event CapMiss(uint256 indexed tokenId); // reroll hit the resample cap; old traits kept
    /// @notice An owner-initiated reroll was ATTEMPTED on this token (see forceReroll).
    ///         Whether it changed anything is told by the accompanying event: a
    ///         `Reroll` means new traits, a `CapMiss` means the old ones were kept.
    event ForcedReroll(uint256 indexed tokenId);
    event BlessedConduitSet(address indexed operator, bool blessed);
    event ExcludedConduitSet(address indexed operator, bool excluded);
    event SafeSent(uint256 indexed tokenId, address indexed from, address indexed to);

    /* ------------------------------------------------------------------ */
    /*                            Constructor                             */
    /* ------------------------------------------------------------------ */

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory allowedSeaDrop_,
        TraitRegistry registry_
    ) ERC721SeaDrop(name_, symbol_, allowedSeaDrop_) {
        registry = registry_;

        // Fixed supply for the drop.
        _maxSupply = SUPPLY;

        // Seed the blessed set with the known Blur + Seaport marketplace routers
        // so all their sales preserve traits. (Seaport conduit fills are also
        // recognised dynamically via SEAPORT_CONDUIT_CONTROLLER.)
        _seedBlessed(OPENSEA_CONDUIT);
        _seedBlessed(BLUR_EXECUTION_DELEGATE);
        _seedBlessed(SEAPORT_1_6);
        _seedBlessed(SEAPORT_1_5);

        // The excluded set starts EMPTY — populate it post-deploy via
        // setExcludedConduit if a router ever needs forcing to reroll.
    }

    /// @dev Constructor helper: mark an operator preserving and log it.
    function _seedBlessed(address operator) private {
        blessedConduit[operator] = true;
        emit BlessedConduitSet(operator, true);
    }

    /* ------------------------------------------------------------------ */
    /*                        Transfer hook (branch)                      */
    /* ------------------------------------------------------------------ */

    /**
     * @dev The reroll-on-transfer mechanic. Runs before every mint, transfer and
     *      burn (ERC721A calls this once per batch: mint may have quantity > 1,
     *      transfers and burns are always quantity 1).
     *
     *      Branch selection:
     *        - from == 0 (mint)            → establish initial combo (single writer).
     *        - to   == 0 (burn)            → release combo (never orphan-lock it).
     *        - operator is a preserving    → PRESERVE combo, no reroll. Preserving =
     *          operator                       in the manual `blessedConduit` set OR
     *                                         any conduit registered with Seaport's
     *                                         canonical ConduitController.
     *        - anything else               → REROLL via the single writer.
     *
     *      Preserving operators cover ALL Blur and Seaport sales: any Seaport
     *      conduit (dynamic), Seaport core for direct fills, and Blur's Execution-
     *      Delegate (both seeded). What still REROLLS is a move with no marketplace
     *      operator — a raw transferFrom or a cold-wallet move.
     *
     *      CONSEQUENCE (accepted): preserving a move is not exclusive to a sale. The
     *      owner has a first-class self-service path — safeSend — to move a token
     *      without rerolling, and marketplace operators are permissionless to invoke
     *      besides. A reroll therefore happens only on a plain transferFrom (or a
     *      non-preserving operator); it is effectively opt-in for the holder.
     */
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override {
        // Chain the base hook (Limit Break transfer validator for royalties).
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        if (from == address(0)) {
            // MINT: establish an initial combo for each token in the batch.
            // Claim-as-you-go (Rule 5): each combo is written before the next
            // token samples, so intra-batch dupes are impossible.
            for (uint256 i = 0; i < quantity; ) {
                _writeCombo(startTokenId + i, true);
                unchecked {
                    ++i;
                }
            }
            return;
        }

        if (to == address(0)) {
            // BURN: clear comboToToken so the combo is freed, not orphan-locked.
            for (uint256 i = 0; i < quantity; ) {
                _releaseCombo(startTokenId + i);
                unchecked {
                    ++i;
                }
            }
            return;
        }

        // TRANSFER. A preserving move keeps traits; a raw transferFrom or cold-
        // wallet move rerolls. A move preserves if it is an owner-initiated safeSend
        // (one-shot guard, consumed HERE before any receiver callback so it can't be
        // reused re-entrantly), OR the operator is manually blessed (Blur delegate,
        // Seaport core, OpenSea conduit), OR any conduit registered with Seaport's
        // ConduitController.
        bool preserving = _preservingSend;
        if (preserving) {
            _preservingSend = false; // consume the one-shot before external callbacks
        }
        // safeSend (the owner's one-shot) always preserves. Otherwise a move preserves
        // only if the operator is recognised (blessed OR a Seaport conduit) AND is NOT
        // explicitly excluded. The excluded set overrides recognition, so a router like
        // OpenSea's TransferHelper — which a wallet "send" may route through — rerolls.
        if (
            preserving ||
            (!excludedConduit[msg.sender] &&
                (blessedConduit[msg.sender] || _isSeaportConduit(msg.sender)))
        ) {
            return; // preserve — no state change
        }
        for (uint256 i = 0; i < quantity; ) {
            _writeCombo(startTokenId + i, false); // non-conduit move → reroll
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice True iff `operator` is a conduit deployed by Seaport's canonical
     *         ConduitController — i.e. a transfer it performs is a Seaport-routed
     *         marketplace move that should preserve traits.
     * @dev    Cannot be spoofed: we ask the trusted controller about `operator`,
     *         we never call `operator` itself. `getKey` reverts for any
     *         non-conduit, so a `try/catch` cleanly answers the question. The
     *         `code.length` guard makes this a safe no-op (→ reroll) on a chain
     *         where the controller is not deployed: without it, a staticcall to a
     *         codeless address would "succeed" with empty returndata and the ABI
     *         decode of the missing `bytes32` would revert UNCAUGHT and brick the
     *         transfer. Belt-and-suspenders for the never-brick guarantee.
     */
    function _isSeaportConduit(address operator) internal view returns (bool) {
        if (address(SEAPORT_CONDUIT_CONTROLLER).code.length == 0) return false;
        try SEAPORT_CONDUIT_CONTROLLER.getKey(operator) returns (bytes32 key) {
            return key != bytes32(0);
        } catch {
            return false;
        }
    }

    /* ------------------------------------------------------------------ */
    /*                    The single uniqueness writer                    */
    /* ------------------------------------------------------------------ */

    /**
     * @notice The ONE function that mutates `_comboToToken` on the settle path
     *         (Rule 1: single writer). Used identically by mint and reroll.
     *
     * @param tokenId The token being settled.
     * @param isMint  True for the initial mint (no prior combo to release), false
     *                for a reroll (the old combo is currently claimed by tokenId).
     *
     * @dev Rules 2, 3 and 5 all live here — see inline tags.
     */
    function _writeCombo(uint256 tokenId, bool isMint) internal {
        // Sampling reverts if ANY layer currently has zero total rollable weight
        // (an empty or fully-retired CDF) — that is exactly the precondition of
        // SamplingLib.sampleBucket. If we let that revert propagate it would brick
        // the transfer and accidentally soulbind the token, breaking the "a reroll
        // never reverts" guarantee. So detect it up front and degrade to the
        // capmiss path instead (Rule 3): a mint reverts (nothing minted, nothing
        // soulbound), a reroll keeps the old traits and does not revert. This is an
        // admin-misconfig backstop; under a valid weight config it never triggers.
        if (!_allLayersSampleable()) {
            if (isMint) revert MintCapMiss();
            emit CapMiss(tokenId);
            return;
        }

        uint256 entropyBase = SamplingLib._entropyBase();

        // On a reroll, the OLD combo stays claimed by this token throughout the
        // loop (Rule 2: lock-until-success). We never release it before a winner
        // exists — which also means a reroll can never re-land its own combo,
        // because that candidate reads back as taken (claimant == tokenId + 1).
        uint256 oldCombo = _tokenCombo[tokenId];

        for (uint256 attempt = 0; attempt < RESAMPLE_CAP; ) {
            uint256 candidate = _sampleCombo(tokenId, attempt, entropyBase);
            uint256 k = ComboLib.key(candidate);

            if (_comboToToken[k] == 0) {
                // Winner found.
                if (!isMint) {
                    // Rule 2: release-old ONLY now that a new winner exists.
                    // (Never release-old first — that would open a collision window
                    //  and could soulbind on failure.)
                    _comboToToken[ComboLib.key(oldCombo)] = 0;
                    emit Reroll(tokenId, oldCombo, candidate);
                    // EIP-4906: a reroll changes the token's traits (candidate can
                    // never equal oldCombo — Rule 2 keeps oldCombo claimed), so signal
                    // marketplaces to refresh this token's cached metadata. Without it
                    // the image/attributes stay stale until a manual refresh. Emitted
                    // as a single-token range; the event + interfaceId 0x49064906 come
                    // from ERC721ContractMetadata.
                    emit BatchMetadataUpdate(tokenId, tokenId);
                }
                // Rule 5: claim-new immediately, before any later draw in a batch.
                _comboToToken[k] = tokenId + 1;
                _tokenCombo[tokenId] = candidate;
                emit ComboSettled(tokenId, candidate, isMint);
                return;
            }

            unchecked {
                ++attempt;
            }
        }

        // Rule 3: capmiss.
        if (isMint) {
            // A mint has no old combo to fall back on; leaving the token unclaimed
            // would break the injectivity invariant. Reverting the mint soulbinds
            // nothing (the token is not yet fully minted at this hook). This path
            // has probability ~4e-18 at the shipped 1.81% occupancy.
            revert MintCapMiss();
        }
        // On a reroll we KEEP the old traits and DO NOT revert. Reverting would
        // brick the transfer and accidentally soulbind the token. No state changed
        // (old combo was never released), so the invariant still holds.
        emit CapMiss(tokenId);
    }

    /**
     * @notice Sample a full four-layer candidate combo for one attempt.
     * @dev    Each layer draw gets its own per-draw nonce (tokenId, attempt,
     *         layer) so draws never collapse together within a batch or an
     *         attempt. Sampling reads the registry's weighted CDFs.
     */
    function _sampleCombo(
        uint256 tokenId,
        uint256 attempt,
        uint256 entropyBase
    ) internal view virtual returns (uint256) {
        uint8 painting = registry.sample(
            ComboLib.LAYER_PAINTING,
            SamplingLib.seed(entropyBase, tokenId, attempt, ComboLib.LAYER_PAINTING)
        );
        uint8 label = registry.sample(
            ComboLib.LAYER_LABEL,
            SamplingLib.seed(entropyBase, tokenId, attempt, ComboLib.LAYER_LABEL)
        );
        uint8 background = registry.sample(
            ComboLib.LAYER_BACKGROUND,
            SamplingLib.seed(entropyBase, tokenId, attempt, ComboLib.LAYER_BACKGROUND)
        );
        uint8 frame = registry.sample(
            ComboLib.LAYER_FRAME,
            SamplingLib.seed(entropyBase, tokenId, attempt, ComboLib.LAYER_FRAME)
        );
        return ComboLib.pack(painting, label, background, frame);
    }

    /**
     * @notice True iff every layer currently has positive total rollable weight,
     *         i.e. `registry.sample` cannot revert for any of the four layers.
     * @dev    `registry.totalWeight(layer)` returns 0 for both an empty CDF and a
     *         zero-total (all-retired) layer — exactly the two cases in which
     *         SamplingLib.sampleBucket reverts — so this is a precise precondition
     *         check, not a broad try/catch that could mask an unrelated revert.
     */
    function _allLayersSampleable() internal view returns (bool) {
        for (uint8 layer = 0; layer < uint8(ComboLib.NUM_LAYERS); ) {
            if (registry.totalWeight(layer) == 0) return false;
            unchecked {
                ++layer;
            }
        }
        return true;
    }

    /**
     * @notice Free a token's combo (burn path). Only clears the map entry if this
     *         token is the current claimant, then drops the per-token combo.
     */
    function _releaseCombo(uint256 tokenId) internal {
        uint256 combo = _tokenCombo[tokenId];
        if (_comboToToken[ComboLib.key(combo)] == tokenId + 1) {
            _comboToToken[ComboLib.key(combo)] = 0;
        }
        delete _tokenCombo[tokenId];
    }

    /* ------------------------------------------------------------------ */
    /*                              Rendering                              */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Fully on-chain metadata: base64 JSON → base64 SVG → stacked base64
     *         PNGs, assembled from the token's unpacked indices. Runs on the
     *         caller's node (view), not on holder gas.
     */
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        return Renderer.tokenURI(registry, tokenId, _tokenCombo[tokenId]);
    }

    /* ------------------------------------------------------------------ */
    /*                          Admin: conduits                           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Add/remove a blessed conduit operator. Owner-only (never approved
     *         operators). Editing this changes which moves preserve vs reroll.
     */
    function setBlessedConduit(address operator, bool blessed) external onlyOwner {
        blessedConduit[operator] = blessed;
        emit BlessedConduitSet(operator, blessed);
    }

    /**
     * @notice Add/remove an operator from the EXCLUDED set — operators that must
     *         REROLL even if they would otherwise be recognised as preserving (blessed
     *         or a Seaport conduit). Owner-only. Use to force a wallet "transfer helper"
     *         / router to behave like a plain transfer. `safeSend` is unaffected.
     */
    function setExcludedConduit(address operator, bool excluded) external onlyOwner {
        excludedConduit[operator] = excluded;
        emit ExcludedConduitSet(operator, excluded);
    }

    /* ------------------------------------------------------------------ */
    /*                       Admin: forced reroll                         */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Reroll tokens IN PLACE, without moving them. Owner-only.
     *
     * @param  tokenIds The tokens to reroll. Ids that do not exist (never minted or
     *                  since burned) are SKIPPED, so a batch assembled off-chain can
     *                  never revert wholesale because one token changed state between
     *                  detection and execution.
     *
     * @dev    Remediation lever for moves that PRESERVED traits but should not have.
     *         The transfer hook cannot always tell a marketplace sale from a plain
     *         send: OpenSea's TransferHelper delegates the actual `transferFrom` to a
     *         Seaport conduit, so the token sees the CONDUIT as `msg.sender` — byte
     *         for byte what a genuine conduit-routed sale looks like. Nothing at
     *         `_beforeTokenTransfers` can separate the two; that distinction only
     *         exists in full transaction context, i.e. OFF-CHAIN. So the classification
     *         is made off-chain and applied here.
     *
     *         Routes through the single writer (Rule 1), so every uniqueness rule
     *         holds unchanged: lock-until-success on the old combo (Rule 2),
     *         capmiss-is-noop when all RESAMPLE_CAP candidates collide (Rule 3), and
     *         claim-as-you-go so earlier tokens in the batch are visible to later
     *         draws (Rule 5). Because `_writeCombo` already emits
     *         `BatchMetadataUpdate`, marketplaces refresh with no extra call.
     *
     *         Never moves a token and never touches ownership or approvals.
     *
     *         NOTE this is a genuine centralisation lever: the owner can rewrite any
     *         holder's traits at any time. `ForcedReroll` is emitted per token so the
     *         use of that power is auditable on-chain.
     */
    function forceReroll(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            if (_exists(tokenId)) {
                emit ForcedReroll(tokenId);
                _writeCombo(tokenId, false); // isMint=false → the reroll path
            }
            unchecked {
                ++i;
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                            Safe send                               */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Send a token to `to` WITHOUT rerolling its traits — a self-service
     *         preserving transfer, e.g. to move a token between your own wallets or
     *         gift it while keeping the current artwork.
     *
     * @param  to      Recipient. As with `safeTransferFrom`, a contract recipient
     *                 must implement `onERC721Received`.
     * @param  tokenId The caller's token to send.
     *
     * @dev    Owner-only: the caller must be the token's CURRENT OWNER, not an
     *         approved operator. Routes through `safeTransferFrom` (so the standard
     *         receiver check and Transfer event still apply) with the one-shot
     *         `_preservingSend` guard set, which the transfer hook consumes to skip
     *         the reroll. The guard is reset inside the hook before any receiver
     *         callback, so a re-entrant transfer cannot ride on it. Uniqueness is
     *         untouched — the token keeps the unique combo it already claims.
     */
    function safeSend(address to, uint256 tokenId) external {
        _safeSend(to, tokenId);
    }

    /**
     * @notice Send SEVERAL tokens to `to` WITHOUT rerolling any of them — the batch
     *         form of `safeSend`, e.g. moving a whole set to a new wallet in one tx.
     *
     * @param  to       Recipient. A contract recipient must implement
     *                  `onERC721Received`; it is called once per token.
     * @param  tokenIds The caller's tokens to send. Every id must be owned by the
     *                  caller at the moment it is reached, so a repeated id reverts
     *                  (ownership has already moved on by the second occurrence).
     *
     * @dev    ATOMIC: any failing token reverts the whole batch, so a partially
     *         preserved / partially rerolled outcome is impossible.
     *
     *         The one-shot `_preservingSend` guard is re-armed for EACH token,
     *         because the transfer hook CONSUMES it per transfer. Arming it once
     *         outside the loop would preserve only the first token and silently
     *         reroll the rest — the exact bug this note exists to prevent.
     *
     *         Re-entrancy is unchanged from the single-token path: the guard is
     *         consumed inside the hook before any receiver callback, so a malicious
     *         `to` cannot ride it to preserve a transfer of its own.
     */
    function safeSendBatch(address to, uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; ) {
            _safeSend(to, tokenIds[i]); // re-arms the one-shot per token
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Shared body of `safeSend` / `safeSendBatch`: arm the one-shot, route
    ///      through `safeTransferFrom` so the receiver check and Transfer event still
    ///      apply, then clear defensively (the hook has already consumed it).
    function _safeSend(address to, uint256 tokenId) private {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _preservingSend = true;
        safeTransferFrom(msg.sender, to, tokenId);
        _preservingSend = false;
        emit SafeSent(tokenId, msg.sender, to);
    }

    /* ------------------------------------------------------------------ */
    /*                               Views                                */
    /* ------------------------------------------------------------------ */

    /// @notice The packed combo held by a token.
    function comboOf(uint256 tokenId) external view returns (uint256) {
        return _tokenCombo[tokenId];
    }

    /// @notice Raw reverse-lookup value: tokenId + 1, or 0 if the combo is free.
    function comboToToken(uint256 combo) external view returns (uint256) {
        return _comboToToken[combo];
    }

    /// @notice The four unpacked trait indices for a token.
    function traitsOf(uint256 tokenId)
        external
        view
        returns (
            uint8 painting,
            uint8 label,
            uint8 background,
            uint8 frame
        )
    {
        return ComboLib.unpack(_tokenCombo[tokenId]);
    }
}
