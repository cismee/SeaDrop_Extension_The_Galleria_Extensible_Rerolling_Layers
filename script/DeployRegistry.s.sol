// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { TraitRegistry } from "../src/TraitRegistry.sol";
import { ComboLib } from "../src/ComboLib.sol";

/**
 * @title  DeployRegistry
 * @notice Deploys the TraitRegistry and populates it from the on-disk art library
 *         using a GAS-BOUNDED, batched SSTORE2 path: each layer's options are added
 *         in chunks of `CHUNK`, one broadcast tx per chunk, so a large library
 *         never hits the block gas limit in a single tx.
 *
 *         ART SOURCE (this is the answer to "where do the PNGs come from"):
 *           art/manifest.json      — per-layer { attributes[], weights[] }
 *           art/<layer>/<NNN>.png  — one PNG per option, 1-based zero-padded (001..)
 *         The PNG bytes are read with vm.readFileBinary at deploy time and written
 *         to SSTORE2 blobs. Regenerate the dummy set with:
 *           python3 art/generate_dummy_art.py
 *         For production, replace the PNGs + manifest with the real collection and
 *         VALIDATE the weights with analysis/neff first (combined N_eff should stay
 *         well above the 2,618 supply — target >= ~30x).
 *
 *         OWNERSHIP. Seeding the art and calling finalizeSetup() are owner-only, so
 *         the registry is constructed owned by the DEPLOYER and those steps run in the
 *         same broadcast. Ownership is then (optionally) handed to a timelock/multisig
 *         AFTER all setup completes. Set TIMELOCK for that handoff; without it the
 *         deployer keeps ownership and can transfer it later. This mirrors
 *         DeployCollection's ownership model exactly.
 *
 *         env:
 *           TIMELOCK        (address) — optional; if set, ownership is transferred to
 *                                       it after seeding (Solady single-step, immediate).
 *           PRIVATE_KEY     (uint)    — deployer key for broadcasting.
 *           ART_DIR         (string)  — optional; defaults to "art".
 *           CHUNK           (uint)    — optional; max options per tx (default 8).
 *           MAX_BATCH_BYTES (uint)    — optional; max raw PNG bytes per tx (default
 *                                       24_000). LOWER THIS if a deploy tx is rejected
 *                                       with "exceeds max transaction gas limit".
 */
contract DeployRegistry is Script {
    // Per-tx batch limits, both env-overridable. A batch flushes when EITHER is hit:
    //   CHUNK           — max options per tx (a hard count cap).
    //   MAX_BATCH_BYTES — max cumulative raw PNG bytes per tx. This is the real gas
    //                     driver: SSTORE2 costs ~200 gas/byte of code deposit, so big
    //                     art (e.g. 5 KB paintings) blows the block/tx gas limit long
    //                     before CHUNK does. Byte-budgeting keeps every tx safe
    //                     regardless of how large individual PNGs are.
    // Defaults are conservative; lower MAX_BATCH_BYTES if a chain/RPC rejects a tx with
    // "exceeds max transaction gas limit".
    uint256 internal chunk;          // set from env in run()
    uint256 internal maxBatchBytes;  // set from env in run()

    string internal artDir;
    string internal manifest;

    function run() external returns (TraitRegistry registry) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        artDir = vm.envOr("ART_DIR", string("art"));
        // Reading the art manifest from disk is the entire purpose of this script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        manifest = vm.readFile(string.concat(artDir, "/manifest.json"));

        // Batch limits (env-overridable). 24_000 bytes/tx keeps each SSTORE2 batch
        // well under typical per-tx gas caps even for 5 KB paintings (~4–5 per tx).
        chunk = vm.envOr("CHUNK", uint256(8));
        maxBatchBytes = vm.envOr("MAX_BATCH_BYTES", uint256(24_000));

        // Construct owned by the DEPLOYER so the owner-only seeding below runs. The
        // (optional) handoff to a timelock/multisig happens AFTER setup completes.
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        registry = new TraitRegistry(deployer);
        console2.log("TraitRegistry:", address(registry));

        _seedLayer(registry, ComboLib.LAYER_PAINTING, "painting");
        _seedLayer(registry, ComboLib.LAYER_LABEL, "label");
        _seedLayer(registry, ComboLib.LAYER_BACKGROUND, "background");
        _seedLayer(registry, ComboLib.LAYER_FRAME, "frame");

        // Lock the fixed label layer; painting/frame/background remain growable.
        registry.finalizeSetup();

        // Optional: hand ownership to the timelock/multisig, AFTER all owner-only
        // setup above has run as the deployer. Solady Ownable transferOwnership is
        // single-step and immediate — no accept() needed on the registry.
        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock != address(0)) {
            registry.transferOwnership(timelock);
            console2.log("  ownership transferred to:", timelock);
        }

        vm.stopBroadcast();
    }

    /// @dev Load one layer from art/<dir>/ + manifest, adding options in gas-bounded
    ///      batches (one tx per batch). Each batch flushes when it reaches `chunk`
    ///      options OR would exceed `maxBatchBytes` of raw PNG — whichever comes first —
    ///      so large art can't push a single tx over the gas limit. A single option
    ///      larger than the byte budget still goes out alone (bounded by SSTORE2's
    ///      ~24 KB ceiling).
    function _seedLayer(TraitRegistry registry, uint8 layer, string memory dir) internal {
        string[] memory attrs = vm.parseJsonStringArray(manifest, string.concat(".", dir, ".attributes"));
        uint256[] memory weights = vm.parseJsonUintArray(manifest, string.concat(".", dir, ".weights"));
        require(attrs.length == weights.length, "manifest attributes/weights mismatch");
        uint256 count = attrs.length;

        // Read every PNG for the layer up front so batch sizing can see byte lengths.
        bytes[] memory allPngs = new bytes[](count);
        for (uint256 i = 0; i < count; ) {
            // Art files are 1-based, zero-padded to 3 digits: option index 0 -> 001.png.
            allPngs[i] = vm.readFileBinary(
                string.concat(artDir, "/", dir, "/", _pad3(i + 1), ".png")
            );
            unchecked {
                ++i;
            }
        }

        uint256 start = 0;
        while (start < count) {
            // Grow the batch [start, start+n) up to the count or byte cap.
            uint256 n = 0;
            uint256 bytesAcc = 0;
            while (start + n < count && n < chunk) {
                uint256 sz = allPngs[start + n].length;
                // Always include at least one option; then stop before exceeding the cap.
                if (n > 0 && bytesAcc + sz > maxBatchBytes) break;
                bytesAcc += sz;
                unchecked {
                    ++n;
                }
            }

            bytes[] memory pngs = new bytes[](n);
            string[] memory vals = new string[](n);
            uint32[] memory wts = new uint32[](n);
            bool[] memory rollables = new bool[](n);
            for (uint256 i = 0; i < n; ) {
                uint256 idx = start + i;
                pngs[i] = allPngs[idx];
                vals[i] = attrs[idx];
                wts[i] = uint32(weights[idx]);
                rollables[i] = true;
                unchecked {
                    ++i;
                }
            }

            registry.addOptionsBatch(layer, pngs, vals, wts, rollables);
            console2.log("  batch: layer", layer, n);
            start += n;
        }
        console2.log("  seeded layer", layer, count);
    }

    /// @dev Zero-pad to 3 digits (1 -> "001", 33 -> "033"), matching the art files.
    function _pad3(uint256 n) internal pure returns (string memory) {
        string memory s = vm.toString(n);
        if (n < 10) return string.concat("00", s);
        if (n < 100) return string.concat("0", s);
        return s;
    }
}
