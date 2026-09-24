// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { TraitRegistry } from "../src/TraitRegistry.sol";
import { ComboLib } from "../src/ComboLib.sol";

/**
 * @title  AddArtworks
 * @notice Deploy NEW artworks to a live collection (post-launch). Reads a layer's
 *         entries from art/manifest.json, compares against what is already on-chain,
 *         and appends only the NEW options — from disk, in gas-bounded chunks (one
 *         tx per chunk), exactly like the initial DeployRegistry batch path.
 *
 *         This makes art/manifest.json the single source of truth for both the
 *         initial deploy and every later addition:
 *           1. drop the new PNG(s) at art/<layer>/<NNN>.png (next 1-based indices),
 *           2. append their attributes+weight to art/manifest.json,
 *           3. run this script.
 *
 *         Only growable layers accept appends (painting=0, background=2, frame=3);
 *         label=1 is fixed and the registry will revert for it after finalizeSetup.
 *
 *         Newly added options only enter circulation via the reroll path (mint is
 *         closed), so they seep in slowly and are emergently scarce; WEIGHT sets the
 *         rate. Use ROLLABLE=false to pre-stage art now and reveal later with
 *         registry.setRollable(layer, index, true).
 *
 *         env:
 *           REGISTRY (address) — deployed TraitRegistry (caller must be owner).
 *           LAYER    (uint)    — 0 painting, 2 background, 3 frame.
 *           ART_DIR  (string)  — optional; defaults to "art".
 *           ROLLABLE (bool)    — optional; defaults to true.
 *           PRIVATE_KEY (uint) — owner key.
 *           CHUNK    (uint)    — optional; max options per tx (default 8).
 *           MAX_BATCH_BYTES (uint) — optional; max raw PNG bytes per tx (default
 *                              24_000). LOWER THIS if a tx is rejected with
 *                              "exceeds max transaction gas limit".
 */
