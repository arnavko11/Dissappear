"""Renders the Dissappear app icon without external image libraries."""
import math, struct, zlib, os, json

MASTER = 1024
SS = 2                      # supersample factor
N = MASTER * SS

BG_TOP = (0x11, 0x18, 0x24)
BG_BOTTOM = (0x1E, 0x2A, 0x3C)
ACCENT = (0x0A, 0x84, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_rect_contains(x, y, left, top, right, bottom, radius):
    if x < left or x > right or y < top or y > bottom:
        return False
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def polygon_contains(x, y, points):
    inside = False
    j = len(points) - 1
    for i in range(len(points)):
        xi, yi = points[i]
        xj, yj = points[j]
        if (yi > y) != (yj > y):
            if x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                inside = not inside
        j = i
    return inside


def render(mac: bool):
    """Returns an RGBA bytearray at MASTER x MASTER."""
    margin = N * 0.098 if mac else 0.0
    corner = (N - 2 * margin) * 0.2237 if mac else 0.0
    left, top = margin, margin
    right, bottom = N - margin, N - margin

    cx, cy = N / 2, N / 2
    ring_r = N * 0.300
    ring_w = N * 0.0165

    # Location arrow: tip at top, notch at the bottom centre.
    ah = N * 0.325          # height
    aw = N * 0.190          # half width
    notch = N * 0.085
    arrow = [(cx, cy - ah / 2 - N * 0.012),
             (cx + aw, cy + ah / 2),
             (cx, cy + ah / 2 - notch),
             (cx - aw, cy + ah / 2)]

    acc = [[0, 0, 0, 0] for _ in range(MASTER * MASTER)]

    for sy in range(N):
        row_t = sy / (N - 1)
        base = lerp(BG_TOP, BG_BOTTOM, row_t)
        oy = (sy // SS) * MASTER
        for sx in range(N):
            if mac and not rounded_rect_contains(sx, sy, left, top, right, bottom, corner):
                continue
            r, g, b = base
            d = math.hypot(sx - cx, sy - cy)
            if abs(d - ring_r) <= ring_w:
                r, g, b = ACCENT
            if polygon_contains(sx, sy, arrow):
                r, g, b = WHITE
            p = acc[oy + (sx // SS)]
            p[0] += r; p[1] += g; p[2] += b; p[3] += 255

    samples = SS * SS
    out = bytearray(MASTER * MASTER * 4)
    for i, (r, g, b, a) in enumerate(acc):
        alpha = a // samples
        if alpha == 0:
            continue
        # Un-premultiply so edges stay crisp against transparency.
        cover = a / 255
        out[i * 4 + 0] = min(255, round(r / cover))
        out[i * 4 + 1] = min(255, round(g / cover))
        out[i * 4 + 2] = min(255, round(b / cover))
        out[i * 4 + 3] = alpha
    return out


def downsample(src, size):
    if size == MASTER:
        return src
    step = MASTER / size
    out = bytearray(size * size * 4)
    for y in range(size):
        y0, y1 = int(y * step), max(int(y * step) + 1, int((y + 1) * step))
        for x in range(size):
            x0, x1 = int(x * step), max(int(x * step) + 1, int((x + 1) * step))
            r = g = b = a = n = 0
            for yy in range(y0, y1):
                base = (yy * MASTER + x0) * 4
                for i in range(x1 - x0):
                    o = base + i * 4
                    alpha = src[o + 3]
                    r += src[o] * alpha; g += src[o + 1] * alpha; b += src[o + 2] * alpha
                    a += alpha; n += 1
            o = (y * size + x) * 4
            if a:
                out[o] = min(255, r // a); out[o + 1] = min(255, g // a); out[o + 2] = min(255, b // a)
            out[o + 3] = a // n if n else 0
    return out


def write_png(path, pixels, size):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw += pixels[y * size * 4:(y + 1) * size * 4]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


ios_dir = "iOS/Resources/Assets.xcassets/AppIcon.appiconset"
mac_dir = "macOS/Resources/Assets.xcassets/AppIcon.appiconset"
os.makedirs(ios_dir, exist_ok=True)
os.makedirs(mac_dir, exist_ok=True)

print("rendering iOS master…")
ios = render(mac=False)
write_png(f"{ios_dir}/AppIcon-1024.png", ios, MASTER)
json.dump({"images": [{"filename": "AppIcon-1024.png", "idiom": "universal",
                       "platform": "ios", "size": "1024x1024"}],
           "info": {"author": "xcode", "version": 1}},
          open(f"{ios_dir}/Contents.json", "w"), indent=2)

print("rendering macOS master…")
mac = render(mac=True)
mac_images = []
for size, scale, pt in [(16, "1x", 16), (32, "2x", 16), (32, "1x", 32), (64, "2x", 32),
                        (128, "1x", 128), (256, "2x", 128), (256, "1x", 256),
                        (512, "2x", 256), (512, "1x", 512), (1024, "2x", 512)]:
    name = f"AppIcon-{size}.png"
    if not os.path.exists(f"{mac_dir}/{name}"):
        write_png(f"{mac_dir}/{name}", downsample(mac, size), size)
        print(" wrote", name)
    mac_images.append({"filename": name, "idiom": "mac", "scale": scale,
                       "size": f"{pt}x{pt}"})
json.dump({"images": mac_images, "info": {"author": "xcode", "version": 1}},
          open(f"{mac_dir}/Contents.json", "w"), indent=2)

# Asset catalogues need a root Contents.json too.
for root in ["iOS/Resources/Assets.xcassets", "macOS/Resources/Assets.xcassets"]:
    json.dump({"info": {"author": "xcode", "version": 1}},
              open(f"{root}/Contents.json", "w"), indent=2)
print("done")
