"""Generate the Gabbro app icon: 1024x1024, opaque RGB, no alpha.

Concept: gabbro is a dark, coarse-grained plutonic rock -- dark pyroxene
groundmass with pale plagioclase laths. Obsidian is volcanic glass. The app
name is doing that work already, so the icon leans into it: a cut, faceted
dark stone with pale mineral flecks, and a voice waveform as the bright
mineral vein through it.

No PIL here, so this rasterises by hand. Everything is drawn as per-row x
spans rather than per-pixel, which keeps a 2048^2 supersample fast in pure
Python. Rendered at 2x and box-downsampled for antialiasing.

iOS masks the corners itself and disallows alpha, so this is full-bleed and
opaque.
"""
import math
import struct
import zlib

SS = 2                      # supersample factor
OUT = 1024
N = OUT * SS

# --- palette -----------------------------------------------------------
TOP = (0x0E, 0x14, 0x16)     # deep pyroxene, near black with a green cast
BOT = (0x1E, 0x2C, 0x28)     # warmer green-black toward the base
BAR = (0xF2, 0xEC, 0xDD)     # plagioclase white, slightly warm
FLECK = (0x8E, 0xA3, 0x99)   # pale green-grey mineral grain


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def shade(c, d):
    return tuple(max(0, min(255, c[i] + d)) for i in range(3))


# --- canvas ------------------------------------------------------------
# rows[y] is a bytearray of N*3 bytes.
rows = []
for y in range(N):
    base = lerp(TOP, BOT, y / (N - 1))
    rows.append(bytearray(base * N))


def fill_span(y, x0, x1, colour):
    if y < 0 or y >= N:
        return
    x0 = max(0, int(x0))
    x1 = min(N, int(x1))
    if x1 <= x0:
        return
    rows[y][x0 * 3:x1 * 3] = bytes(colour) * (x1 - x0)


def poly_spans(points):
    """Yield (y, xmin, xmax) for a convex-ish polygon via scanline."""
    ys = [p[1] for p in points]
    for y in range(max(0, int(min(ys))), min(N, int(max(ys)) + 1)):
        xs = []
        for i in range(len(points)):
            (x1, y1), (x2, y2) = points[i], points[(i + 1) % len(points)]
            if y1 == y2:
                continue
            if min(y1, y2) <= y < max(y1, y2):
                xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        if len(xs) >= 2:
            yield y, min(xs), max(xs)


def draw_facet(points, delta):
    """Flat tint over the vertical gradient -- colour depends only on y."""
    for y, xa, xb in poly_spans(points):
        base = lerp(TOP, BOT, y / (N - 1))
        fill_span(y, xa, xb, shade(base, delta))


# --- facets ------------------------------------------------------------
# Broad angular planes, like a split rock face. Kept low-contrast so they
# read as material at 1024px and vanish politely at 60px.
S = N / 1024.0
draw_facet([(0, 0), (1024 * S, 0), (1024 * S, 300 * S), (0, 430 * S)], +13)
draw_facet([(0, 430 * S), (1024 * S, 300 * S), (1024 * S, 560 * S), (0, 640 * S)], -9)
draw_facet([(0, 760 * S), (1024 * S, 700 * S), (1024 * S, 1024 * S), (0, 1024 * S)], +18)
# A single brighter cleavage plane, off-centre so the icon is not symmetric.
draw_facet([(640 * S, 0), (1024 * S, 0), (1024 * S, 210 * S), (560 * S, 120 * S)], +26)


# --- plagioclase flecks ------------------------------------------------
# Coarse-grained is the identifying feature of gabbro, so the speckle is the
# point, not decoration. Deterministic seed: the icon must be reproducible.
class Rand:
    def __init__(self, seed):
        self.s = seed

    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / 0x7FFFFFFF


rnd = Rand(20260921)
for _ in range(68):
    cx, cy = rnd.next() * N, rnd.next() * N
    if 0.30 * N < cx < 0.70 * N and 0.18 * N < cy < 0.82 * N:
        continue  # keep grain off the mark
    w = (4 + rnd.next() * 11) * S
    h = (2.5 + rnd.next() * 5) * S
    ang = rnd.next() * math.pi
    strength = 0.08 + rnd.next() * 0.20
    ca, sa = math.cos(ang), math.sin(ang)
    pts = []
    for dx, dy in ((-w, -h), (w, -h), (w, h), (-w, h)):
        pts.append((cx + dx * ca - dy * sa, cy + dx * sa + dy * ca))
    for y, xa, xb in poly_spans(pts):
        base = lerp(TOP, BOT, y / (N - 1))
        col = tuple(int(base[i] + (FLECK[i] - base[i]) * strength) for i in range(3))
        fill_span(y, xa, xb, col)


# --- waveform ----------------------------------------------------------
# Five bars, not seven: at the 60x60 the home screen actually renders, five
# chunky bars stay legible where seven turn into grey mush. Heights are
# asymmetric so it reads as speech rather than an equaliser graphic.
def rounded_bar(cx, half_w, half_h, colour):
    top, bot = cy_mid - half_h, cy_mid + half_h
    r = half_w
    for y in range(max(0, int(top)), min(N, int(bot) + 1)):
        if y < top + r:                      # top cap
            dy = (top + r) - y
            dx = math.sqrt(max(0.0, r * r - dy * dy))
        elif y > bot - r:                    # bottom cap
            dy = y - (bot - r)
            dx = math.sqrt(max(0.0, r * r - dy * dy))
        else:
            dx = half_w
        fill_span(y, cx - dx, cx + dx, colour)


cy_mid = N * 0.5
bar_w = 74 * S
gap = 46 * S
heights = [95, 205, 310, 245, 132]           # HALF-heights; peak = 620px tall
total = len(heights) * bar_w + (len(heights) - 1) * gap
x = (N - total) / 2 + bar_w / 2
for h in heights:
    rounded_bar(x, bar_w / 2, h * S, BAR)
    x += bar_w + gap


# --- downsample and write ----------------------------------------------
print("downsampling...")
out_rows = []
for oy in range(OUT):
    row = bytearray(OUT * 3)
    r0, r1 = rows[oy * SS], rows[oy * SS + 1]
    for ox in range(OUT):
        i = ox * SS * 3
        for c in range(3):
            row[ox * 3 + c] = (r0[i + c] + r0[i + 3 + c] + r1[i + c] + r1[i + 3 + c]) >> 2
    out_rows.append(bytes(row))

raw = b"".join(b"\x00" + r for r in out_rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", OUT, OUT, 8, 2, 0, 0, 0))  # colour type 2 = RGB, no alpha
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

import sys
path = sys.argv[1]
with open(path, "wb") as f:
    f.write(png)
print(f"wrote {path} ({len(png) / 1024:.0f} KB, {OUT}x{OUT}, RGB no alpha)")
