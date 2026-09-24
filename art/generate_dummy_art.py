#!/usr/bin/env python3
"""
Generate DUMMY placeholder art for The Galleria as a reference for the on-chain
deploy pipeline. Produces 140x160 RGBA PNGs under art/<layer>/<index>.png plus
art/manifest.json (per-option value + weight), which script/DeployRegistry.s.sol
reads at deploy time.

The dummies are intentionally distinct and alpha-aware so the stacked SVG in
tokenURI actually shows layering:
  - background : fully opaque solid color
  - painting   : opaque centered rectangle, transparent elsewhere
  - frame      : opaque border ring, transparent center
  - label      : opaque bar near the bottom, transparent elsewhere

Replace this art (and the manifest values/weights) with the real collection.
No third-party deps — hand-rolls PNG via zlib.

Run:  python3 art/generate_dummy_art.py
"""

import json
import os
import struct
import zlib

W, H = 140, 160

# (layer dir, count, base RGB palette cycled per option)
LAYERS = {
    "painting": (6, [(210, 60, 60), (60, 150, 210), (240, 200, 70), (120, 200, 120), (180, 110, 210), (230, 140, 70)]),
    "label": (4, [(30, 30, 30), (250, 250, 250), (200, 40, 40), (40, 90, 200)]),
    "background": (4, [(245, 236, 220), (30, 34, 48), (210, 225, 240), (250, 240, 210)]),
    "frame": (4, [(120, 82, 40), (200, 200, 205), (212, 175, 55), (40, 40, 40)]),
}


def png(pixels):
    """pixels: H rows of W (r,g,b,a) tuples -> PNG bytes."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type 0
        for (r, g, b, a) in row:
            raw += bytes((r, g, b, a))

    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def make(layer, idx, rgb):
    r, g, b = rgb
    T = (0, 0, 0, 0)  # transparent
    C = (r, g, b, 255)  # opaque color
    rows = []
    for y in range(H):
        row = []
        for x in range(W):
            px = T
            if layer == "background":
                px = C
            elif layer == "painting":
                if 24 <= x < W - 24 and 30 <= y < H - 30:
                    px = C
            elif layer == "frame":
                if x < 12 or x >= W - 12 or y < 12 or y >= H - 12:
                    px = C
            elif layer == "label":
                if 20 <= x < W - 20 and H - 34 <= y < H - 12:
                    px = C
            row.append(px)
        rows.append(row)
    return png(rows)


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    manifest = {}
    for layer, (count, palette) in LAYERS.items():
        d = os.path.join(root, layer)
        os.makedirs(d, exist_ok=True)
        values, weights = [], []
        for i in range(count):
            rgb = palette[i % len(palette)]
            with open(os.path.join(d, f"{i}.png"), "wb") as f:
                f.write(make(layer, i, rgb))
            values.append(f"{layer.capitalize()} {i}")
            weights.append(100)  # uniform dummy weights; retune for production
        manifest[layer] = {"values": values, "weights": weights}
        print(f"{layer:<11} {count} options -> {d}")

    with open(os.path.join(root, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("wrote", os.path.join(root, "manifest.json"))


if __name__ == "__main__":
    main()
