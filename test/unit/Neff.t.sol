// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { Neff } from "../../analysis/neff.sol";

/// @notice Cross-check that the N_eff/occupancy math (analysis/neff.*) matches the
///         weighted sampling the registry will actually perform.
contract NeffTest is Test {
    uint256 constant SUPPLY = 2618;

    function _uniform(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) a[i] = 100;
    }

    function test_uniform_neff_equals_raw_product() public pure {
        // Shipped config (mirrors art/manifest.json): 33*6*27*27 = 144,342.
        uint256 neffWad = Neff.combinedNeffWad(
            _uniform(33),
            _uniform(6),
            _uniform(27),
            _uniform(27)
        );
        uint256 neff = neffWad / Neff.WAD;
        assertEq(neff, 33 * 6 * 27 * 27, "uniform N_eff == raw product");

        // >= 30x supply target.
        assertGe(neff, 30 * SUPPLY);

        // occupancy ~ 1.8% at the 2,618 supply (2618 / 144,342).
        uint256 occWad = Neff.occupancyWad(neffWad, SUPPLY);
        uint256 occBps = (occWad * 10000) / Neff.WAD; // basis points
        assertApproxEqAbs(occBps, 181, 5); // 1.81%
    }

    function test_skew_shrinks_neff() public pure {
        // A skewed layer (one dominant option) has far lower N_eff than uniform.
        // Sized to a shipped layer count (background/frame = 27).
        uint256[] memory skewed = new uint256[](27);
        skewed[0] = 10000; // dominant
        for (uint256 i = 1; i < 27; ++i) skewed[i] = 100;

        uint256 uniformLayer = Neff.layerNeffWad(_uniform(27)) / Neff.WAD; // == 27
        uint256 skewedLayer = Neff.layerNeffWad(skewed) / Neff.WAD;
        assertEq(uniformLayer, 27);
        assertLt(skewedLayer, uniformLayer, "skew must reduce effective options");
    }
}
