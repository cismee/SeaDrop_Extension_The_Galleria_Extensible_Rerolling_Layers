// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @title  SamplingLib
 * @notice Weighted per-layer draws via cumulative-weight (CDF) binary search,
 *         plus the per-draw entropy seed. Both halves are pure/library code so
 *         the invariant suite can target them directly.
 *
 *         WEIGHTING vs UNIQUENESS. Weights shape trait-*population* statistics
 *         across the 2,618 supply. They do NOT create rare combos — uniqueness
 *         already makes every combo 1-of-1. Weighting does shrink the *effective*
 *         combo space N_eff = 1 / Σ pᵢ², and because the four layers are
 *         independent that shrink compounds multiplicatively across them. Keep the
 *         combined N_eff well above supply (target ≥ ~30×). See analysis/neff.
 *
 *         NO MODULO SAMPLING. Modulo over a weight total biases low buckets; we
 *         draw uniformly in [0, totalWeight) and binary-search the CDF instead.
 */
library SamplingLib {
    /* ------------------------------------------------------------------ */
    /*                       Per-draw entropy seed                         */
    /* ------------------------------------------------------------------ */

    /**
     * @notice The chain entropy source, isolated so it can be swapped for a VRF
     *         later without touching any other line of this repo.
     * @dev    Returns PREVRANDAO. On Solidity 0.8.18+ this is `block.prevrandao`;
     *         at our pinned 0.8.17 the identifier does not exist yet, so we read
     *         the same opcode (0x44) via `block.difficulty`. On any post-merge
     *         chain the two are byte-identical.
     *
     *         Known property (flagged, INTENDED): PREVRANDAO is not caller-
     *         controlled, but it is known during execution and the reroll is
     *         retryable across blocks. A holder can therefore grind for a desired
     *         combo — revert on an unwanted result and retry in a later block — and
     *         keep the win by holding or selling through a blessed conduit (which
     *         preserves, no reroll). That is a permitted game mechanic here, not an
     *         attack we defend against. To make combos grind-resistant, replace only
     *         this function with a VRF draw.
     */
    function _entropyBase() internal view returns (uint256) {
        return block.difficulty; // == block.prevrandao (PREVRANDAO / 0x44) post-merge
    }

    /**
     * @notice Per-draw nonce. MANDATORY — without a per-draw nonce every layer
     *         draw inside one batched `mintSeaDrop(quantity)` would share the same
     *         block entropy and the whole batch would collapse to identical combos.
     * @dev    Folds in:
     *           - the block entropy base (PREVRANDAO),
     *           - `tokenId`      → distinct across a batch,
     *           - `attempt`      → distinct across resample attempts for one token,
     *           - `layer`        → distinct across the four layer draws of one attempt.
     *         The (tokenId, attempt, layer) triple makes every individual draw's
     *         seed unique within a transaction, which is what actually prevents the
     *         intra-batch collapse; `claim-as-you-go` in the writer then guarantees
     *         earlier combos are visible to later draws.
     */
    function seed(
        uint256 entropyBase,
        uint256 tokenId,
        uint256 attempt,
        uint256 layer
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(entropyBase, tokenId, attempt, layer)));
    }

    /* ------------------------------------------------------------------ */
    /*                          CDF bucket draw                           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Draw an option index from a cumulative-weight array.
     * @param  cdf  Strictly-non-decreasing cumulative weights, one entry per
     *              option index in the layer. `cdf[i]` is the running total of
     *              effective weight through option `i`. A retired / non-rollable
     *              option contributes a zero-width bucket (cdf[i] == cdf[i-1]) and
     *              can therefore never be selected. `cdf[last]` is the total.
     * @param  rand Any uint256 of entropy; reduced modulo the total to a uniform
     *              draw in [0, totalWeight). (Modulo here is over raw *entropy*, a
     *              full-width uint256 — not over a small weight sum — so the bias is
     *              ~2^-224 and irrelevant. The forbidden "modulo sampling" is using
     *              `rand % numOptions` as the *selection*; we never do that.)
     * @return index The selected option index: the smallest `i` with `cdf[i] > r`.
     *
     * @dev    The returned bucket always has positive width. Since `r < total` and
     *         we return the first `i` with `cdf[i] > r >= cdf[i-1]`, that bucket's
     *         width `cdf[i]-cdf[i-1]` is > 0, i.e. the option is rollable. Zero-width
     *         (non-rollable) buckets are skipped for free.
     */
    function sampleBucket(uint256[] memory cdf, uint256 rand)
        internal
        pure
        returns (uint256 index)
    {
        uint256 n = cdf.length;
        require(n != 0, "SamplingLib: empty cdf");
        uint256 total = cdf[n - 1];
        require(total != 0, "SamplingLib: zero total weight");

        uint256 r = rand % total; // uniform in [0, total)

        // Binary search for the smallest index with cdf[index] > r.
        uint256 lo = 0;
        uint256 hi = n - 1; // cdf[n-1] == total > r, so a valid answer always exists in [lo, hi]
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (cdf[mid] > r) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        index = lo;
    }
}
