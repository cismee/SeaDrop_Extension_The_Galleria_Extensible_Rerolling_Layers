# Adding a New Painting

How to append a new painting to the live Galleria collection, start to finish.

**Time:** ~30 min. **Cost:** one transaction, roughly 4–5M gas.

---

## The short version

```bash
# 1. Put the new PNG at the next number
cp mynewpainting.png art/painting/034.png

# 2. Append its attributes + weight to art/manifest.json (see Step 3)

# 3. Sanity-check the rarity math
python3 analysis/neff.py

# 4. Bump the count in test/unit/RealManifest.t.sol, then
forge test

# 5. Dry run
REGISTRY=0x1Fb6023a3E8f01429fd3F24D753C4c2429152118 LAYER=0 \
  forge script script/AddArtworks.s.sol:AddArtworks --rpc-url $RPC_URL

# 6. Send it
REGISTRY=0x1Fb6023a3E8f01429fd3F24D753C4c2429152118 LAYER=0 \
  forge script script/AddArtworks.s.sol:AddArtworks --rpc-url $RPC_URL \
  --broadcast --ledger --sender <OWNER_ADDRESS>
```

Details for each step below.

---

## Before you start: what actually happens

The painting layer (**layer 0**) is *growable*, which means you can append to it
forever, even though setup is finalized. Appending is a **pure append**:

- The new painting gets the **next index**. Nothing is renumbered.
- **No existing token changes.** Every token on-chain keeps the exact packed
  value it already has.
- The combo space **gets bigger**, never smaller. Uniqueness is unaffected.

**Holders do not receive the new painting immediately.** Minting is closed, so
the only way a new painting enters circulation is when a token **rerolls** (a
non-marketplace transfer). It seeps in slowly. Its weight controls how fast.

---

## Step 0 — Pre-flight checks

Read the live registry before you touch anything. Set your RPC first:

```bash
export RPC_URL=<your mainnet rpc>
export REGISTRY=0x1Fb6023a3E8f01429fd3F24D753C4c2429152118
```

```bash
cast call $REGISTRY "optionCountOf(uint8)(uint256)" 0   --rpc-url $RPC_URL  # paintings on-chain
cast call $REGISTRY "isGrowable(uint8)(bool)"       0   --rpc-url $RPC_URL  # must be true
cast call $REGISTRY "owner()(address)"                  --rpc-url $RPC_URL  # must be you
cast call $REGISTRY "weightsFrozen()(bool)"             --rpc-url $RPC_URL  # read the warning below
```

Write down the painting count. **If it returns `33`, your new file is
`034.png` and its on-chain index will be `33`.** (Files are 1-based, indices are
0-based. The script handles the conversion; you just name the file correctly.)

> **⚠️ If `weightsFrozen` is `true`:** you can still add the painting, but you can
> **never** flip its `rollable` flag afterwards. That means you must add it with
> `ROLLABLE=true` and the right weight **on the first try**. There is no
> pre-stage-then-reveal, and no retuning the weight later. Get it right up front.

---

## Step 1 — Prepare the PNG

Match the existing paintings exactly:

| Requirement | Value |
| --- | --- |
| Dimensions | **1120 × 1280** px |
| Format | PNG, 8-bit **RGBA** (color type 6) |
| Transparency | **Required** — the background layer shows through behind it |
| File size | **Hard limit 24,575 bytes.** Aim for **≤ 23,000**. |

Existing paintings run 13,451 – 22,540 bytes, so the ceiling is closer than it
looks. Check and compress:

```bash
ls -l mynewpainting.png                  # must be under 24,575
oxipng -o max --strip safe mynewpainting.png   # if you need to shrink it
```

Verify the header matches the others:

```bash
python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
w,h=struct.unpack('>II',d[16:24])
print(f'{w}x{h} bitdepth={d[24]} colortype={d[25]} bytes={len(d)}')
" mynewpainting.png
# expect: 1120x1280 bitdepth=8 colortype=6 bytes=<24575
```

If the file is over 24,575 bytes the transaction **will revert** with
`DeploymentFailed()`.

---

## Step 2 — Drop the file in place

```bash
cp mynewpainting.png art/painting/034.png
```

Use the next number in sequence, zero-padded to 3 digits. Do not rename or
reorder any existing file.

