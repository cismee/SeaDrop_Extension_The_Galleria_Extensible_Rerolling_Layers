// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Ownable } from "solady/auth/Ownable.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { ComboLib } from "./ComboLib.sol";
import { SamplingLib } from "./SamplingLib.sol";

/**
 * @title  TraitRegistry
 * @notice The shared, static art + weight library for The Galleria.
 *
 *         Every one of the 2,618 tokens dereferences THIS registry — per-token
 *         storage is only a packed combo, never image data. One SSTORE2 blob is
 *         deployed per trait *option* (each painting, each label, each background,
 *         each frame) and shared across all tokens. DMG 2-bit PNGs are tiny, well
 *         under the SSTORE2 / EIP-170 ceiling, so no option is ever split across
 *         pointers.
 *
 *         Owner is assumed to be a timelock/multisig. All mutators are owner-only
 *         and NEVER openable to approved operators — they change trait/weight
 *         config for the whole collection.
 *
 *         Two independent flags per option (the "split two flags" rule):
 *           - exists   : permanent once set. The renderer must ALWAYS be able to
 *                        resolve art for any option any token holds, so a blob /
 *                        registry entry is NEVER deleted, even if retired.
 *           - rollable : toggleable. Governs whether sampling may draw the option.
 *                        Lets art be pre-staged (exists=true, rollable=false) for a
 *                        timed reveal, and lets a trait be retired from circulation
 *                        without breaking tokens that still hold it.
 */
