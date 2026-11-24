#!/usr/bin/env python3
"""
logo2bin.py - turn the Commander X16 logo PNG into data for GUIMenu.

    python3 tools/logo2bin.py CommanderX16_320.png

The logo is shown with VERA sprites: 5 sprites of 64x64 pixels, side by
side, in 8 bits per pixel (each pixel is a palette index, 0 = see-through).
This script writes two files that GUIMENU.ASM includes with .incbin:

  LOGO.PAL  the logo's colours, for palette entries LOGO_PAL_FIRST..255,
            2 bytes each in VERA's format: $GB (green, blue), then $0R (red)

  LOGO.RLE  the pixels of the 5 sprites one after another (sprite 0 rows
            0-63, then sprite 1, ...), run-length encoded to save space:
              $00, n   -> n see-through pixels (n = 1..255)
              $00, $00 -> end of the data
              anything else -> one pixel of that colour

The PNG's flat background colour (its top-left pixel) becomes
see-through, so the logo sits straight on the desktop.

Needs Pillow (pip install pillow). The .PAL and .RLE files are checked in,
so building GUIMenu doesn't need Python - only rerun this to change the logo.
"""
import sys
from PIL import Image

SPR = 64            # sprite width and height in pixels
COUNT = 5           # sprites across
FIRST = 128         # first palette entry used by the logo
NCOL = 256 - FIRST  # number of palette entries available


def to12(c):
    """8-bit RGB -> nearest 4-bit-per-channel RGB (what VERA can show)."""
    return tuple((v * 15 + 127) // 255 for v in c[:3])


def main(src):
    im = Image.open(src).convert("RGB")
    w, h = im.size
    if w > SPR * COUNT or h > SPR:
        sys.exit(f"image is {w}x{h}, must fit in {SPR * COUNT}x{SPR}")

    bg = to12(im.getpixel((0, 0)))
    pix = [[to12(im.getpixel((x, y))) for x in range(w)] for y in range(h)]

    # Every colour except the background needs a palette entry. If there
    # are too many, let Pillow pick the best NCOL and map to those.
    colours = sorted({c for row in pix for c in row if c != bg})
    if len(colours) > NCOL:
        strip = Image.new("RGB", (len(colours), 1))
        strip.putdata([tuple(v * 17 for v in c) for c in colours])
        q = strip.quantize(colors=NCOL, method=Image.Quantize.MEDIANCUT)
        qpal = q.getpalette()
        remap = {c: to12(qpal[i * 3:i * 3 + 3])
                 for c, i in zip(colours, q.getdata())}
        pix = [[c if c == bg else remap[c] for c in row] for row in pix]
        colours = sorted(set(remap.values()))
    index = {c: FIRST + i for i, c in enumerate(colours)}

    # palette file: always NCOL entries (unused ones black)
    pal = bytearray()
    for i in range(NCOL):
        r, g, b = colours[i] if i < len(colours) else (0, 0, 0)
        pal += bytes([(g << 4) | b, r])

    # pixel stream, sprite by sprite, padded with see-through pixels
    stream = []
    for s in range(COUNT):
        for y in range(SPR):
            for x in range(s * SPR, (s + 1) * SPR):
                c = pix[y][x] if x < w and y < h else bg
                stream.append(0 if c == bg else index[c])

    rle = bytearray()
    i = 0
    while i < len(stream):
        if stream[i] == 0:
            n = 1
            while i + n < len(stream) and stream[i + n] == 0 and n < 255:
                n += 1
            rle += bytes([0, n])
            i += n
        else:
            rle.append(stream[i])
            i += 1
    rle += bytes([0, 0])

    open("LOGO.PAL", "wb").write(pal)
    open("LOGO.RLE", "wb").write(rle)
    print(f"{len(colours)} colours, LOGO.RLE {len(rle)} bytes "
          f"(from {len(stream)} pixels)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "CommanderX16_320.png")