---

## Step 3 — Add it to `art/manifest.json`

`art/manifest.json` is the source of truth. Open it and **append one entry to the
end** of both `painting.attributes` and `painting.weights`. Position matters:
the *n*-th entry in each array is the *n*-th painting on-chain.

The attributes value is a **JSON string containing a JSON fragment** — so every
inner quote is backslash-escaped. Copy the shape of the line above it:

```json
"painting": {
  "attributes": [
    "...",
    "{\"trait_type\":\"Demake\",\"value\":\"Noli me Tangere\"},{\"trait_type\":\"Master\",\"value\":\"Bronzino\"},{\"trait_type\":\"Year\",\"value\":\"c. 1560–1561\"}",
    "{\"trait_type\":\"Demake\",\"value\":\"YOUR PAINTING\"},{\"trait_type\":\"Master\",\"value\":\"YOUR MASTER\"},{\"trait_type\":\"Year\",\"value\":\"c. 1500\"}"
  ],
  "weights": [
    536, 2040, 794, "...", 1764,
    1200
  ]
}
```

Rules for the attributes fragment:

- **No** surrounding `[ ]` brackets.
- **No** trailing comma at the end.
- Paintings carry three traits: `Demake`, `Master`, `Year`.
- It is emitted into token metadata **verbatim, unescaped**. Malformed JSON here
  breaks `tokenURI` for every token that draws this painting. Step 4 catches it.

### Choosing the weight

Weight sets how common the painting is. Current painting weights:

| | value |
| --- | --- |
| Range in use | 448 (rarest) – 2,400 (commonest) |
| Total across 33 paintings | 38,812 |

Pick from this table:

| Weight | Draw chance | Roughly this many of 2,618, long-run |
| --- | --- | --- |
| 500 | 1.3% | 34 |
| 1,200 | 3.0% | 79 |
| 2,400 | 5.8% | 152 |

**Keep it at 450 or above.** The collection's rarity design holds every option
above a ~1% draw chance; anything lower breaks that convention.

---

## Step 4 — Check the rarity math

Edit `analysis/neff.py` and append the same weight to the end of the `"painting"`
list in `CONFIG` (around line 57), then run it:

```bash
python3 analysis/neff.py
```

You want the last line to read **`PASS: N_eff >= 30x supply`**. Adding a painting
always *increases* N_eff (a 34th painting at weight 1,200 takes it from 33.2× to
~34.4× supply), so this should pass comfortably. If it doesn't, something else is
wrong — stop and investigate.

---

## Step 5 — Update the test, then run the suite

`test/unit/RealManifest.t.sol` asserts the painting count against the manifest.
It **will fail** until you bump it. Line 37:

```solidity
assertEq(paintings.length, 34, "paintings");   // was 33
```

Then:

```bash
forge test
```

This test actually renders `tokenURI` from your real manifest and parses the
output JSON, so **it is what catches a broken attributes fragment.** Do not skip
it. Everything must be green before you broadcast.

---

## Step 6 — Dry run against mainnet

No `--broadcast` flag means simulate only. Nothing is sent.

```bash
REGISTRY=$REGISTRY LAYER=0 \
  forge script script/AddArtworks.s.sol:AddArtworks --rpc-url $RPC_URL
```

Read the output. You are looking for:

```
Layer 0
  on-chain: 33
  manifest: 34
```

If it says `Nothing to add: on-chain count already matches manifest`, your
manifest edit didn't land. If it says `manifest has fewer options than on-chain`,
you removed an entry — undo that.

---

## Step 7 — Broadcast

```bash
REGISTRY=$REGISTRY LAYER=0 \
  forge script script/AddArtworks.s.sol:AddArtworks --rpc-url $RPC_URL \
  --broadcast --ledger --sender <OWNER_ADDRESS>
```

The script deploys the PNG as an SSTORE2 blob, registers it, stores its
attributes and weight, and rebuilds the painting CDF — all in **one transaction**
from the registry owner. Budget ~4–5M gas for a 22 KB painting (SSTORE2 costs
~200 gas per byte of art).

Using a keystore or raw key instead of a Ledger:

