#!/usr/bin/env python3
"""Original pixel-art pet pack: 雪独角鲸 / Snow Narwhal, with a baked-in Santa hat.

Draws everything from primitives (no reference artwork, no downloaded assets) and
writes a schema-1 pet pack in the format of `docs/pets/README.md`:

    pack.json + idle.png + working.png + thinking.png

Each sheet is 64x32: two 32x32 cells side by side. The canvas is 32x32 at
`scale: 1` / `pixelArt: true`. Every animation is two frames at 400 ms and the
two frames differ (breathing bob and tail sway), with the hat baked into every
frame so it moves with the head.

The animation `box` is the whole 32x32 canvas cell, not `contentBox`: the app
requires `frameW == trunc(box.w * scale)` / `frameH == trunc(box.h * scale)`
(docs/pets/README.md §4.1, `PetPackValidator`), so a 32x32 cell means a 32x32
box. `contentBox` stays the idle body box from the design brief.

Run from anywhere (Pillow only; no numpy, no network):

    python3 app/tool/make_xmas_narwhal.py --out app/test/fixtures/pets/xmas-narwhal/

Optional extras for manual phone testing (not part of the committed fixture):

    python3 app/tool/make_xmas_narwhal.py \
        --out app/test/fixtures/pets/xmas-narwhal/ \
        --zip experiments/xmas-narwhal/xmas-narwhal.zip \
        --preview experiments/xmas-narwhal/preview.png

The output is deterministic: same script -> byte-identical pack.json and PNGs.
"""

import argparse
import json
import os
import sys
import zipfile

from PIL import Image

# ---------------------------------------------------------------- palette ---

CLEAR = (0, 0, 0, 0)
OUTLINE = (16, 38, 50, 255)  # deep navy-teal, not DeepSeek blue
BODY_LIGHT = (132, 232, 236, 255)  # icy rim light
BODY_MAIN = (84, 204, 214, 255)  # winter teal
BODY_MID = (58, 176, 192, 255)
BODY_SHADE = (38, 130, 152, 255)
BELLY = (240, 252, 255, 255)
BELLY_SHADE = (198, 236, 244, 255)
SPOT = (44, 146, 166, 255)
TUSK = (248, 240, 210, 255)
TUSK_SHADE = (206, 184, 138, 255)
EYE = (14, 34, 46, 255)
EYE_SHINE = (255, 255, 255, 255)
HAT_RED = (212, 48, 58, 255)
HAT_DARK = (154, 28, 42, 255)
HAT_LIGHT = (240, 100, 104, 255)
TRIM = (252, 252, 252, 255)
TRIM_SHADE = (208, 228, 238, 255)
BUBBLE = (250, 253, 255, 255)
ICE = (196, 240, 250, 255)

W = H = 32
ANIMS = ("idle", "working", "thinking")
FRAME_MS = 400


# ---------------------------------------------------------------- drawing ---

def blank():
    return [[CLEAR for _ in range(W)] for _ in range(H)]


def put(canvas, x, y, color):
    if 0 <= x < W and 0 <= y < H:
        canvas[y][x] = color


def ellipse(cx, cy, rx, ry):
    """Pixel-centre ellipse mask."""
    return {
        (x, y)
        for y in range(H)
        for x in range(W)
        if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0
    }