contract TraitRegistry is Ownable {
    using SSTORE2 for address;

    /* ------------------------------------------------------------------ */
    /*                              Errors                                 */
    /* ------------------------------------------------------------------ */

    error BadLayer();
    error BadOption();
    error LayerNotGrowable();
    error SetupFinalized();
    error WeightsFrozen();
    error LengthMismatch();
    error BadRenderOrder();
    error BadCanvas();

    /* ------------------------------------------------------------------ */
    /*                              Events                                 */
    /* ------------------------------------------------------------------ */

    event OptionAdded(uint8 indexed layer, uint256 indexed index, address pointer, string attributes, uint32 weight, bool rollable);
    event WeightSet(uint8 indexed layer, uint256 indexed index, uint32 weight);
    event RollableSet(uint8 indexed layer, uint256 indexed index, bool rollable);
    event WeightsFrozenEvent();
    event SetupFinalizedEvent();
    event RenderOrderSet(uint8[] order);
    event CanvasSet(uint16 width, uint16 height);
    event DescriptionSet(string description);

    /* ------------------------------------------------------------------ */
    /*                              Storage                                */
    /* ------------------------------------------------------------------ */

    /// @dev One option's on-chain record. Packs into a single storage slot:
    ///      address(20) + bool(1) + bool(1) + uint32(4) = 26 bytes.
    struct Option {
        address pointer; // SSTORE2 blob holding this option's raw PNG bytes
        bool exists; // permanent once true — never cleared
        bool rollable; // toggleable — governs sampling eligibility
        uint32 weight; // raw sampling weight (effective weight is 0 when !rollable)
    }

    /// @dev options[layer][index]. Registry:
    ///      mapping(layer => mapping(optionIndex => pointer/flags/weight)).
    mapping(uint8 => mapping(uint256 => Option)) internal _options;

    /// @dev Per-option metadata as a JSON attributes fragment: one or more
    ///      `{"trait_type":...,"value":...}` objects joined by commas, WITHOUT the
    ///      surrounding `[ ]` and WITHOUT a trailing comma. The Renderer concatenates
    ///      the four layers' fragments into the token's `attributes` array, so an
    ///      option can contribute any number of traits (e.g. a painting carries
    ///      Demake + Master + Year). Owner-supplied and MUST be valid JSON with any
    ///      special characters pre-escaped — the owner is a trusted timelock/multisig
    ///      and this fragment is emitted verbatim (not escaped) at render time.
    mapping(uint8 => mapping(uint256 => string)) internal _optionAttributes;

    /// @dev Append-only option count per layer. Indices are [0, count) and are
    ///      NEVER renumbered, reused, or deleted.
    mapping(uint8 => uint256) internal _optionCount;

    /// @dev Cached cumulative effective-weight array per layer for CDF draws.
    ///      Rebuilt whenever a weight/rollable/option changes for that layer.
    mapping(uint8 => uint256[]) internal _cdf;

    /// @dev Which layers may grow after setup is finalized. painting/frame/
    ///      background are growable; label is fixed (4-layer independent model).
    mapping(uint8 => bool) internal _growable;

    /// @dev trait_type name per layer, e.g. "Painting".
    mapping(uint8 => string) internal _layerName;

    /// @dev Collection-wide `description` shown in every token's metadata JSON.
    ///      Owner-settable; the Renderer reads it live, so one update changes all
    ///      2,618 tokens at once. JSON-escaped at render time.
    string internal _description;

    /// @dev Render (z) order, bottom→top, as an EXPLICIT MUTABLE list decoupled
    ///      from bit position, so z-order can be corrected without touching packing.
    uint8[] internal _renderOrder;

    /// @dev Pixel canvas for the SVG viewBox.
    uint16 public canvasWidth;
    uint16 public canvasHeight;

    /// @dev One-way: once true, weights and rollable toggles are immutable.
    bool public weightsFrozen;

    /// @dev One-way: once true, only growable layers may add options.
    bool public setupFinalized;

    /* ------------------------------------------------------------------ */
    /*                            Constructor                             */
    /* ------------------------------------------------------------------ */

    /**
     * @param owner_ The timelock/multisig that will govern the registry.
     */
    constructor(address owner_) {
        _initializeOwner(owner_);

        // Fixed forever: exactly four layers with these bit positions and names.
        _layerName[ComboLib.LAYER_PAINTING] = "Painting";
        _layerName[ComboLib.LAYER_LABEL] = "Label";
        _layerName[ComboLib.LAYER_BACKGROUND] = "Background";
        _layerName[ComboLib.LAYER_FRAME] = "Frame";

        // Growable layers (append options post-deploy): painting, frame, background.
        // label is fixed — see the label-coupling decision (independent decorative).
        _growable[ComboLib.LAYER_PAINTING] = true;
        _growable[ComboLib.LAYER_BACKGROUND] = true;
        _growable[ComboLib.LAYER_FRAME] = true;
        _growable[ComboLib.LAYER_LABEL] = false;

        // Default render order bottom→top: background, painting, frame, label.
        _renderOrder = [
            ComboLib.LAYER_BACKGROUND,
            ComboLib.LAYER_PAINTING,
            ComboLib.LAYER_FRAME,
            ComboLib.LAYER_LABEL
        ];

        // Art canvas is 140x160 px (width x height). Adjustable via setCanvas.
        canvasWidth = 140;
        canvasHeight = 160;

        // Default collection description, shown in EVERY token's metadata JSON
        // (owner-settable later via setDescription). Stored as plain text with REAL
        // newlines; the Renderer runs it through LibString.escapeJSON, which turns
        // them into `\n` and leaves `/` untouched, so the markdown links survive
        // intact. Marketplaces render the markdown.
        // The underscores in the @_ab83_ LINK TEXT are backslash-escaped so markdown
        // renders them literally instead of italicising "ab83". That backslash survives
        // the JSON layer: escapeJSON emits it as `\\`, the parser collapses it back to
        // one `\`, and the renderer reads `\_` as a literal underscore. The underscores
        // inside the URL are left alone — markdown does not emphasise link destinations,
        // and escaping there would break the link.
        _description = "[The Galleria](https://galleria.theflorentines.xyz) is a fully onchain dynamic collection of 2,618 NFTs on mainnet created by [Cartyisme](https://x.com/cartyisme). A follow-up to [The Florentines](https://theflorentines.xyz), every transfer regenerates the artwork.\n\nHandcrafted 2-bit demakes of Renaissance classics, it's art history canon delivered with handheld nostalgia.\n\nContracts inspired by [@\\_ab83\\_](https://x.com/_ab83_)'s [Heraldia](https://opensea.io/collection/heraldia).";
    }

    /* ------------------------------------------------------------------ */
    /*                          Admin: options                            */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Append one option to a layer. Pure append — never a repack.
     * @dev    Deploys the PNG as an SSTORE2 blob, registers it at the NEXT index
     *         for that layer, records its trait value string and weight in the
     *         SAME operation (art and attributes stay in sync), and rebuilds the
     *         layer CDF. Indices are append-only; existing packed values cannot
     *         move, so a new option can never alias an existing combo — the space
     *         only grows and occupancy only drops.
     *
     *         Allowed for any layer during setup; after `finalizeSetup()`, only
     *         growable layers (painting/frame/background) may still append.
     *
     * @return index The index the option was registered at.
     */
    function addOption(
        uint8 layer,
        bytes calldata pngData,
        string calldata attributes,
        uint32 weight,
        bool rollable
    ) external onlyOwner returns (uint256 index) {
        return _addOption(layer, pngData, attributes, weight, rollable);
    }

    /**
     * @notice Batched append — several options for one layer in a single tx.
     * @dev    The gas-bounded setup path: the deploy script chunks a layer's
     *         options into as many calls as needed to stay under the block gas
     *         limit. Each element becomes its own SSTORE2 pointer.
     */
    function addOptionsBatch(
        uint8 layer,
        bytes[] calldata pngData,
        string[] calldata attributesArr,
        uint32[] calldata weights,
        bool[] calldata rollables
    ) external onlyOwner returns (uint256 firstIndex, uint256 count) {
        uint256 n = pngData.length;
        if (n != attributesArr.length || n != weights.length || n != rollables.length) {
            revert LengthMismatch();
        }
        firstIndex = _optionCount[layer];
        for (uint256 i = 0; i < n; ) {
            _addOptionNoCdf(layer, pngData[i], attributesArr[i], weights[i], rollables[i]);
            unchecked {
                ++i;
            }
        }
        _rebuildCdf(layer); // rebuild once for the whole batch
        count = n;
    }

    function _addOption(
        uint8 layer,
        bytes calldata pngData,
        string calldata attributes,
        uint32 weight,
        bool rollable
    ) internal returns (uint256 index) {
        index = _addOptionNoCdf(layer, pngData, attributes, weight, rollable);
        _rebuildCdf(layer);
    }

    function _addOptionNoCdf(
        uint8 layer,
        bytes calldata pngData,
        string calldata attributes,
        uint32 weight,
        bool rollable
    ) internal returns (uint256 index) {
        if (layer >= ComboLib.NUM_LAYERS) revert BadLayer();
        // Append gate: any layer during setup; only growable layers after.
        if (setupFinalized && !_growable[layer]) revert LayerNotGrowable();

        index = _optionCount[layer];
        if (index >= ComboLib.MAX_OPTIONS_PER_LAYER) revert BadOption(); // 8-bit field is full

        address pointer = SSTORE2.write(pngData);
        _options[layer][index] = Option({
            pointer: pointer,
            exists: true, // permanent once set
            rollable: rollable,
            weight: weight
        });
        _optionAttributes[layer][index] = attributes;
        unchecked {
            _optionCount[layer] = index + 1;
        }

        emit OptionAdded(layer, index, pointer, attributes, weight, rollable);
    }

    /* ------------------------------------------------------------------ */
    /*                       Admin: weights & flags                       */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Set an option's raw weight. Only affects FUTURE mints/rerolls;
     *         already-settled tokens are fixed.
     */
    function setWeight(uint8 layer, uint256 index, uint32 weight) external onlyOwner {
        _requireOption(layer, index);
        if (weightsFrozen) revert WeightsFrozen();
        _options[layer][index].weight = weight;
        _rebuildCdf(layer);
        emit WeightSet(layer, index, weight);
    }

    /**
     * @notice Batched weight retune for one layer.
     */
    function setWeightsBatch(
        uint8 layer,
        uint256[] calldata indices,
        uint32[] calldata weights
    ) external onlyOwner {
        if (weightsFrozen) revert WeightsFrozen();
        if (indices.length != weights.length) revert LengthMismatch();
        for (uint256 i = 0; i < indices.length; ) {
            _requireOption(layer, indices[i]);
            _options[layer][indices[i]].weight = weights[i];
            emit WeightSet(layer, indices[i], weights[i]);
            unchecked {
                ++i;
            }
        }
        _rebuildCdf(layer);
    }

    /* ------------------------------------------------------------------ */
    /*                   Admin: whole-layer weight setters                */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Replace EVERY weight in the painting layer (layer 0) in one call.
     * @param  weights One weight per option, POSITIONAL: `weights[i]` becomes the
     *                 weight of option index `i` (= art/painting/00(i+1).png).
     *                 Length MUST equal the layer's current option count.
     */
    function setPaintingWeights(uint32[] calldata weights) external onlyOwner {
        _setLayerWeights(ComboLib.LAYER_PAINTING, weights);
    }

    /// @notice Replace EVERY weight in the label layer (layer 1). See setPaintingWeights.
    /// @dev    `finalizeSetup()` locks ADDING options to this layer, never retuning the
    ///         weights of the options already in it — this stays callable.
    function setLabelWeights(uint32[] calldata weights) external onlyOwner {
        _setLayerWeights(ComboLib.LAYER_LABEL, weights);
    }

    /// @notice Replace EVERY weight in the background layer (layer 2). See setPaintingWeights.
    function setBackgroundWeights(uint32[] calldata weights) external onlyOwner {
        _setLayerWeights(ComboLib.LAYER_BACKGROUND, weights);
    }

    /// @notice Replace EVERY weight in the frame layer (layer 3). See setPaintingWeights.
    function setFrameWeights(uint32[] calldata weights) external onlyOwner {
        _setLayerWeights(ComboLib.LAYER_FRAME, weights);
    }

    /**
     * @dev Shared body of the four whole-layer setters.
     *
     *      Rejects with `LengthMismatch()` unless `weights.length` is EXACTLY the
     *      layer's option count — too short would silently leave a tail of options on
     *      their old weights, too long would silently drop the excess. Requiring an
     *      exact cover means the array you send is the distribution you get.
     *
     *      No per-index `_requireOption` is needed: indices [0, count) all exist by
     *      construction, since options are append-only and `exists` is permanent.
     *
     *      Rebuilds the CDF ONCE for the whole layer. Effective weight is still
     *      `rollable ? weight : 0`, so writing a weight to a non-rollable option stores
     *      the value but keeps it a zero-width (undrawable) bucket until re-enabled.
     *
     *      Setting every weight in a layer to 0 leaves that layer unsampleable. That is
     *      allowed here (it mirrors `setRollable`), and Galleria degrades safely — a
     *      reroll keeps its old traits, a mint reverts — but minting stays broken until
     *      a positive weight is restored. On a layer with zero options this is a no-op.
     */
    function _setLayerWeights(uint8 layer, uint32[] calldata weights) internal {
        if (weightsFrozen) revert WeightsFrozen();
        uint256 count = _optionCount[layer];
        if (weights.length != count) revert LengthMismatch();
        for (uint256 i = 0; i < count; ) {
            _options[layer][i].weight = weights[i];
            emit WeightSet(layer, i, weights[i]);
            unchecked {
                ++i;
            }
        }
        _rebuildCdf(layer);
    }

    /**
     * @notice Toggle whether sampling may draw an option (the `rollable` flag).
     *         `exists` is untouched, so tokens holding it still render.
     */
    function setRollable(uint8 layer, uint256 index, bool rollable) external onlyOwner {
        _requireOption(layer, index);
        if (weightsFrozen) revert WeightsFrozen();
        _options[layer][index].rollable = rollable;
        _rebuildCdf(layer);
        emit RollableSet(layer, index, rollable);
    }

    /**
     * @notice One-way freeze of all weights and rollable toggles.
     */
    function freezeWeights() external onlyOwner {
        weightsFrozen = true;
        emit WeightsFrozenEvent();
    }

    /**
     * @notice One-way finalize of setup. After this, only growable layers
     *         (painting/frame/background) may add options; label is locked.
     */
    function finalizeSetup() external onlyOwner {
        setupFinalized = true;
        emit SetupFinalizedEvent();
    }

    /**
     * @notice Replace the render (z) order list. Must be a permutation of the
     *         four layer ids. Decoupled from packing — never affects uniqueness.
     */
    function setRenderOrder(uint8[] calldata order) external onlyOwner {
        if (order.length != ComboLib.NUM_LAYERS) revert BadRenderOrder();
        // Verify it is a permutation of {0,1,2,3}.
        bool[4] memory seen;
        for (uint256 i = 0; i < order.length; ) {
            uint8 l = order[i];
            if (l >= ComboLib.NUM_LAYERS || seen[l]) revert BadRenderOrder();
            seen[l] = true;
            unchecked {
                ++i;
            }
        }
        _renderOrder = order;
        emit RenderOrderSet(order);
    }

    /**
     * @notice Set the pixel canvas used for the SVG viewBox.
     */
    function setCanvas(uint16 width, uint16 height) external onlyOwner {
        if (width == 0 || height == 0) revert BadCanvas();
        canvasWidth = width;
        canvasHeight = height;
        emit CanvasSet(width, height);
    }

    /**
     * @notice Set the collection-wide metadata `description`. Applies to every
     *         token immediately (tokenURI reads it live). Provide plain text —
     *         it is JSON-escaped at render time.
     */
    function setDescription(string calldata description_) external onlyOwner {
        _description = description_;
        emit DescriptionSet(description_);
    }

    /* ------------------------------------------------------------------ */
    /*                           CDF machinery                            */
    /* ------------------------------------------------------------------ */

    /// @dev Recompute a layer's cumulative effective-weight array. Effective
    ///      weight is `rollable ? weight : 0`, so non-rollable options become
    ///      zero-width buckets that sampling can never land on.
    function _rebuildCdf(uint8 layer) internal {
        uint256 count = _optionCount[layer];
        uint256[] storage cdf = _cdf[layer];

        // Resize the stored array to `count`.
        while (cdf.length < count) {
            cdf.push(0);
        }
        while (cdf.length > count) {
            cdf.pop();
        }

        uint256 running = 0;
        for (uint256 i = 0; i < count; ) {
            Option storage o = _options[layer][i];
            if (o.rollable) {
                running += uint256(o.weight);
            }
            cdf[i] = running;
            unchecked {
                ++i;
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                          Views: sampling                           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Draw a rollable option index for `layer` from `rand` entropy.
     * @dev    Reads the cached CDF and binary-searches the bucket. Reverts if the
     *         layer has zero total rollable weight (an admin misconfiguration).
     */
    function sample(uint8 layer, uint256 rand) external view returns (uint8) {
        return uint8(SamplingLib.sampleBucket(_cdf[layer], rand));
    }

    /// @notice The cached CDF for a layer (cumulative effective weights).
    function cdfOf(uint8 layer) external view returns (uint256[] memory) {
        return _cdf[layer];
    }

    /// @notice Total rollable weight of a layer (last CDF entry, or 0 if empty).
    function totalWeight(uint8 layer) external view returns (uint256) {
        uint256[] storage cdf = _cdf[layer];
        uint256 n = cdf.length;
        return n == 0 ? 0 : cdf[n - 1];
    }

    /* ------------------------------------------------------------------ */
    /*                          Views: options                            */
    /* ------------------------------------------------------------------ */

    /// @notice SSTORE2 pointer for an option. Reverts if the option was never set.
    function pointerOf(uint8 layer, uint256 index) external view returns (address) {
        Option storage o = _options[layer][index];
        if (!o.exists) revert BadOption();
        return o.pointer;
    }

    /// @notice Raw PNG bytes for an option (EXTCODECOPY out of its SSTORE2 blob).
    function readOption(uint8 layer, uint256 index) external view returns (bytes memory) {
        Option storage o = _options[layer][index];
        if (!o.exists) revert BadOption();
        return SSTORE2.read(o.pointer);
    }

    function optionExists(uint8 layer, uint256 index) external view returns (bool) {
        return _options[layer][index].exists;
    }

    function isRollable(uint8 layer, uint256 index) external view returns (bool) {
        return _options[layer][index].rollable;
    }

    function weightOf(uint8 layer, uint256 index) external view returns (uint32) {
        return _options[layer][index].weight;
    }

    /* ------------------------------------------------------------------ */
    /*                   Views: whole-layer weight arrays                 */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Every RAW weight in the painting layer (layer 0), in option-index order.
     * @dev    The exact inverse of `setPaintingWeights`: feeding this array straight
     *         back in is a no-op, so read-modify-write round-trips cleanly.
     *
     *         These are RAW weights, NOT effective ones. A non-rollable option still
     *         reports its stored weight here even though sampling can never draw it —
     *         effective weight is `rollable ? weight : 0`. For what sampling actually
     *         sees, read `cdfOf(layer)` (cumulative effective weight; difference
     *         consecutive entries) or pair this with `isRollable`.
     */
    function paintingWeights() external view returns (uint32[] memory) {
        return _layerWeights(ComboLib.LAYER_PAINTING);
    }

    /// @notice Every RAW weight in the label layer (layer 1). See paintingWeights.
    function labelWeights() external view returns (uint32[] memory) {
        return _layerWeights(ComboLib.LAYER_LABEL);
    }

    /// @notice Every RAW weight in the background layer (layer 2). See paintingWeights.
    function backgroundWeights() external view returns (uint32[] memory) {
        return _layerWeights(ComboLib.LAYER_BACKGROUND);
    }

    /// @notice Every RAW weight in the frame layer (layer 3). See paintingWeights.
    function frameWeights() external view returns (uint32[] memory) {
        return _layerWeights(ComboLib.LAYER_FRAME);
    }

    /// @notice Every RAW weight for an arbitrary layer id, in option-index order.
    /// @dev    Generic form of the four named getters above; reverts `BadLayer()` for
    ///         an id outside [0, NUM_LAYERS).
    function weightsOf(uint8 layer) external view returns (uint32[] memory) {
        if (layer >= ComboLib.NUM_LAYERS) revert BadLayer();
        return _layerWeights(layer);
    }

    /// @dev Shared body: collect [0, optionCount) into a fresh array. Length always
    ///      equals `optionCountOf(layer)`, so it is exactly the length the matching
    ///      whole-layer setter demands. An empty layer returns an empty array.
    function _layerWeights(uint8 layer) internal view returns (uint32[] memory out) {
        uint256 count = _optionCount[layer];
        out = new uint32[](count);
        for (uint256 i = 0; i < count; ) {
            out[i] = _options[layer][i].weight;
            unchecked {
                ++i;
            }
        }
    }

    function optionCountOf(uint8 layer) external view returns (uint256) {
        return _optionCount[layer];
    }

    function optionAttributesOf(uint8 layer, uint256 index) external view returns (string memory) {
        return _optionAttributes[layer][index];
    }

    function layerNameOf(uint8 layer) external view returns (string memory) {
        return _layerName[layer];
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function isGrowable(uint8 layer) external view returns (bool) {
        return _growable[layer];
    }

    function renderOrder() external view returns (uint8[] memory) {
        return _renderOrder;
    }

    function canvas() external view returns (uint16, uint16) {
        return (canvasWidth, canvasHeight);
    }

    /* ------------------------------------------------------------------ */
    /*                             Internal                               */
    /* ------------------------------------------------------------------ */

    function _requireOption(uint8 layer, uint256 index) internal view {
        if (layer >= ComboLib.NUM_LAYERS) revert BadLayer();
        if (!_options[layer][index].exists) revert BadOption();
    }
}
