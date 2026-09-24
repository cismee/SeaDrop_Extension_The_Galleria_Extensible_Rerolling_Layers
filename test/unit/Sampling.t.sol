// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { SamplingLib } from "../../src/SamplingLib.sol";

/// @dev External wrapper so `vm.expectRevert` sees a revert one call-depth down.
contract SamplingHarness {
    function sampleBucket(uint256[] calldata cdf, uint256 rand) external pure returns (uint256) {
        return SamplingLib.sampleBucket(cdf, rand);
    }
}

/// @notice CDF bucket-draw correctness + a statistical distribution check.
contract SamplingTest is Test {
    SamplingHarness internal harness = new SamplingHarness();

    /// @dev Build a CDF from raw weights (cumulative).
    function _cdf(uint256[] memory w) internal pure returns (uint256[] memory cdf) {
        cdf = new uint256[](w.length);
        uint256 running;
        for (uint256 i = 0; i < w.length; ++i) {
            running += w[i];
            cdf[i] = running;
        }
    }

    function test_sampleBucket_boundaries() public pure {
        // weights [10, 20, 30] → cdf [10, 30, 60]
        uint256[] memory w = new uint256[](3);
        w[0] = 10;
        w[1] = 20;
        w[2] = 30;
        uint256[] memory cdf = _cdf(w);

        // r in [0,10) → 0 ; [10,30) → 1 ; [30,60) → 2
        assertEq(SamplingLib.sampleBucket(cdf, 0), 0);
        assertEq(SamplingLib.sampleBucket(cdf, 9), 0);
        assertEq(SamplingLib.sampleBucket(cdf, 10), 1);
        assertEq(SamplingLib.sampleBucket(cdf, 29), 1);
        assertEq(SamplingLib.sampleBucket(cdf, 30), 2);
        assertEq(SamplingLib.sampleBucket(cdf, 59), 2);
        // rand reduced modulo total (60) → 0 again
        assertEq(SamplingLib.sampleBucket(cdf, 60), 0);
    }

    function test_zeroWidth_buckets_never_selected() public pure {
        // Option 1 has zero effective weight (non-rollable) → cdf [10,10,40].
        uint256[] memory cdf = new uint256[](3);
        cdf[0] = 10;
        cdf[1] = 10; // zero-width bucket
        cdf[2] = 40;

        // Sweep the whole domain; index 1 must never come up.
        for (uint256 r = 0; r < 40; ++r) {
            uint256 idx = SamplingLib.sampleBucket(cdf, r);
            assertTrue(idx != 1, "zero-width bucket selected");
        }
    }

    function test_reverts_on_zero_total() public {
        uint256[] memory cdf = new uint256[](2);
        cdf[0] = 0;
        cdf[1] = 0;
        vm.expectRevert(bytes("SamplingLib: zero total weight"));
        harness.sampleBucket(cdf, 3);
    }

    function testFuzz_result_in_positive_bucket(uint256 rand) public pure {
        uint256[] memory cdf = new uint256[](4);
        cdf[0] = 5;
        cdf[1] = 5; // zero width
        cdf[2] = 15;
        cdf[3] = 15; // zero width
        uint256 idx = SamplingLib.sampleBucket(cdf, rand);
        // Selected bucket must have positive width.
        uint256 lower = idx == 0 ? 0 : cdf[idx - 1];
        assertGt(cdf[idx] - lower, 0);
    }

    /// @dev Weighted draw hits configured buckets at roughly the configured
    ///      frequency over many draws (statistical test). weights 1:3:6.
    function test_distribution_matches_weights() public pure {
        uint256[] memory w = new uint256[](3);
        w[0] = 100;
        w[1] = 300;
        w[2] = 600;
        uint256[] memory cdf = _cdf(w); // total 1000

        uint256 N = 20_000;
        uint256[] memory hits = new uint256[](3);
        for (uint256 i = 0; i < N; ++i) {
            uint256 rand = uint256(keccak256(abi.encode(i, uint256(0xABCD))));
            hits[SamplingLib.sampleBucket(cdf, rand)]++;
        }

        // Expected proportions 10% / 30% / 60%. Allow ±3 percentage points.
        assertApproxEqAbs((hits[0] * 100) / N, 10, 3);
        assertApproxEqAbs((hits[1] * 100) / N, 30, 3);
        assertApproxEqAbs((hits[2] * 100) / N, 60, 3);
    }

    function test_seed_varies_by_tokenId_attempt_layer() public pure {
        uint256 base = 0xdead;
        uint256 a = SamplingLib.seed(base, 1, 0, 0);
        assertTrue(a != SamplingLib.seed(base, 2, 0, 0), "tokenId must vary seed");
        assertTrue(a != SamplingLib.seed(base, 1, 1, 0), "attempt must vary seed");
        assertTrue(a != SamplingLib.seed(base, 1, 0, 1), "layer must vary seed");
    }
}