```bash
# keystore
... --broadcast --account <account-name> --sender <OWNER_ADDRESS>

# raw key (avoid on mainnet)
PRIVATE_KEY=0x... REGISTRY=$REGISTRY LAYER=0 forge script ... --broadcast
```

If the transaction is rejected for exceeding the gas limit, lower the byte
budget: `MAX_BATCH_BYTES=16000`.

---

## Step 8 — Verify it landed

```bash
cast call $REGISTRY "optionCountOf(uint8)(uint256)"          0    --rpc-url $RPC_URL  # 34
cast call $REGISTRY "weightOf(uint8,uint256)(uint32)"        0 33 --rpc-url $RPC_URL  # your weight
cast call $REGISTRY "isRollable(uint8,uint256)(bool)"        0 33 --rpc-url $RPC_URL  # true
cast call $REGISTRY "optionAttributesOf(uint8,uint256)(string)" 0 33 --rpc-url $RPC_URL
cast call $REGISTRY "totalWeight(uint8)(uint256)"            0    --rpc-url $RPC_URL  # 38812 + yours
```

Confirm the image itself renders:

```bash
cast call $REGISTRY "readOption(uint8,uint256)(bytes)" 0 33 --rpc-url $RPC_URL \
  | sed 's/^0x//' | xxd -r -p > /tmp/onchain.png
cmp /tmp/onchain.png art/painting/034.png && echo "byte-identical ✓"
```

Then commit the repo changes (`art/painting/034.png`, `art/manifest.json`,
`analysis/neff.py`, `test/unit/RealManifest.t.sol`) so the repo matches the chain.

---

## Gotchas

**Never run `python3 art/generate_dummy_art.py`.** It overwrites `art/manifest.json`
with dummy placeholder data at the wrong dimensions and the wrong key name. It is
a leftover from initial development.

**Never insert or reorder.** Manifest arrays are positional and match on-chain
indices exactly. Only ever append to the end. Inserting in the middle silently
reassigns which artwork is which rarity, for every painting after the insert point.

**Nothing is reversible.** `exists` is permanent — an option can never be deleted
or replaced. The only undo is `setRollable(0, 33, false)`, which stops *future*
draws but leaves the art in place for tokens already holding it. And that lever is
gone entirely if `weightsFrozen` is true.

**`freezeWeights()` does not block adding paintings.** Appending to a growable
layer always works. What freezing blocks is `setWeight`, `setRollable`, and the
whole-layer setters — i.e. everything *after* the add.

**`setPaintingWeights()` now needs 34 entries.** The whole-layer setters demand an
array exactly as long as the option count, or they revert with `LengthMismatch()`.
Read the current values with `paintingWeights()` first.

**Adding several at once works.** Drop `034.png`, `035.png`, append both to the
manifest, run the script once — it appends everything new, chunked across as many
transactions as the gas budget needs.

---

## Alternative: one-off without touching the manifest

`script/AddOption.s.sol` appends a single option straight from the command line.
It skips the manifest, which means **the repo no longer matches the chain** — use
it only in a hurry, and backfill the manifest afterwards.

```bash
REGISTRY=$REGISTRY \
LAYER=0 \
PNG_PATH=art/painting/034.png \
ATTRIBUTES='{"trait_type":"Demake","value":"YOUR PAINTING"},{"trait_type":"Master","value":"YOUR MASTER"},{"trait_type":"Year","value":"c. 1500"}' \
WEIGHT=1200 \
ROLLABLE=true \
  forge script script/AddOption.s.sol:AddOption --rpc-url $RPC_URL \
  --broadcast --ledger --sender <OWNER_ADDRESS>
```

Note the `ATTRIBUTES` value here is **raw JSON in single quotes** — not the
backslash-escaped form used inside `manifest.json`.

---

## Reference

| Thing | Value |
| --- | --- |
| Registry (mainnet) | `0x1Fb6023a3E8f01429fd3F24D753C4c2429152118` |
| Token (mainnet) | `0x0964Fe43B3bE705219a1513b3f0450AD65692EBc` |
| Painting layer id | `0` |
| Growable layers | painting `0`, background `2`, frame `3` |
| Fixed layer | label `1` — locked forever, cannot be appended to |
| Max options per layer | 256 (8-bit field) |
| Max PNG bytes | 24,575 |
