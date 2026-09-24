// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { TraitRegistry } from "../src/TraitRegistry.sol";

/**
 * @title  AddOption
 * @notice Append ONE option (a painting, frame, OR background — the growable
 *         layers) to a live registry, post-deploy. A pure append: it deploys the
 *         new SSTORE2 blob, registers it at the next index for that layer, records
 *         its attributes fragment + weight in the same call, and rebuilds that
 *         layer's CDF. Existing packed values never move.
 *
 *         With mint closed, a newly added option can only enter circulation via
 *         the reroll path, so it propagates slowly and is emergently scarce; its
 *         weight sets how fast it seeps in.
 *
 *         env:
 *           REGISTRY  (address) — deployed TraitRegistry (caller must be owner).
 *           LAYER     (uint)    — 0 painting, 2 background, 3 frame (NOT 1 label).
 *           PNG_PATH  (string)  — path to the option's PNG file.
 *           ATTRIBUTES (string) — the option's attributes JSON fragment (one or more
 *                                 {"trait_type":..,"value":..} objects, no brackets,
 *                                 no trailing comma), e.g.
 *                                 {"trait_type":"Demake","value":"Starry Night"}.
 *           WEIGHT    (uint)    — sampling weight.
 *           ROLLABLE  (bool)    — whether it is immediately drawable.
 *           PRIVATE_KEY (uint)  — owner key.
 */
contract AddOption is Script {
    function run() external returns (uint256 index) {
        address registry = vm.envAddress("REGISTRY");
        uint8 layer = uint8(vm.envUint("LAYER"));
        bytes memory png = vm.readFileBinary(vm.envString("PNG_PATH"));
        string memory attributes = vm.envString("ATTRIBUTES");
        uint32 weight = uint32(vm.envUint("WEIGHT"));
        bool rollable = vm.envOr("ROLLABLE", true);
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        index = TraitRegistry(registry).addOption(layer, png, attributes, weight, rollable);

        vm.stopBroadcast();

        console2.log("Appended option to layer", layer);
        console2.log("  index:", index);
        console2.log("  attributes:", attributes);
    }
}
