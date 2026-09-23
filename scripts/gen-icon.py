#!/usr/bin/env python3
"""NoBu（iOS）のアプリアイコンを依存なしで描く。Web 版の scripts/gen-icons.py と同じ絵。
紙色の地に、傾けた本が3冊並ぶ本棚。出力は Assets.xcassets の 1024px 1枚だけ。"""
import os
import struct
import zlib

BG = (0x2F, 0x4A, 0x3A)      # 深い緑
SHELF = (0xE9, 0xDF, 0xC9)
BOOKS = [(0xF6, 0xF1, 0xE7), (0xB5, 0x53, 0x2E), (0xD9, 0xB4, 0x6A)]


def png(w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def draw(n):
    px = bytearray(BG * (n * n))

    def rect(x0, y0, x1, y1, c, skew=0.0):
        for y in range(int(y0 * n), int(y1 * n)):
            off = skew * ((y1 * n) - y)
            for x in range(int(x0 * n + off), int(x1 * n + off)):
                if 0 <= x < n and 0 <= y < n:
                    i = (y * n + x) * 3
                    px[i:i + 3] = bytes(c)

    rect(0.26, 0.28, 0.38, 0.70, BOOKS[0])
    rect(0.26, 0.34, 0.38, 0.37, BG)       # 背の帯
    rect(0.40, 0.24, 0.52, 0.70, BOOKS[1])
    rect(0.40, 0.60, 0.52, 0.63, BG)
    rect(0.56, 0.30, 0.67, 0.70, BOOKS[2], skew=0.28)
    rect(0.20, 0.70, 0.80, 0.745, SHELF)   # 棚板
    return png(n, n, px)


out = os.path.join(os.path.dirname(__file__), "..", "NoBu", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "AppIcon-1024.png"), "wb") as f:
    f.write(draw(1024))
print("AppIcon-1024.png written")
