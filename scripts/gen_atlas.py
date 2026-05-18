"""Pre-render Menlo 5pt glyph atlas + metrics for Zig consumption.

Format (binary, little-endian):
  Header (16 bytes):
    magic           4   "MNAT"
    version         2   u16 = 1
    cell_w          2   u16  max glyph width
    cell_h          2   u16  cell height (asc+desc)
    asc             2   u16
    desc            2   u16
    first_char      1   u8   = 32 (space)
    last_char       1   u8   = 126 (~)
  Per-glyph (N glyphs = last-first+1):
    advance_px      2   u16
    -- packed 1-bit bitmap, cell_w*cell_h bits, row-major
"""
import struct
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/System/Library/Fonts/Menlo.ttc"
FONT_SIZE = 5
FIRST = 32  # space
LAST  = 126 # ~

font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
asc, desc = font.getmetrics()
cell_h = asc + desc

# Find max glyph width across our range
max_w = 0
for code in range(FIRST, LAST + 1):
    ch = chr(code)
    w = int(font.getlength(ch)) + 1
    if w > max_w:
        max_w = w

cell_w = max_w
print(f"Atlas: cell={cell_w}x{cell_h}, asc={asc}, desc={desc}, chars={LAST-FIRST+1}")

with open("/tmp/menlo5_atlas.bin", "wb") as f:
    # Header
    f.write(b"MNAT")
    f.write(struct.pack("<H", 1))          # version
    f.write(struct.pack("<H", cell_w))
    f.write(struct.pack("<H", cell_h))
    f.write(struct.pack("<H", asc))
    f.write(struct.pack("<H", desc))
    f.write(struct.pack("<B", FIRST))
    f.write(struct.pack("<B", LAST))

    # Glyphs
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        advance = int(font.getlength(ch))
        img = Image.new("L", (cell_w, cell_h), 255)
        d = ImageDraw.Draw(img)
        d.text((0, -desc // 2), ch, fill=0, font=font)
        # Threshold to 1-bit (anti-aliased pixels -> any non-white -> black)
        pix = img.load()
        f.write(struct.pack("<H", advance))
        # Pack row-major bits: bit=1 means BLACK (ink)
        bits = []
        for y in range(cell_h):
            for x in range(cell_w):
                bits.append(1 if pix[x, y] < 200 else 0)
        # Pack 8 bits per byte
        for i in range(0, len(bits), 8):
            byte = 0
            for j in range(8):
                if i + j < len(bits) and bits[i + j]:
                    byte |= 1 << (7 - j)
            f.write(struct.pack("<B", byte))

import os
print(f"Atlas size: {os.path.getsize('/tmp/menlo5_atlas.bin')} bytes")
