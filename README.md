# The Galleria

A fully on-chain, generative **1-of-1** NFT collection, built as an **OpenSea
SeaDrop extension** (extends the canonical [`ERC721SeaDrop`](https://github.com/ProjectOpenSea/seadrop)).
Art is **never stored or composited on-chain**: each token stores only a packed
`uint256` combo of four trait indices, and the image is assembled lazily at read
time from a shared, static library of PNG blobs. A token's traits **reroll when it
is transferred outside a blessed conduit**. Every combo is enforced 1-of-1.

- **Supply:** 2,618
- **Combo space:** ~144k (four 8-bit layers; shipped config = 144,342 — 33·6·27·27)
- **Mint:** via SeaDrop (`mintSeaDrop`) — standard allowlist / public / signed drop
- **No frontend.** Contracts, scripts, tests, and an off-chain N_eff calculator only.

## The four layers

`painting`, `label`, `background`, `frame` — fixed forever, exactly four. Render
(z) order bottom→top is `background, painting, frame, label`, kept as an **explicit
mutable list** in the registry, decoupled from bit position so it can be corrected
without touching packing.

**Label-coupling decision (resolved before build): `label` is INDEPENDENT
decorative text.** It is a fixed (non-growable) but independently-sampled fourth
layer. Uniqueness keys on **all four** layers and `N_eff` is a four-layer product.

## How uniqueness is enforced

Registry: `comboToToken[packedCombo] = tokenId + 1` (`0` = free; storing `+1` lets
combo value `0` be a legal key and gives a free reverse-lookup / existence check).

**Property-tested invariant:** for every live token, `comboToToken[combo[t]] == t+1`,
and live-token → combo is injective. Enforced by five rules (each tagged inline in
`src/Galleria.sol`):

1. **Single writer** — `_writeCombo` is the only settle-path mutator of the registry.
2. **Lock-until-success** — on reroll the OLD combo stays claimed until a new winner
   exists; release-old happens only then (so a reroll can never re-land its own combo).
3. **Capmiss-is-noop** — after `N = 10` failed attempts a *reroll* keeps the old
   traits and does **not** revert (reverting would soulbind the token). A *mint*
   capmiss reverts (nothing is minted, nothing soulbound). P(capmiss) ≈ 4e-17.
4. **Canonical packing** — fixed 8-bit fields, all unused high bits zero, one
   encoding per combo (`src/ComboLib.sol`).
5. **Claim-as-you-go** — within a batched mint each combo is written before the next
   draw, so later draws see earlier ones.

## Reroll on transfer (`_beforeTokenTransfers`)

- `from == 0` (mint) → establish initial combo via the single writer.
- operator (`msg.sender`) is **preserving** → **preserve**, no reroll. **All Blur and
  Seaport sales preserve.** Preserving =
  - any conduit registered with Seaport's canonical `ConduitController` (`0x0000…Ad63`),
    recognised dynamically — covers OpenSea and every Seaport-conduit marketplace; **or**
  - a manually **blessed** router in the admin-editable set, seeded with: OpenSea's
    conduit `0x1E00…3c71`, **Seaport core** (1.5 / 1.6 — `msg.sender` for direct
    `conduitKey == 0` fills), and **Blur's ExecutionDelegate** (`msg.sender` for Blur
    trades/loans).
- owner calls **`safeSend(to, tokenId)`** → **preserve**. A self-service preserving
  transfer: the current owner (not an approved operator) moves a token — between their
  own wallets or as a gift — keeping the current artwork. Routes through
  `safeTransferFrom` (receiver check applies) with a one-shot guard the transfer hook
  consumes *before* any receiver callback, so a re-entrant recipient can't reuse it.
- anything else — a raw `transferFrom` or cold-wallet move (no marketplace operator)
  → **reroll**.
- `to == 0` (burn) → release combo (never orphan-locked).

**Excluded operators (force-reroll override).** An admin-editable `excludedConduit` set
takes precedence over BOTH the blessed set and dynamic Seaport-conduit recognition: a
move whose operator is excluded **rerolls**, even if it would otherwise be recognised as
preserving. It is seeded with **OpenSea's TransferHelper** (`0x0000…1A72`) because some
wallet "send" flows (e.g. MetaMask) route a plain transfer through it, which would
otherwise skip the reroll. Edit with `setExcludedConduit(operator, excluded)`. `safeSend`
is unaffected — the owner's one-shot always preserves.

**Metadata refresh (EIP-4906).** A successful reroll changes the token's traits, so
`_writeCombo` emits `BatchMetadataUpdate(tokenId, tokenId)` (the EIP-4906 event, inherited
from `ERC721ContractMetadata`; the contract reports interface `0x49064906`). Marketplaces
that honor 4906 — OpenSea included — refresh the cached image/attributes automatically,
so a rerolled token updates without a manual "refresh metadata". A **capmiss** reroll keeps
the old traits and deliberately emits **no** update (nothing changed). The owner-only
`emitBatchMetadataUpdate(from, to)` remains for bulk/manual refreshes.

> Seed addresses are verified against Etherscan (Ethereum mainnet); re-check them for
> any other target chain. Newer Seaport versions or a future Blur delegate are added
> with `setBlessedConduit` — no redeploy. A wrong/missing address only fails safe (that
> sale rerolls). The dynamic conduit check is a safe no-op (→ reroll) on any chain
> where the controller isn't deployed.

**Consequence (accepted):** preserving a move is no longer tied to a sale. Between
`safeSend` (a first-class owner action) and the permissionless marketplace operators,
a holder can always move a token without rerolling. A reroll therefore happens only on
a plain `transferFrom` (or a non-preserving operator) — it is effectively **opt-in**
for the holder. This fully supersedes the earlier "no escape hatch" stance.

## Repository layout

```
src/
  Galleria.sol        SeaDrop extension: uniqueness writer, transfer hook, tokenURI
  TraitRegistry.sol   SSTORE2 pointer registry + exists/rollable flags + weighted CDFs
  ComboLib.sol        canonical pack/unpack + uniqueness-key helpers
  SamplingLib.sol     per-layer CDF binary-search draw + isolated per-draw entropy seed
  Renderer.sol        tokenURI assembly: EXTCODECOPY -> base64 -> stacked SVG -> JSON
script/
  DeployRegistry.s.sol    batched SSTORE2 blob deploy across multiple txs (gas-bounded)
  DeployCollection.s.sol  deploy token + wire SeaDrop + optional public drop
  AddArtworks.s.sol       append every NEW manifest option for a layer (batched, idempotent)
  AddOption.s.sol         append a single painting/frame/background option post-deploy
test/
  unit/               packing, sampling, registry, tokenURI, transfer, reroll, burn, append, neff
  invariant/          StdInvariant handler + injectivity / consistency / canonical assertions
  helpers/            GalleriaTestBase, ForcedCollisionGalleria harness
analysis/
  neff.{py,js,sol}    off-chain N_eff / occupancy calculator for a weight config
art/
  manifest.json       per-layer { values[], weights[] } for every option
  <layer>/<i>.png     one 140x160 PNG per option (the art source DeployRegistry reads)
  generate_dummy_art.py   regenerates the dummy reference art + manifest
```

## Art source (where the PNGs come from on deploy)

`script/DeployRegistry.s.sol` reads the art from disk at deploy time:

- `art/manifest.json` — `{ "<layer>": { "values": [...], "weights": [...] }, ... }`
- `art/<layer>/<i>.png` — one PNG per option, indexed `0..count-1`

Each PNG is loaded with `vm.readFileBinary` and written to its own SSTORE2 blob;
the option count per layer is taken from the manifest arrays. `foundry.toml` grants
read access to `./art`. The committed set is **dummy reference art** (distinct
alpha-aware 140x160 layers so stacking is visible) generated by:

```bash
python3 art/generate_dummy_art.py
```

For production, drop in the real PNGs + manifest (same layout), validate the
weights with `analysis/neff.py`, then deploy. Options can also be appended one at a
time after deploy via `script/AddOption.s.sol` (which reads a single `PNG_PATH`).

## Storage model

One SSTORE2 blob **per trait option** (each painting, each label, each background,
each frame), shared across all 2,618 tokens — never per-token image data. Per-token
storage is only the packed combo. DMG 2-bit PNGs are tiny, comfortably under the
SSTORE2 / EIP-170 ceiling, so no option is split across pointers. A gas-bounded
batched setup path (`addOptionsBatch`) deploys many pointers across multiple txs.

Two flags per option: **`exists`** (permanent — the renderer must always resolve art
for any held option, so blobs are never deleted) and **`rollable`** (toggleable —
governs sampling; lets you pre-stage art then reveal, or retire a trait from
circulation without breaking tokens that hold it).

## Extensibility

`painting`, `frame`, `background` are **growable**: appending an option is a pure
append at the next per-layer index — never a repack. Existing packed values can't
move, so a new option can never alias an existing combo; the space only grows and
occupancy only drops. Art value + weight are set in the same call (art/attributes
stay in sync). `label` is fixed and locked by `finalizeSetup()`. With mint closed, a
newly-added option enters only via reroll, so it seeps in slowly and is emergently
scarce; its weight sets the rate.

## Deploying new artworks (post-launch)

Adding a new painting, frame, or background to a **live** collection is a pure,
gas-bounded append — no redeploy, no repack, existing tokens untouched. `label` is
fixed and cannot grow. The full lifecycle:

**1. Prepare the PNG.** Same spec as the rest of the collection (default 140×160,
alpha-aware so it stacks). Files are **1-based, zero-padded to 3 digits**, so the
name is the current option count + 1 — if the layer already has 33 options (indices
0–32, files `001.png`–`033.png`), the new file is:

```
art/painting/034.png
```

**2. Record it in the manifest** (art + attributes fragment + weight, together). Each
`attributes` entry is that option's JSON fragment — one or more
`{"trait_type":…,"value":…}` objects, no surrounding `[ ]`, no trailing comma:

```jsonc
// art/manifest.json → "painting"
"attributes": [ ..., "{\"trait_type\":\"Demake\",\"value\":\"The Scream\"},{\"trait_type\":\"Master\",\"value\":\"Munch\"},{\"trait_type\":\"Year\",\"value\":\"1893\"}" ],
"weights":    [ ..., 100 ]   // append its sampling weight
```

**3. (Optional) re-check N_eff.** Adding options only *grows* the space (occupancy
drops), but if you retuned weights, revalidate: `python3 analysis/neff.py`.

**4. Append on-chain** (owner/timelock). One command handles one or many new
artworks — it appends exactly the manifest entries not yet on-chain, in batches, and
is idempotent (safe to re-run):

```bash
REGISTRY=$REGISTRY LAYER=0 \
forge script script/AddArtworks.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
# LAYER: 0 painting, 2 background, 3 frame.  ROLLABLE=false to pre-stage (see below).
```

For a single option without touching the manifest, `AddOption.s.sol` takes a direct
`PNG_PATH` instead (see Commands §6).

**5. Verify it landed:**

```bash
cast call $REGISTRY "optionCountOf(uint8)(uint256)" 0 --rpc-url $RPC_URL        # count grew
cast call $REGISTRY "optionAttributesOf(uint8,uint256)(string)" 0 33 --rpc-url $RPC_URL
```

**How it propagates.** Because mint is closed, a new option can only enter
circulation via the **reroll path** (a non-conduit transfer). It therefore seeps in
slowly and is **emergently scarce** — its `weight` sets the rate. Existing tokens
keep their traits until they themselves reroll.

**Timed reveal (pre-stage).** Publish the art on-chain now but keep it undrawable by
appending with `ROLLABLE=false`, then flip it live at your chosen moment:

```bash
cast send $REGISTRY "setRollable(uint8,uint256,bool)" 0 7 true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Note: `setRollable`/`setWeight` are blocked after `freezeWeights()`, so if you plan
to pre-stage/reveal or retune later, don't freeze weights yet. `addOption`/
`AddArtworks` themselves still work after freeze (they set the new weight at add
time) but the option can't then be toggled.

## Weighted sampling & N_eff

Each layer has an on-chain cumulative-weight array (CDF); a draw is a uniform pick
in `[0, totalWeight)` binary-searched to a bucket (no modulo sampling). Each layer
draw is seeded with a per-draw nonce `keccak256(prevrandao, tokenId, attempt, layer)`
— mandatory, or a batched mint would collapse to identical combos.

Weighting shrinks the effective space `N_eff = 1/sum(p_i^2)`, compounding
multiplicatively across the four independent layers. **Validate any weight config
before deploy** so combined `N_eff` stays well above supply (target >= ~30x):

```bash
python3 analysis/neff.py      # or: node analysis/neff.js
```

Raw combo space is 33*6*27*27 = **144,342**. Under uniform weights `N_eff` equals that
exactly (55x supply). The shipped tiered curve in `analysis/neff.py` gives
`N_eff` = **86,997 = 33.2x supply**, occupancy **3.01%**, E[attempts] ~= 1.03,
P(capmiss) ~= 6e-16. `analysis/neff.sol` + `test/unit/Neff.t.sol` cross-check this math
against the on-chain sampling.

See [Adjusting weights](#adjusting-weights) for the full retune process.

## Adjusting weights

Everything about *how often a trait is drawn* lives in **`TraitRegistry`**, not in the
token. `Galleria` stores only per-token combos; when it needs a trait it calls
`registry.sample(layer, seed)`, which reads the CDF the weights build. So every command
in this section targets `$REGISTRY`, never `$TOKEN`.

| Contract | Holds | Weight calls |
|---|---|---|
| `Galleria` (`$TOKEN`) | combos, conduit sets | no |
| `TraitRegistry` (`$REGISTRY`) | options, PNGs, weights, CDFs, `weightsFrozen` | **yes** |

Both are owner-only and normally owned by the same wallet, so this is one key in
practice — just the other address.

### The model

Every option carries a raw `weight` (uint32) and a `rollable` flag:

```
effective weight  = rollable ? weight : 0
p(option i)       = effective_i / sum(effective across the layer)
```

Four consequences worth internalising:

- **Only ratios matter.** `[200,100]` and `[2400,1200]` are the same distribution.
  Larger numbers just give finer granularity when you want distinct weights.
- **A non-rollable option is a zero-width bucket.** It can never be drawn, but it still
  renders for any token already holding it (`exists` is permanent).
- **Changes apply to FUTURE draws only** — mints and rerolls. Already-settled tokens
  keep their combos. A weight change never rewrites existing art.
- **The CDF is rebuilt on every write**, so the change is live the moment the tx lands.

### Layer ids and index mapping

| Layer | id | Options | Growable | Art directory |
|---|---|---|---|---|
| Painting | `0` | 33 | yes | `art/painting/` |
| Label | `1` | 6 | **no** (locked by `finalizeSetup`) | `art/label/` |
| Background | `2` | 27 | yes | `art/background/` |
| Frame | `3` | 27 | yes | `art/frame/` |

**Index ↔ file:** on-chain option index `i` is `art/<layer>/00(i+1).png`. Indices are
0-based, art files are 1-based. Option `0` is `001.png`; option `32` is `033.png`.
Indices are append-only and never renumbered, so this mapping is stable forever.

Confirm the live count before writing anything:

```bash
for L in 0 1 2 3; do cast call $REGISTRY "optionCountOf(uint8)(uint256)" $L --rpc-url $RPC_URL; done
```

### Step 1 — model the change before sending it

Weight changes compound *multiplicatively* across the four independent layers, so a
change that looks mild per-layer can breach the `N_eff >= 30x` guard. Always model first:

```bash
$EDITOR analysis/neff.py      # edit CONFIG to the weights you intend to set
python3 analysis/neff.py      # must print: PASS: N_eff >= 30x supply
```

`CONFIG` mirrors the on-chain arrays exactly — one list per layer, positional, rollable
options only. If it prints `WARN`, do not send the transaction; soften the skew.

### Step 2 — write the weights

Four write paths, all `onlyOwner` on `$REGISTRY`, all blocked once `freezeWeights()`
has run:

```bash
# a) ONE trait
cast send $REGISTRY "setWeight(uint8,uint256,uint32)" <layer> <index> <weight> \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# b) MANY traits in one layer — one tx, one CDF rebuild
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" <layer> "[<indices>]" "[<weights>]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# c) An ENTIRE layer, one array, no indices  (see availability note below)
cast send $REGISTRY "setPaintingWeights(uint32[])" "[<weights>]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# d) Remove from circulation WITHOUT deleting (still renders for current holders)
cast send $REGISTRY "setRollable(uint8,uint256,bool)" <layer> <index> false \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**(b) `setWeightsBatch`** is a *partial* write: only the indices you list are touched.
It reverts `LengthMismatch()` if the two arrays differ in length, and `BadOption()` if
any index was never added. Use it to retune a subset.

**(c) whole-layer setters** are a *total* write: the array must cover the layer exactly.
Use them when the array you have IS the distribution — no index bookkeeping, no risk of
a forgotten index keeping a stale weight.

| | `setWeightsBatch` | `set<Layer>Weights` |
|---|---|---|
| Scope | the indices you pass | the whole layer, always |
| Args | `layer`, `indices[]`, `weights[]` | `weights[]` |
| Wrong length | reverts only if the two arrays disagree | reverts unless it equals the option count |
| Partial retune | yes | no — send the full array |

> **Availability.** The four whole-layer setters are in `src/TraitRegistry.sol` but are
> **not on the currently deployed registry** — they ship with the next registry deploy.
> Until then use `setWeightsBatch`, which does the same job. Everything else in this
> section works against the live registry today.

### Step 3 — per-layer recipes (current shipped curve)

Each command below sets an entire layer in one transaction. Arrays are **positional**:
position `k` is option index `k`. They run commonest → rarest.

**Painting** (layer 0, 33 options, total weight 38,812):

```bash
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 0 \
  "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32]" \
  "[2400,2248,2182,2040,1977,1830,1764,1687,1559,1512,1420,1372,1273,1225,1143,1110,1046,982,953,888,853,794,767,718,696,648,625,579,560,536,499,478,448]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Label** (layer 1, 6 options, total 10,488):

```bash
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 1 \
  "[0,1,2,3,4,5]" "[2400,2025,1870,1571,1444,1178]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Background** (layer 2, 27 options, total 38,071):

```bash
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 2 \
  "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]" \
  "[2400,2266,2208,2081,2024,1891,1831,1761,1642,1599,1514,1468,1374,1330,1250,1219,1157,1095,1066,1002,968,908,881,831,809,760,736]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Frame** (layer 3, 27 options, total 37,149):

```bash
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 3 \
  "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]" \
  "[2400,2259,2198,2065,2006,1868,1805,1732,1610,1565,1478,1431,1335,1289,1208,1176,1114,1051,1022,957,923,863,836,786,764,716,692]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Note the label layer being non-growable does **not** stop weight edits — `finalizeSetup`
locks *adding options* to that layer, not retuning the ones already there.

### Step 3b — the same curve via the whole-layer setters

Identical result to Step 3, minus the indices array. **Not on the deployed registry yet**
(see the availability note in Step 2) — these are for the next registry deploy.

```bash
cast send $REGISTRY "setPaintingWeights(uint32[])" \
  "[2400,2248,2182,2040,1977,1830,1764,1687,1559,1512,1420,1372,1273,1225,1143,1110,1046,982,953,888,853,794,767,718,696,648,625,579,560,536,499,478,448]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

cast send $REGISTRY "setLabelWeights(uint32[])" \
  "[2400,2025,1870,1571,1444,1178]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

cast send $REGISTRY "setBackgroundWeights(uint32[])" \
  "[2400,2266,2208,2081,2024,1891,1831,1761,1642,1599,1514,1468,1374,1330,1250,1219,1157,1095,1066,1002,968,908,881,831,809,760,736]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

cast send $REGISTRY "setFrameWeights(uint32[])" \
  "[2400,2259,2198,2065,2006,1868,1805,1732,1610,1565,1478,1431,1335,1289,1208,1176,1114,1051,1022,957,923,863,836,786,764,716,692]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Each reverts `LengthMismatch()` unless the array length equals that layer's
`optionCountOf` **exactly** — too short would leave a tail of options on their old
weights, too long would silently drop the excess. Both are silent wrong-distribution
bugs, so the check is strict in both directions rather than a maximum.

Note the length requirement tracks the layer as it grows: append one painting and a
33-entry array stops fitting. Regenerate the array after any `addOption`.

### Adjusting a single trait

To make painting index 12 twice as common, leaving everything else alone:

```bash
cast call $REGISTRY "weightOf(uint8,uint256)(uint32)" 0 12 --rpc-url $RPC_URL      # 1273
cast send $REGISTRY "setWeight(uint8,uint256,uint32)" 0 12 2546 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Because probability is `weight / layerTotal`, raising one option **dilutes every other
option in that layer**. Doubling index 12 above moves the layer total from 38,812 to
40,085, so every other painting drops ~3.2% in relative frequency. If you want to change
one trait's rarity without disturbing the rest, rebalance the whole layer with
`setWeightsBatch` instead of nudging one value.

### Step 4 — read weights back

```bash
# WHOLE LAYER as an array of RAW weights  (see availability note in Step 2)
cast call $REGISTRY "paintingWeights()(uint32[])"   --rpc-url $RPC_URL
cast call $REGISTRY "labelWeights()(uint32[])"      --rpc-url $RPC_URL
cast call $REGISTRY "backgroundWeights()(uint32[])" --rpc-url $RPC_URL
cast call $REGISTRY "frameWeights()(uint32[])"      --rpc-url $RPC_URL
cast call $REGISTRY "weightsOf(uint8)(uint32[])" 0  --rpc-url $RPC_URL   # generic by layer id

# per-option
cast call $REGISTRY "weightOf(uint8,uint256)(uint32)" 0 32 --rpc-url $RPC_URL
cast call $REGISTRY "isRollable(uint8,uint256)(bool)" 0 32 --rpc-url $RPC_URL

# effective (what sampling actually sees)
cast call $REGISTRY "totalWeight(uint8)(uint256)" 0 --rpc-url $RPC_URL   # sum of effective weights
cast call $REGISTRY "cdfOf(uint8)(uint256[])"     0 --rpc-url $RPC_URL
```

Each getter returns exactly `optionCountOf(layer)` entries in option-index order — the
same length its matching setter demands — so a read feeds straight back into a write:

```bash
W=$(cast call $REGISTRY "paintingWeights()(uint32[])" --rpc-url $RPC_URL)
# ...edit W...
cast send $REGISTRY "setPaintingWeights(uint32[])" "$W" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**RAW vs EFFECTIVE.** The array getters report the stored `weight` field. A retired
(`rollable == false`) option still shows its weight there even though sampling can never
draw it. For what sampling sees, use `cdfOf` — or pair the array with `isRollable`.

**Without the array getters** (i.e. on the currently deployed registry), difference the
CDF, remembering it yields *effective* weights:

```bash
cast call $REGISTRY "cdfOf(uint8)(uint256[])" 0 --rpc-url $RPC_URL \
| tr -d '[]' | tr ',' '\n' | awk '{gsub(/ /,"");c[NR]=$1}
    END{for(i=1;i<=NR;i++) printf "%s%s", (i==1?c[1]:c[i]-c[i-1]), (i<NR?", ":"\n")}'
```

Read the CDF as the ground truth. It is cumulative, so option `i`'s effective weight is
`cdf[i] - cdf[i-1]`, and its probability is that gap over `cdf[last]`. A **flat step**
(`cdf[i] == cdf[i-1]`) means option `i` is unreachable — either weight 0 or
`rollable == false`. The last entry is the layer total.

### Gotchas

**`freezeWeights()` is one-way and broader than it sounds.** It permanently blocks
`setWeight`, `setWeightsBatch` *and* `setRollable` — so it also removes your only kill
switch for a bad option. It does **not** block `addOption`, so new options can still
enter a growable layer afterwards and shift the distribution. Leave it unfrozen until
the collection is genuinely finished.

**Never zero out an entire layer.** If a layer's total effective weight reaches 0,
sampling cannot draw it. `Galleria` handles this safely rather than bricking — a reroll
degrades to a `CapMiss` and keeps the old traits, and a mint reverts with `MintCapMiss()`
— but minting stays broken until you restore a positive weight. Zeroing a *single*
option is fine and is the normal way to retire one.

**Adding options changes N_eff.** Appending a common option raises it; appending a rare
one lowers it. Re-run `analysis/neff.py` after any `addOption`.

**Weights set the draw distribution, not the holding distribution.** Because traits
reroll on non-preserving transfers and holders can retry across blocks, anyone hunting a
rare trait can reroll until they get it and then keep it via `safeSend`. Observed
population counts will therefore drift *rarer* than the weights imply. Treat the table
as an equilibrium under passive play, not a guaranteed census.

**Gas.** `setWeightsBatch` costs roughly 5k gas per option touched plus the CDF rebuild
(one SSTORE per option in the layer), so a full 33-option painting retune is well under
1M gas — negligible on Base.

## Commands & workflows

Every workflow, end to end. Conventions used below:

```bash
export RPC_URL=https://...        # or http://localhost:8545 for anvil
export PRIVATE_KEY=0x...          # deployer / owner key (use a keystore in prod)
export ETHERSCAN_API_KEY=...      # for --verify / forge verify-contract
export SEADROP=0x00005EA00Ac477B1030CE78506496e8C2dE24bf5  # SeaDrop impl (mainnet canonical; chain-specific)
export REGISTRY=0x...             # TraitRegistry address (after step 4a)
export TOKEN=0x...                # Galleria address (after step 4b)
export RENDERER=0x...             # Renderer library address (after step 4b; only for manual verify)
```

`LAYER` ids everywhere: **0 = painting, 1 = label, 2 = background, 3 = frame.**
Growable layers are `0`, `2`, `3`; `label` (1) is fixed. All registry/token
mutators are **owner-only** — in production the owner is a timelock/multisig, so
those calls are proposed there; the `cast send` forms below are for local/testing
with the owner key.

### 0. Deploy & change runbook (at a glance)

The whole lifecycle in order. Each step links to its detailed section below. **The
contracts are not upgradeable** — `Galleria`'s `registry` is `immutable` and neither
contract has a proxy — so "pushing a change" is one of three things: an **admin
mutator** (config/art/weights, no redeploy), an **SSTORE2 append** (new art, no
redeploy), or a **full redeploy** (any change to contract *logic*). See
[Pushing changes to a live collection](#pushing-changes-to-a-live-collection) below.

**A. Fresh deploy (registry → collection)**

Assumes you deploy from a single wallet (`$PRIVATE_KEY`) and keep ownership there. Drop config
(mint price, fee recipient, creator payout, allowlist, etc.) is set afterward in
**OpenSea Studio**, so it is NOT passed at deploy time. (For a multisig/timelock handoff
or on-chain drop config instead, see the optional flags in §4b.)

```bash
# 0. prerequisites
foundryup && forge install                  # tooling + submodules   (§1)
forge build && forge test                   # compile + 73 tests green (§2, §3)
python3 analysis/neff.py                     # validate weights ≥ ~30× supply (§11)

# 1. registry: deploy + load all art from art/ (batched SSTORE2), locks label layer.
#    Owned by your deployer wallet. --verify auto-verifies TraitRegistry.                (§4a)
forge script script/DeployRegistry.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY \
--slow  --verify --etherscan-api-key $ETHERSCAN_API_KEY
export REGISTRY=0x<printed>

# 2. collection: deploy Galleria + linked Renderer, wire SeaDrop. Owned by your wallet.
#    --verify auto-verifies BOTH Galleria and its Renderer library, with the right
#    constructor args + library linkage — no manual bookkeeping.                          (§4b)
REGISTRY=$REGISTRY SEADROP_ADDRESS=$SEADROP \
forge script script/DeployCollection.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
export TOKEN=0x<printed>
# (Deploy produces THREE contracts: TraitRegistry, Renderer library, Galleria — all
#  verified above. If --verify is skipped, verify manually: see §4.)

# 3. configure the drop in OpenSea Studio (price, fee recipient, creator payout,
#    allowlist, dates). Your deployer wallet owns the contract, so it has full access.
#    (Prefer on-chain instead? See §8 for the cast/updatePublicDrop equivalents.)

# 4. lock down when done (ONE-WAY — optional, do these last)
cast send $REGISTRY "freezeWeights()"  --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # freezes weights+rollable §7
# (finalizeSetup() already ran inside DeployRegistry; label layer is locked)
```

<a id="pushing-changes-to-a-live-collection"></a>
**B. Pushing changes to a live collection (no redeploy)** — all owner-only:

| Want to change | Command | Section |
| --- | --- | --- |
| Add a painting/bg/frame (manifest-driven, batched) | `AddArtworks.s.sol` | §6 |
| Add one option from a single PNG | `AddOption.s.sol` | §6 |
| Pre-stage art now, reveal later | add `ROLLABLE=false` → later `setRollable(...true)` | §6 |
| Retune a sampling weight | `setWeight` / `setWeightsBatch` | §7 |
| Retire a trait from sampling (keeps rendering) | `setRollable(layer,i,false)` | §7 |
| Fix render (z) order | `setRenderOrder` | §7 |
| Change canvas size | `setCanvas` | §7 |
| Change collection description (all tokens, instant) | `setDescription` | §7 |
| Add a trait-preserving marketplace/router | `setBlessedConduit` | §8 |
| Change SeaDrop drop terms (price, allowlist, …) | `updatePublicDrop` / `updateAllowList` / … | §8 |
| Royalties / transfer validator | `setRoyaltyInfo` / `setTransferValidator` | §8 |
| Refresh marketplace metadata (EIP-4906) | `emitBatchMetadataUpdate(1,2618)` | §8 |

**C. Changing contract *logic* (requires a redeploy)** — anything in `src/*.sol`
behaviour (packing, sampling, transfer/reroll rules, render assembly). There is no
upgrade path: deploy a **new** `Galleria` against the existing (or a new) registry
via step A.2, re-wire SeaDrop, and migrate the drop. The old token's holders and
combos are unaffected; nothing is auto-migrated.

### 1. First-time setup

```bash
foundryup                                   # install/update forge, cast, anvil
forge install                               # fetch submodules (seadrop, solady, forge-std)
cp .env.example .env                        # then fill in RPC_URL, keys, SeaDrop addr
```

### 2. Build & format

```bash
forge build                                 # compile (auto-links the Renderer library)
forge build --sizes                         # runtime bytecode sizes (watch the 24,576 limit)
forge fmt                                    # format Solidity
forge inspect Galleria bytecode             # raw artifacts; also: abi, methodIdentifiers, storageLayout
forge clean                                 # wipe out/ and cache/
```

### 3. Test

```bash
forge test                                  # full suite incl. invariants (73 tests)
forge test -vvv                             # show traces (raise -v for more detail)
forge test --match-contract RerollTest      # one test contract
forge test --match-test test_capmiss        # one test by name
forge test --match-path 'test/unit/*'       # only unit tests
forge test --match-path 'test/invariant/*'  # only the uniqueness invariants

FOUNDRY_PROFILE=heavy forge test            # heavy fuzz/invariant profile (5,000 fuzz runs)
FOUNDRY_INVARIANT_RUNS=400 FOUNDRY_INVARIANT_DEPTH=64 \
  forge test --match-path 'test/invariant/*'   # ad-hoc deeper invariant run

forge coverage                              # line/branch coverage
forge test --gas-report                     # per-function gas
forge snapshot                              # write .gas-snapshot
```

### 4. Deploy (registry → collection)

```bash
# 4a. Registry: deploys TraitRegistry, loads all art from art/ (batched SSTORE2), and
#     finalizes. Constructed owned by the deployer, which runs the owner-only seeding.
#     Stays owned by your wallet. --verify verifies TraitRegistry in the same command.
forge script script/DeployRegistry.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
#   env: ART_DIR (default: "art"), PRIVATE_KEY
#   optional: TIMELOCK — if set, ownership is transferred to it after seeding
#             (immediate, single-step). Omit to keep deployer ownership.

# 4b. Collection: deploys Galleria + linked Renderer, wires it to SeaDrop. Stays owned
#     by your wallet; configure the drop afterward in OpenSea Studio (or on-chain, §8).
#     --verify verifies BOTH Galleria and its linked Renderer library (correct
#     constructor args + linkage handled for you).
REGISTRY=$REGISTRY SEADROP_ADDRESS=$SEADROP \
forge script script/DeployCollection.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
#   env: REGISTRY (required), SEADROP_ADDRESS, PRIVATE_KEY
#   optional: TIMELOCK — hand ownership to a multisig/timelock (two-step; the new owner
#             must acceptOwnership()). CONFIGURE_DROP=true + FEE_RECIPIENT + CREATOR_PAYOUT
#             — set a public drop on-chain at deploy instead of in Studio.
```

The deploy produces **three** on-chain contracts — `TraitRegistry`, the `Renderer`
library (deployed + linked automatically), and `Galleria` — and `--verify` verifies
all three. If you skipped `--verify` (or a verification failed), verify manually.
Each needs its constructor args, and `Galleria` must be linked to the deployed
`Renderer`:

```bash
# Registry — constructor arg: owner. It is constructed owned by the DEPLOYER (and only
# transferred later if you set TIMELOCK), so this constructor arg is the deployer address.
forge verify-contract $REGISTRY src/TraitRegistry.sol:TraitRegistry --chain mainnet \
  --constructor-args $(cast abi-encode "constructor(address)" 0x<deployer>)

# Renderer library — no constructor args. Its address is in the broadcast log
# (broadcast/DeployCollection.s.sol/<chainId>/run-latest.json) or the verify output.
forge verify-contract $RENDERER src/Renderer.sol:Renderer --chain mainnet

# Galleria — constructor args (name, symbol, allowedSeaDrop[], registry) AND the
# Renderer library link.
forge verify-contract $TOKEN src/Galleria.sol:Galleria --chain mainnet \
  --libraries src/Renderer.sol:Renderer:$RENDERER \
  --constructor-args $(cast abi-encode \
    "constructor(string,string,address[],address)" \
    "The Galleria" "GALLERIA" "[$SEADROP]" $REGISTRY)
```

### 5. Art pipeline

```bash
python3 art/generate_dummy_art.py           # (re)generate dummy PNGs + art/manifest.json
```

Real art: replace `art/<layer>/<NNN>.png` (140×160, 1-based zero-padded) and update
`art/manifest.json` (`attributes[]` + `weights[]` per layer). `DeployRegistry` reads
both. See "Art source".

### 6. Post-deploy admin — options (growable layers only)

See "Deploying new artworks" above for the full lifecycle. Quick reference:

```bash
# Append every NEW manifest entry for a layer (batched, idempotent). Preferred for
# adding one or many artworks: update art/manifest.json + drop the PNGs, then:
REGISTRY=$REGISTRY LAYER=0 \
forge script script/AddArtworks.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY

# Append ONE option directly from a PNG file (no manifest edit needed). ATTRIBUTES is
# the option's JSON fragment (one or more {"trait_type":..,"value":..}, no brackets).
REGISTRY=$REGISTRY LAYER=0 PNG_PATH=art/painting/034.png \
ATTRIBUTES='{"trait_type":"Demake","value":"Nighthawks"},{"trait_type":"Master","value":"Hopper"},{"trait_type":"Year","value":"1942"}' \
WEIGHT=100 ROLLABLE=true \
forge script script/AddOption.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY

# Equivalent raw call (index is assigned automatically = current option count):
cast send $REGISTRY "addOption(uint8,bytes,string,uint32,bool)" \
  0 0x<pngHex> '{"trait_type":"Demake","value":"Nighthawks"}' 100 true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

Pre-stage then reveal: add with `ROLLABLE=false`, then flip it live later:

```bash
cast send $REGISTRY "setRollable(uint8,uint256,bool)" 0 6 true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### 7. Post-deploy admin — weights, flags, render order, canvas

Quick reference. For the full weight-retuning process — index mapping, modelling with
`analysis/neff.py`, per-layer commands, verification and gotchas — see
[Adjusting weights](#adjusting-weights).

```bash
cast send $REGISTRY "setWeight(uint8,uint256,uint32)" 0 3 250 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 0 "[0,1,2]" "[100,150,200]" \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setRollable(uint8,uint256,bool)" 3 2 false --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setRenderOrder(uint8[])" "[2,0,3,1]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setCanvas(uint16,uint16)" 140 160 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# Collection-wide metadata description (applies to every token instantly; plain
# text, JSON-escaped at render time). NOT blocked by freezeWeights.
cast send $REGISTRY "setDescription(string)" "A fully on-chain 1-of-1 gallery." --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# One-way locks (do these LAST — they block the calls above):
cast send $REGISTRY "finalizeSetup()"  --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # locks label layer
cast send $REGISTRY "freezeWeights()"  --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # freezes weights+rollable
```

### 8. Post-deploy admin — token & SeaDrop drop config

```bash
# Blessed conduits (preserve traits instead of rerolling); OpenSea's is pre-seeded.
cast send $TOKEN "setBlessedConduit(address,bool)" 0x<operator> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# Excluded conduits (FORCE reroll, overriding blessed + Seaport recognition). The set
# ships EMPTY. It can only act on the address that actually arrives as msg.sender, so a
# router that delegates to a conduit — notably OpenSea's TransferHelper — can NEVER be
# caught by it: the token sees the Seaport conduit, indistinguishable from a real sale.
# Verified on Base, tx 0xd2c12301b89a81e1f0eef551638cc90dc80557626bc1495a84b7163aaef3e7b0.
cast send $TOKEN "setExcludedConduit(address,bool)" 0x<operator> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# SeaDrop drop wiring (inherited from ERC721SeaDrop; SEADROP = allowed SeaDrop impl):
cast send $TOKEN "updateCreatorPayoutAddress(address,address)" $SEADROP 0x<payout> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updateAllowedFeeRecipient(address,address,bool)" $SEADROP 0x<fee> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updatePublicDrop(address,(uint80,uint48,uint48,uint16,uint16,bool))" \
  $SEADROP "(10000000000000000,$(date +%s),$(($(date +%s)+604800)),10,500,true)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# also available: updateAllowList, updateTokenGatedDrop, updateSignedMintValidationParams,
#   updatePayer, updateDropURI, setBaseURI, setContractURI, setRoyaltyInfo, setMaxSupply,
#   setProvenanceHash, multiConfigure(...)

# Two-step ownership handoff to a timelock/multisig:
cast send $TOKEN "transferOwnership(address)" 0x<timelock> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# then, from the new owner:  cast send $TOKEN "acceptOwnership()" ...
```

### 9. Minting

Minting goes through SeaDrop (`mintSeaDrop`), gated to the allowed SeaDrop impl —
you don't call it directly in production; buyers mint via the configured drop on
OpenSea/SeaDrop. To exercise it locally on anvil, impersonate the SeaDrop:

```bash
SEADROP=0x00005EA00Ac477B1030CE78506496e8C2dE24bf5
cast rpc anvil_impersonateAccount $SEADROP --rpc-url $RPC_URL
cast rpc anvil_setBalance $SEADROP 0xDE0B6B3A7640000 --rpc-url $RPC_URL
cast send $TOKEN "mintSeaDrop(address,uint256)" 0x<minter> 3 \
  --from $SEADROP --unlocked --gas-limit 3000000 --rpc-url $RPC_URL

# Burn (owner/approved):
cast send $TOKEN "burn(uint256)" 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# Safe send (owner only): move a token to a new address WITHOUT rerolling its traits.
cast send $TOKEN "safeSend(address,uint256)" 0x<to> 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

### 10. Read on-chain state

```bash
# Token
cast call $TOKEN "tokenURI(uint256)(string)" 1 --rpc-url $RPC_URL        # full base64 data URI
cast call $TOKEN "comboOf(uint256)(uint256)" 1 --rpc-url $RPC_URL        # packed combo
cast call $TOKEN "traitsOf(uint256)(uint8,uint8,uint8,uint8)" 1 --rpc-url $RPC_URL
cast call $TOKEN "comboToToken(uint256)(uint256)" <combo> --rpc-url $RPC_URL   # tokenId+1, 0=free
cast call $TOKEN "ownerOf(uint256)(address)" 1 --rpc-url $RPC_URL
cast call $TOKEN "totalSupply()(uint256)" --rpc-url $RPC_URL
cast call $TOKEN "blessedConduit(address)(bool)" 0x<op> --rpc-url $RPC_URL

# Registry
cast call $REGISTRY "optionCountOf(uint8)(uint256)" 0 --rpc-url $RPC_URL
cast call $REGISTRY "optionAttributesOf(uint8,uint256)(string)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "isRollable(uint8,uint256)(bool)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "weightOf(uint8,uint256)(uint32)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "totalWeight(uint8)(uint256)" 0 --rpc-url $RPC_URL
cast call $REGISTRY "readOption(uint8,uint256)(bytes)" 0 6 --rpc-url $RPC_URL   # raw PNG bytes
cast call $REGISTRY "renderOrder()(uint8[])" --rpc-url $RPC_URL
cast call $REGISTRY "canvas()(uint16,uint16)" --rpc-url $RPC_URL
cast call $REGISTRY "description()(string)" --rpc-url $RPC_URL
```

Decode a `tokenURI` to inspect the JSON/SVG:

```bash
cast call $TOKEN "tokenURI(uint256)(string)" 1 --rpc-url $RPC_URL \
  | python3 -c "import sys,base64,json;s=sys.stdin.read().strip().strip('\"');print(base64.b64decode(s.split(',',1)[1]).decode())"
```

### 11. Validate a weight config (before deploy)

```bash
python3 analysis/neff.py        # edit CONFIG to your real weights first
node analysis/neff.js           # same math in JS
# analysis/neff.sol + test/unit/Neff.t.sol cross-check it on-chain
```

### 12. Local dev loop (anvil)

```bash
anvil                                                   # terminal 1
export RPC_URL=http://localhost:8545
export PRIVATE_KEY=<ANVIL_TEST_PRIVATE_KEY>  # anvil acct 0
# then run steps 4 → 9 against $RPC_URL
```

## Function reference (every callable function)

Every externally callable function, grouped by contract. Uses the env vars from
**Commands & workflows** (`$TOKEN`, `$REGISTRY`, `$PRIVATE_KEY`, `$RPC_URL`, `$SEADROP`). Reads use
`cast call`; state changes use `cast send`. Functions marked **[owner]** revert unless
called by the current owner (in production a timelock/multisig — propose there).
`LAYER` ids: `0` painting, `1` label, `2` background, `3` frame.

### Galleria — token (`$TOKEN`)

**Constants & wiring** (read)

```bash
cast call $TOKEN "SUPPLY()(uint256)" --rpc-url $RPC_URL                      # 2618
cast call $TOKEN "RESAMPLE_CAP()(uint256)" --rpc-url $RPC_URL                # 10
cast call $TOKEN "registry()(address)" --rpc-url $RPC_URL                    # TraitRegistry address
cast call $TOKEN "OPENSEA_CONDUIT()(address)" --rpc-url $RPC_URL
cast call $TOKEN "SEAPORT_CONDUIT_CONTROLLER()(address)" --rpc-url $RPC_URL
cast call $TOKEN "BLUR_EXECUTION_DELEGATE()(address)" --rpc-url $RPC_URL
cast call $TOKEN "SEAPORT_1_5()(address)" --rpc-url $RPC_URL
cast call $TOKEN "SEAPORT_1_6()(address)" --rpc-url $RPC_URL
cast call $TOKEN "OPENSEA_TRANSFER_HELPER()(address)" --rpc-url $RPC_URL   # seeded excluded (force reroll)
```

**Traits & combo** (read)

```bash
cast call $TOKEN "tokenURI(uint256)(string)" 1 --rpc-url $RPC_URL                    # base64 JSON data URI
cast call $TOKEN "comboOf(uint256)(uint256)" 1 --rpc-url $RPC_URL                    # packed combo
cast call $TOKEN "traitsOf(uint256)(uint8,uint8,uint8,uint8)" 1 --rpc-url $RPC_URL   # painting,label,bg,frame
cast call $TOKEN "comboToToken(uint256)(uint256)" <combo> --rpc-url $RPC_URL         # tokenId+1 (0 = free)
cast call $TOKEN "blessedConduit(address)(bool)" 0x<op> --rpc-url $RPC_URL           # is operator preserving?
cast call $TOKEN "excludedConduit(address)(bool)" 0x<op> --rpc-url $RPC_URL          # is operator force-reroll?
```

**Preserving transfer** (holder)

```bash
# Move a token to a new address WITHOUT rerolling. Caller must be the current owner.
cast send $TOKEN "safeSend(address,uint256)" 0x<to> 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Trait-preservation admin** [owner]

```bash
# Add/remove a preserving operator (Blur/Seaport routers are pre-seeded).
cast send $TOKEN "setBlessedConduit(address,bool)" 0x<op> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# Add/remove a FORCE-REROLL operator (overrides blessed + Seaport recognition).
# OpenSea's TransferHelper is pre-seeded so wallet "send" flows reroll.
cast send $TOKEN "setExcludedConduit(address,bool)" 0x<op> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Standard ERC721** (holder / operator)

```bash
cast call $TOKEN "name()(string)" --rpc-url $RPC_URL
cast call $TOKEN "symbol()(string)" --rpc-url $RPC_URL
cast call $TOKEN "totalSupply()(uint256)" --rpc-url $RPC_URL
cast call $TOKEN "balanceOf(address)(uint256)" 0x<owner> --rpc-url $RPC_URL
cast call $TOKEN "ownerOf(uint256)(address)" 1 --rpc-url $RPC_URL
cast call $TOKEN "getApproved(uint256)(address)" 1 --rpc-url $RPC_URL
cast call $TOKEN "isApprovedForAll(address,address)(bool)" 0x<owner> 0x<op> --rpc-url $RPC_URL
cast call $TOKEN "supportsInterface(bytes4)(bool)" 0x80ac58cd --rpc-url $RPC_URL       # 0x80ac58cd = ERC721

cast send $TOKEN "approve(address,uint256)" 0x<op> 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "setApprovalForAll(address,bool)" 0x<op> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "transferFrom(address,address,uint256)" 0x<from> 0x<to> 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # REROLLS (non-preserving path)
cast send $TOKEN "safeTransferFrom(address,address,uint256)" 0x<from> 0x<to> 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "safeTransferFrom(address,address,uint256,bytes)" 0x<from> 0x<to> 1 0x --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "burn(uint256)" 1 --private-key $PRIVATE_KEY --rpc-url $RPC_URL                # owner/approved; frees the combo
```

**Minting** (SeaDrop only)

```bash
# Only callable by an allowed SeaDrop impl; buyers mint via the configured drop.
# See Commands §9 for local anvil impersonation.
cast send $TOKEN "mintSeaDrop(address,uint256)" 0x<minter> 3 --from $SEADROP --unlocked --rpc-url $RPC_URL
cast call $TOKEN "getMintStats(address)(uint256,uint256,uint256)" 0x<minter> --rpc-url $RPC_URL  # minted, totalSupply, maxSupply
```

**SeaDrop drop config** [owner]

```bash
# Public drop tuple: (mintPrice, startTime, endTime, maxPerWallet, feeBps, restrictFeeRecipients)
cast send $TOKEN "updatePublicDrop(address,(uint80,uint48,uint48,uint16,uint16,bool))" \
  $SEADROP "(10000000000000000,$(date +%s),$(($(date +%s)+604800)),10,500,true)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# AllowList tuple: (merkleRoot, publicKeyURIs[], allowListURI)
cast send $TOKEN "updateAllowList(address,(bytes32,string[],string))" \
  $SEADROP "(0x<root>,[],ipfs://<allowlist.json>)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# TokenGated tuple: (mintPrice, maxPerWallet, startTime, endTime, dropStageIndex, maxTokenSupplyForStage, feeBps, restrict)
cast send $TOKEN "updateTokenGatedDrop(address,address,(uint80,uint16,uint48,uint48,uint8,uint32,uint16,bool))" \
  $SEADROP 0x<gateNft> "(...)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# SignedMint params: (minMintPrice, maxMaxPerWallet, minStartTime, maxEndTime, maxMaxTokenSupplyForStage, minFeeBps, maxFeeBps)
cast send $TOKEN "updateSignedMintValidationParams(address,address,(uint80,uint24,uint40,uint40,uint40,uint16,uint16))" \
  $SEADROP 0x<signer> "(...)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL

cast send $TOKEN "updateCreatorPayoutAddress(address,address)" $SEADROP 0x<payout> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updateAllowedFeeRecipient(address,address,bool)" $SEADROP 0x<fee> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updatePayer(address,address,bool)" $SEADROP 0x<payer> true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updateDropURI(address,string)" $SEADROP "ipfs://<drop.json>" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "updateAllowedSeaDrop(address[])" "[$SEADROP]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# multiConfigure bundles maxSupply + baseURI + contractURI + drop + allowlist + ... in ONE call.
# The struct is large; easiest via DeployCollection (CONFIGURE_DROP=true) or the SeaDrop docs.
```

**Metadata & supply** [owner]

```bash
cast send $TOKEN "setBaseURI(string)" "" --private-key $PRIVATE_KEY --rpc-url $RPC_URL          # unused — art is fully on-chain
cast call $TOKEN "baseURI()(string)" --rpc-url $RPC_URL
cast send $TOKEN "setContractURI(string)" "ipfs://<contract.json>" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast call $TOKEN "contractURI()(string)" --rpc-url $RPC_URL
cast send $TOKEN "setMaxSupply(uint256)" 2618 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast call $TOKEN "maxSupply()(uint256)" --rpc-url $RPC_URL
cast send $TOKEN "setProvenanceHash(bytes32)" 0x<hash> --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # before any mint only
cast call $TOKEN "provenanceHash()(bytes32)" --rpc-url $RPC_URL
cast send $TOKEN "emitBatchMetadataUpdate(uint256,uint256)" 1 2618 --private-key $PRIVATE_KEY --rpc-url $RPC_URL  # EIP-4906 refresh
```

**Royalties & transfer validator** [owner]

```bash
cast send $TOKEN "setRoyaltyInfo((address,uint96))" "(0x<receiver>,500)" --private-key $PRIVATE_KEY --rpc-url $RPC_URL  # 500 = 5%
cast call $TOKEN "royaltyInfo(uint256,uint256)(address,uint256)" 1 10000 --rpc-url $RPC_URL
cast call $TOKEN "royaltyAddress()(address)" --rpc-url $RPC_URL
cast call $TOKEN "royaltyBasisPoints()(uint256)" --rpc-url $RPC_URL
cast send $TOKEN "setTransferValidator(address)" 0x<validator> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast call $TOKEN "getTransferValidator()(address)" --rpc-url $RPC_URL
cast call $TOKEN "getTransferValidationFunction()(bytes4,bool)" --rpc-url $RPC_URL
```

**Ownership — two-step** [owner]

```bash
cast call $TOKEN "owner()(address)" --rpc-url $RPC_URL
cast send $TOKEN "transferOwnership(address)" 0x<newOwner> --private-key $PRIVATE_KEY --rpc-url $RPC_URL     # step 1
cast send $TOKEN "acceptOwnership()" --private-key $NEW_OWNER_PK --rpc-url $RPC_URL                 # step 2 (new owner)
cast send $TOKEN "cancelOwnershipTransfer()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN "renounceOwnership()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL                         # irreversible
```

### TraitRegistry (`$REGISTRY`)

**Options** [owner]

```bash
# Append ONE option: layer, PNG bytes, attributes fragment, weight, rollable.
cast send $REGISTRY "addOption(uint8,bytes,string,uint32,bool)" \
  0 0x<pngHex> '{"trait_type":"Demake","value":"Nighthawks"}' 100 true --private-key $PRIVATE_KEY --rpc-url $RPC_URL

# Batched append (parallel arrays).
cast send $REGISTRY "addOptionsBatch(uint8,bytes[],string[],uint32[],bool[])" \
  0 "[0x<png1>,0x<png2>]" '["<frag1>","<frag2>"]' "[100,100]" "[true,true]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

> Prefer the scripts — `AddArtworks.s.sol` (batched, manifest-driven) or `AddOption.s.sol`
> (single, direct `PNG_PATH`) — which read PNGs from disk for you. See Commands §6.

**Weights & flags** [owner]

```bash
cast send $REGISTRY "setWeight(uint8,uint256,uint32)" 0 3 250 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setWeightsBatch(uint8,uint256[],uint32[])" 0 "[0,1,2]" "[100,150,200]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setRollable(uint8,uint256,bool)" 0 6 true --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "freezeWeights()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL     # one-way: locks weights + rollable
cast send $REGISTRY "finalizeSetup()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL     # one-way: locks the label layer
```

**Render config** [owner]

```bash
cast send $REGISTRY "setRenderOrder(uint8[])" "[2,0,3,1]" --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # bottom→top: bg, painting, frame, label
cast send $REGISTRY "setCanvas(uint16,uint16)" 140 160 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
cast send $REGISTRY "setDescription(string)" "A fully on-chain 1-of-1 gallery." --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

**Reads — sampling**

```bash
cast call $REGISTRY "sample(uint8,uint256)(uint8)" 0 <rand> --rpc-url $RPC_URL   # draw an option index from entropy
cast call $REGISTRY "cdfOf(uint8)(uint256[])" 0 --rpc-url $RPC_URL               # cumulative-weight array
cast call $REGISTRY "totalWeight(uint8)(uint256)" 0 --rpc-url $RPC_URL
```

**Reads — options & config**

```bash
cast call $REGISTRY "optionCountOf(uint8)(uint256)" 0 --rpc-url $RPC_URL
cast call $REGISTRY "optionAttributesOf(uint8,uint256)(string)" 0 6 --rpc-url $RPC_URL   # the option's JSON fragment
cast call $REGISTRY "optionExists(uint8,uint256)(bool)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "isRollable(uint8,uint256)(bool)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "weightOf(uint8,uint256)(uint32)" 0 6 --rpc-url $RPC_URL
cast call $REGISTRY "pointerOf(uint8,uint256)(address)" 0 6 --rpc-url $RPC_URL            # SSTORE2 blob address
cast call $REGISTRY "readOption(uint8,uint256)(bytes)" 0 6 --rpc-url $RPC_URL             # raw PNG bytes
cast call $REGISTRY "isGrowable(uint8)(bool)" 0 --rpc-url $RPC_URL
cast call $REGISTRY "layerNameOf(uint8)(string)" 0 --rpc-url $RPC_URL
cast call $REGISTRY "renderOrder()(uint8[])" --rpc-url $RPC_URL
cast call $REGISTRY "canvas()(uint16,uint16)" --rpc-url $RPC_URL
cast call $REGISTRY "canvasWidth()(uint16)" --rpc-url $RPC_URL
cast call $REGISTRY "canvasHeight()(uint16)" --rpc-url $RPC_URL
cast call $REGISTRY "description()(string)" --rpc-url $RPC_URL
cast call $REGISTRY "weightsFrozen()(bool)" --rpc-url $RPC_URL
cast call $REGISTRY "setupFinalized()(bool)" --rpc-url $RPC_URL
```

**Ownership — Solady** (note: `transferOwnership` here is **single-step**, unlike the token) [owner]

```bash
cast call $REGISTRY "owner()(address)" --rpc-url $RPC_URL
cast send $REGISTRY "transferOwnership(address)" 0x<newOwner> --private-key $PRIVATE_KEY --rpc-url $RPC_URL   # immediate
cast send $REGISTRY "renounceOwnership()" --private-key $PRIVATE_KEY --rpc-url $RPC_URL                       # irreversible
# Two-step handover alternative (initiated by the incoming owner):
cast send $REGISTRY "requestOwnershipHandover()" --private-key $NEW_OWNER_PK --rpc-url $RPC_URL
cast send $REGISTRY "completeOwnershipHandover(address)" 0x<newOwner> --private-key $PRIVATE_KEY --rpc-url $RPC_URL  # current owner completes
cast send $REGISTRY "cancelOwnershipHandover()" --private-key $NEW_OWNER_PK --rpc-url $RPC_URL
cast call $REGISTRY "ownershipHandoverExpiresAt(address)(uint256)" 0x<newOwner> --rpc-url $RPC_URL
```

## Compiler note

Pinned to **Solidity 0.8.17** because seadrop uses a *fixed* `pragma solidity 0.8.17`.
The `block.prevrandao` identifier only exists from 0.8.18, so entropy is read via
`block.difficulty` — the same post-merge opcode (`0x44` / PREVRANDAO), byte-identical
on any post-merge chain — isolated in `SamplingLib._entropyBase` so it can be swapped
for a VRF without touching anything else.

## Open decisions (defaults used; flagged `TODO: confirm` at the top of `Galleria.sol`)

1. **Field width = 8 bits (256 max) per growable layer** (painting/frame/background).
   Confirm 256 exceeds the most you'd ever reach in **each**, not just painting.
2. **Resample cap N = 10.**
3. **Reroll entropy = PREVRANDAO** folded into the per-draw nonce. Not
   caller-controlled, but PREVRANDAO is known during execution and the reroll is
   retryable across blocks, so a holder **can** grind for a desired combo (revert on
   an unwanted result, retry next block) and keep it by holding or selling through a
   blessed conduit, which preserves. This is **intended** — grinding out rares is a
   permitted game mechanic, not a defended-against attack. Isolated in
   `SamplingLib._entropyBase` for a VRF swap if that ever needs to change.
4. **Uniqueness key = all four layers** (label independent decorative — the chosen
   model); `N_eff` is a four-layer product.
5. **New options enter only via reroll once mint is closed** — confirm vs a
   mint-window-only reveal.
6. **Cross-layer compatibility:** every option freely combines with every other (no
   "this frame only fits that painting"). If constraints exist, sampling must be
   constrained and the space discounted — a different mechanic.
7. **Canvas = 140x160 px** (width x height). Adjustable via `registry.setCanvas`.