contract AddArtworks is Script {
    // Per-tx batch limits, both env-overridable. A batch flushes when EITHER is hit:
    //   CHUNK           — max options per tx (a hard count cap).
    //   MAX_BATCH_BYTES — max cumulative raw PNG bytes per tx (the real gas driver;
    //                     SSTORE2 costs ~200 gas/byte). Byte-budgeting keeps every tx
    //                     under the gas limit regardless of how large individual PNGs
    //                     are. Lower MAX_BATCH_BYTES if a tx is rejected with
    //                     "exceeds max transaction gas limit".
    uint256 internal chunk;          // set from env in run()
    uint256 internal maxBatchBytes;  // set from env in run()

    function run() external {
        TraitRegistry registry = TraitRegistry(vm.envAddress("REGISTRY"));
        uint8 layer = uint8(vm.envUint("LAYER"));
        string memory dir = _layerDir(layer);
        string memory artDir = vm.envOr("ART_DIR", string("art"));

        chunk = vm.envOr("CHUNK", uint256(8));
        maxBatchBytes = vm.envOr("MAX_BATCH_BYTES", uint256(24_000));

        (string[] memory values, uint256[] memory weights) = _readManifest(artDir, dir);
        uint256 have = registry.optionCountOf(layer);
        require(values.length >= have, "manifest has fewer options than on-chain (append-only)");

        if (values.length == have) {
            console2.log("Nothing to add: on-chain count already matches manifest", have);
            return;
        }
        console2.log("Layer", layer);
        console2.log("  on-chain:", have);
        console2.log("  manifest:", values.length);

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        _appendRange(registry, layer, artDir, dir, values, weights, have);
        vm.stopBroadcast();

        console2.log("Done. New on-chain count:", registry.optionCountOf(layer));
    }

    function _readManifest(string memory artDir, string memory dir)
        internal
        view
        returns (string[] memory values, uint256[] memory weights)
    {
        // Reading the art manifest from disk is the entire purpose of this script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory manifest = vm.readFile(string.concat(artDir, "/manifest.json"));
        values = vm.parseJsonStringArray(manifest, string.concat(".", dir, ".attributes"));
        weights = vm.parseJsonUintArray(manifest, string.concat(".", dir, ".weights"));
        require(values.length == weights.length, "manifest attributes/weights mismatch");
    }

    /// @dev Append manifest entries [from, values.length) in gas-bounded batches. Each
    ///      batch flushes when it reaches `chunk` options OR would exceed `maxBatchBytes`
    ///      of raw PNG — whichever comes first — so large art can't push a single tx
    ///      over the gas limit. A single option larger than the byte budget still goes
    ///      out alone (bounded by SSTORE2's ~24 KB ceiling).
    function _appendRange(
        TraitRegistry registry,
        uint8 layer,
        string memory artDir,
        string memory dir,
        string[] memory values,
        uint256[] memory weights,
        uint256 from
    ) internal {
        bool rollable = vm.envOr("ROLLABLE", true);
        uint256 want = values.length;

        // Read every NEW PNG up front so batch sizing can see byte lengths.
        uint256 newCount = want - from;
        bytes[] memory allPngs = new bytes[](newCount);
        for (uint256 i = 0; i < newCount; ) {
            // Art files are 1-based, zero-padded to 3 digits: option index 0 -> 001.png.
            allPngs[i] = vm.readFileBinary(
                string.concat(artDir, "/", dir, "/", _pad3(from + i + 1), ".png")
            );
            unchecked {
                ++i;
            }
        }

        uint256 start = 0; // offset within [from, want)
        while (start < newCount) {
            uint256 n = _batchSize(allPngs, start, newCount);
            _appendBatch(registry, layer, allPngs, values, weights, from, start, n, rollable);
            start += n;
            console2.log("  appended through index", from + start - 1);
        }
    }

    /// @dev How many options (from `start`) fit in one tx: up to `chunk` count and
    ///      `maxBatchBytes` of raw PNG, but always at least one.
    function _batchSize(bytes[] memory allPngs, uint256 start, uint256 newCount)
        internal
        view
        returns (uint256 n)
    {
        uint256 bytesAcc = 0;
        while (start + n < newCount && n < chunk) {
            uint256 sz = allPngs[start + n].length;
            if (n > 0 && bytesAcc + sz > maxBatchBytes) break; // always include ≥1
            bytesAcc += sz;
            unchecked {
                ++n;
            }
        }
    }

    /// @dev Build one batch [from+start, from+start+n) and add it in a single tx.
    function _appendBatch(
        TraitRegistry registry,
        uint8 layer,
        bytes[] memory allPngs,
        string[] memory values,
        uint256[] memory weights,
        uint256 from,
        uint256 start,
        uint256 n,
        bool rollable
    ) internal {
        bytes[] memory pngs = new bytes[](n);
        string[] memory vals = new string[](n);
        uint32[] memory wts = new uint32[](n);
        bool[] memory rolls = new bool[](n);
        for (uint256 i = 0; i < n; ) {
            uint256 idx = from + start + i; // absolute option index
            pngs[i] = allPngs[start + i];
            vals[i] = values[idx];
            wts[i] = uint32(weights[idx]);
            rolls[i] = rollable;
            unchecked {
                ++i;
            }
        }
        registry.addOptionsBatch(layer, pngs, vals, wts, rolls);
    }

    /// @dev Zero-pad to 3 digits (1 -> "001", 33 -> "033"), matching the art files.
    function _pad3(uint256 n) internal pure returns (string memory) {
        string memory s = vm.toString(n);
        if (n < 10) return string.concat("00", s);
        if (n < 100) return string.concat("0", s);
        return s;
    }

    function _layerDir(uint8 layer) internal pure returns (string memory) {
        if (layer == ComboLib.LAYER_PAINTING) return "painting";
        if (layer == ComboLib.LAYER_LABEL) return "label";
        if (layer == ComboLib.LAYER_BACKGROUND) return "background";
        if (layer == ComboLib.LAYER_FRAME) return "frame";
        revert("bad layer");
    }
}
