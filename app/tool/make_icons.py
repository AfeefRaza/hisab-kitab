"""Generates the Hisab Kitab app icons (no dependencies: pure-Python PNG writer).

Run from app/:  python tool/make_icons.py
Design: teal background, white ledger page with ruled lines, gold coin.
"""
import struct
import zlib
from pathlib import Path

TEAL = (15, 118, 110)
WHITE = (255, 255, 255)
LINE = (153, 204, 199)
GOLD = (245, 179, 1)
GOLD_DARK = (180, 120, 0)


def rounded_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def shade(u, v, maskable):
    """Colour at normalised coords u, v in [0, 1]."""
    # maskable icons keep content inside the central 80% safe zone
    s = 0.78 if maskable else 1.0
    u = (u - 0.5) / s + 0.5
    v = (v - 0.5) / s + 0.5
    if not maskable and not rounded_rect(u, v, 0, 0, 1, 1, 0.22):
        return None  # transparent corners for the regular icon
    col = TEAL
    # ledger page
    if rounded_rect(u, v, 0.22, 0.18, 0.70, 0.82, 0.05):
        col = WHITE
        for ly in (0.34, 0.46, 0.58, 0.70):
            if abs(v - ly) < 0.018 and 0.30 < u < 0.62:
                col = LINE
        if abs(u - 0.31) < 0.012 and 0.26 < v < 0.76:
            col = (239, 68, 68)  # margin line
    # coin
    d = ((u - 0.70) ** 2 + (v - 0.70) ** 2) ** 0.5
    if d < 0.19:
        col = GOLD_DARK
    if d < 0.165:
        col = GOLD
        if abs(u - 0.70) < 0.02 and abs(v - 0.70) < 0.09:
            col = GOLD_DARK
        if abs(v - 0.70) < 0.02 and abs(u - 0.70) < 0.06:
            col = GOLD_DARK
    return col


def render(size, maskable=False, ss=3):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    c = shade((x + (sx + 0.5) / ss) / size, (y + (sy + 0.5) / ss) / size, maskable)
                    if c is not None:
                        acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += 255
            n = ss * ss
            a = acc[3] // n
            if a == 0:
                row += bytes([0, 0, 0, 0])
            else:
                k = acc[3] / 255
                row += bytes([int(acc[0] / k), int(acc[1] / k), int(acc[2] / k), a])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    web = Path(__file__).resolve().parent.parent / "web"
    (web / "icons").mkdir(exist_ok=True)
    (web / "favicon.png").write_bytes(render(32))
    (web / "icons" / "Icon-192.png").write_bytes(render(192))
    (web / "icons" / "Icon-512.png").write_bytes(render(512, ss=2))
    (web / "icons" / "Icon-maskable-192.png").write_bytes(render(192, maskable=True))
    (web / "icons" / "Icon-maskable-512.png").write_bytes(render(512, maskable=True, ss=2))
    (web / "icons" / "apple-touch-icon.png").write_bytes(render(180, maskable=True))
    print("icons written to", web)