def polygon(points):
    """Even-odd polygon mask on pixel centres."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    out = set()
    for y in range(max(0, min(ys)), min(H - 1, max(ys)) + 1):
        for x in range(max(0, min(xs)), min(W - 1, max(xs)) + 1):
            px, py = x + 0.5, y + 0.5
            inside = False
            j = len(points) - 1
            for i in range(len(points)):
                xi, yi = points[i]
                xj, yj = points[j]
                if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
                    inside = not inside
                j = i
            if inside:
                out.add((x, y))
    return out


def dilate(mask):
    out = set(mask)
    for x, y in mask:
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)):
            out.add((x + dx, y + dy))
    return out


def outline_of(mask):
    """One-pixel ring around `mask` (drawn outside the silhouette)."""
    return dilate(mask) - mask


# -------------------------------------------------------------- character ---

def tail_mask(sway=0):
    """Two-lobe whale fluke on the right; `sway` moves the tips left/right."""
    s = sway
    upper = polygon([(23, 19), (27 + s, 14), (29 + s, 15), (27, 22)])
    lower = polygon([(23, 24), (27 + s, 27), (29 + s, 26), (27, 22)])
    return upper | lower


def tusk_pixels(dy=0, down=False):
    """Ivory horn, one pixel column at a time: 2 px at the base, 1 px at the tip."""
    out = []
    for i in range(7):
        x = 7 - i
        base_y = 17 + i if down else 17 - i
        for t in range(2 if i < 4 else 1):
            out.append((x, base_y + t + dy))
    return out


def render_frame(kind, index):
    """One 32x32 RGBA frame. `kind` in ANIMS, `index` 0/1.

    The body stays on the baseline; the head (and with it the hat, tusk, eye and
    spots on the head) lifts 1 px on frame 1, which reads as breathing without
    lifting the pet off its perch. The tail sways sideways.
    """
    frame = blank()
    head_dy = 0 if index == 0 else -1  # breathing: the head rises 1 px
    sway = 0 if index == 0 else (1 if kind != "working" else -1)

    torso = ellipse(16.0, 21.0, 9.4, 5.8)
    head = ellipse(11.5, 19.5 + head_dy, 6.2, 5.7)
    raised = kind == "working" and index == 1
    flank = ellipse(8.0, (23.4 if raised else 24.4), 2.8, 1.8)
    body = torso | head | tail_mask(sway) | polygon([(23, 19), (26, 20), (26, 24), (23, 25)]) | flank

    # ---- silhouette: outline outside, then the teal body with rims.
    for x, y in outline_of(body):
        put(frame, x, y, OUTLINE)
    top, bottom = {}, {}
    for x in range(W):
        column = [y for (xx, y) in body if xx == x]
        if column:
            top[x], bottom[x] = min(column), max(column)
    for x, y in body:
        if y <= top[x]:
            put(frame, x, y, BODY_LIGHT)
        elif y >= bottom[x]:
            put(frame, x, y, BODY_SHADE)
        else:
            put(frame, x, y, BODY_MAIN)

    # ---- white belly on the front-bottom of the head/chest.
    belly = ellipse(12.5, 23.0, 5.2, 3.0) & body
    for x, y in belly:
        put(frame, x, y, BELLY)
    for x, y in belly:
        if (x, y + 1) not in body:
            put(frame, x, y, BELLY_SHADE)

    # ---- pectoral flipper shaded onto the silhouette's lower front (raised
    # while working). No ink line: it is part of the body outline.
    for x, y in flank & body:
        put(frame, x, y, BODY_SHADE if (x, y + 1) not in flank else BODY_MID)

    # ---- mottled spots on the back.
    for x, y in ((14, 16), (16, 17), (13, 18)):
        if (x, y + head_dy) in body:
            put(frame, x, y + head_dy, SPOT)

    # ---- tusk: a solid ivory horn from the forehead, up-left (idle/thinking)
    # or down-left (working), with faint cross bands for the spiral.
    tusk = set(tusk_pixels(head_dy, down=kind == "working"))
    for x, y in outline_of(tusk):
        put(frame, x, y, OUTLINE)
    for x, y in tusk:
        put(frame, x, y, TUSK_SHADE if (x + y) % 5 == 0 else TUSK)

    # ---- face: one 2x2 eye with a shine. It sits in the open head, away from
    # the tusk base and the hat brim's outline.
    eye_x, eye_y = 10, 16 + head_dy
    for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
        put(frame, eye_x + dx, eye_y + dy, EYE)
    put(frame, eye_x, eye_y, EYE_SHINE)

    # ---- Santa hat: white brim, red cone, white pom-pom; baked every frame and
    # riding the same 1 px head lift as the eye.
    cone = polygon([(8, 12 + head_dy), (16, 12 + head_dy), (16, 4 + head_dy)])
    for x, y in outline_of(cone):
        put(frame, x, y, OUTLINE)
    for x, y in cone:
        put(frame, x, y, HAT_RED)
    for x, y in cone:
        if (x + 1, y) not in cone or (x, y + 1) not in cone:
            put(frame, x, y, HAT_DARK)
        elif (x - 1, y) not in cone:
            put(frame, x, y, HAT_LIGHT)
    brim = ellipse(12.0, 13.0 + head_dy, 4.9, 1.4)
    for x, y in outline_of(brim):
        put(frame, x, y, OUTLINE)
    for x, y in brim:
        put(frame, x, y, TRIM)
    for x, y in brim:
        if (x, y + 1) not in brim:
            put(frame, x, y, TRIM_SHADE)
    pom = ellipse(16.2, 3.6 + head_dy, 1.9, 1.6)
    for x, y in outline_of(pom):
        put(frame, x, y, OUTLINE)
    for x, y in pom:
        put(frame, x, y, TRIM)
    for x, y in pom:
        if (x, y + 1) not in pom:
            put(frame, x, y, TRIM_SHADE)

    # ---- per-state props (off the body; never inside contentBox).
    if kind == "thinking":
        d = head_dy
        cloud = (
            ellipse(25.0, 7.0 + d, 3.5, 2.7)
            | ellipse(27.8, 8.2 + d, 2.0, 1.7)
            | ellipse(25.6, 9.6 + d, 2.3, 1.6)
            | ellipse(26.8, 4.8 + d, 2.0, 1.6)
        )
        if index == 1:
            cloud |= ellipse(28.8, 5.6 + d, 1.6, 1.3)
        for x, y in outline_of(cloud):
            put(frame, x, y, OUTLINE)
        for x, y in cloud:
            put(frame, x, y, BUBBLE)
    if kind == "working":
        # A chunk of ice the narwhal is chipping with its horn, plus sparks.
        block = polygon([(0, 24), (4, 23), (6, 25), (5, 27), (1, 27), (0, 26)])
        for x, y in outline_of(block):
            put(frame, x, y, OUTLINE)
        for x, y in block:
            put(frame, x, y, ICE)
        for x, y in ((1, 25), (2, 25), (3, 25)):
            put(frame, x, y, TRIM)
        sparks = [(3, 21), (4, 22), (2, 21)] if index == 0 else [(2, 20), (4, 21), (3, 23)]
        for x, y in sparks:
            put(frame, x, y, TRIM)

    return frame


def sheet(kind):
    img = Image.new("RGBA", (64, 32), CLEAR)
    for i in range(2):
        frame = Image.new("RGBA", (32, 32), CLEAR)
        frame.putdata([p for row in render_frame(kind, i) for p in row])
        img.paste(frame, (i * 32, 0))
    return img


# ------------------------------------------------------------------- pack ---

def pack_json():
    return {
        "schema": 1,
        "id": "xmas-narwhal",
        "name": "雪独角鲸",
        "author": "dsh-Go",
        "license": "CC0-1.0",
        "source": "original pixel art generated for dsh-Go",
        "pixelArt": True,
        "scale": 1,
        "canvas": {"w": 32, "h": 32},
        "anchor": {"x": 16, "baseline": 28},
        "contentBox": {"x": 6, "y": 10, "w": 20, "h": 14},
        "animations": {
            name: {
                "sheet": f"{name}.png",
                "frameW": 32,
                "frameH": 32,
                "cols": 2,
                "box": {"x": 0, "y": 0, "w": 32, "h": 32},
                "loop": True,
                "frames": [{"i": 0, "ms": FRAME_MS}, {"i": 1, "ms": FRAME_MS}],
            }
            for name in ANIMS
        },
        "states": {"idle": ["idle"], "working": ["working"], "thinking": ["thinking"]},
    }


# ------------------------------------------------------------------ output ---

def write_fixture(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name in ANIMS:
        sheet(name).save(os.path.join(out_dir, f"{name}.png"))
    with open(os.path.join(out_dir, "pack.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(pack_json(), f, ensure_ascii=False, indent=2)
        f.write("\n")


def write_zip(zip_path, out_dir):
    os.makedirs(os.path.dirname(os.path.abspath(zip_path)) or ".", exist_ok=True)
    names = ["pack.json", *(f"{name}.png" for name in ANIMS)]
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(os.path.join(out_dir, name), "rb") as f:
                zf.writestr(info, f.read())


def write_preview(preview_path, out_dir):
    """256x256 nearest-neighbour contact sheet: idle 0/1, working 0, thinking 0."""
    os.makedirs(os.path.dirname(os.path.abspath(preview_path)) or ".", exist_ok=True)
    picks = [("idle", 0), ("idle", 1), ("working", 0), ("thinking", 0)]
    cells = []
    for name, index in picks:
        with Image.open(os.path.join(out_dir, f"{name}.png")) as sheet_img:
            cells.append(sheet_img.convert("RGBA").crop((index * 32, 0, index * 32 + 32, 32)))
    bg = Image.new("RGBA", (256, 256), (20, 32, 42, 255))
    for i, cell in enumerate(cells):
        bg.paste(cell.resize((128, 128), Image.NEAREST), ((i % 2) * 128, (i // 2) * 128))
    for p in range(256):  # thin cross separating the four cells
        bg.putpixel((128, p), (60, 86, 98, 255))
        bg.putpixel((p, 128), (60, 86, 98, 255))
    bg.save(preview_path)
    return preview_path


def main(argv=None):
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        default=os.path.join(repo_root, "app", "test", "fixtures", "pets", "xmas-narwhal"),
        help="directory for pack.json and the three sheets (default: the test fixture)",
    )
    parser.add_argument("--zip", help="also write an importable zip (pack.json + PNGs at its root)")
    parser.add_argument("--preview", help="also write a 256x256 nearest-neighbour preview PNG")
    args = parser.parse_args(argv)

    write_fixture(args.out)
    if args.zip:
        write_zip(args.zip, args.out)
    if args.preview:
        write_preview(args.preview, args.out)
    print(f"wrote {args.out}")
    if args.zip:
        print(f"wrote {args.zip}")
    if args.preview:
        print(f"wrote {args.preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
