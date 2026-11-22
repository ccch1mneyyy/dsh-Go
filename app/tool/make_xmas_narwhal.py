#!/usr/bin/env python3
"""Original pixel-art pet pack: 雪独角鲸 / Snow Narwhal, with a baked-in Santa hat.

Draws everything from primitives (no reference artwork, no downloaded assets) and
writes a schema-1 pet pack in the format of `docs/pets/README.md`:

    pack.json + idle.png + working.png + thinking.png
              + react-left.png + react-right.png + react-double.png + react-drag.png

Each sheet is 64x32: two 32x32 cells side by side. The canvas is 32x32 at
`scale: 1` / `pixelArt: true`. The three state animations are two frames at
400 ms (breathing bob and tail sway). The four reactions are two frames at
220-260 ms with `loop: false`, wired through `reactions` so a poke, a tickle and
a drag play them: the body leans left/right and blinks, hops with raised fins, or
hangs 2 px off the foot line with drooping fins. In every frame the hat is baked
in and rides the head, and the two frames really differ (the lean settles, the
body hops, the hanging body swings).

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
from dataclasses import dataclass

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

# Reactions: `pack.json` key -> (animation name, ms per frame). Two frames each,
# `loop: false` (the App plays one pass and returns to the state animation; a
# drag is driven by the pointer, so its two frames repeat while held).
#   tap      2 x 220 = 440 ms: a quick recoil that stays readable at 4.5 fps.
#   tickle   2 x 240 = 480 ms: a little more hang time on the hop.
#   drag     2 x 260 = 520 ms: a slow dangle rather than a twitch.
REACTIONS = {
    "tapLeft": ("react-left", 220),
    "tapRight": ("react-right", 220),
    "tickle": ("react-double", 240),
    "drag": ("react-drag", 260),
}
ALL_ANIMS = ANIMS + tuple(name for name, _ in REACTIONS.values())


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


def shift(mask, dx, dy):
    """The same pixel mask moved by whole pixels."""
    if dx == 0 and dy == 0:
        return set(mask)
    return {(x + dx, y + dy) for x, y in mask}


@dataclass(frozen=True)
class Pose:
    """Where the parts sit in one frame.

    `dx`/`dy` move the whole character (lean, hop, hang); `head_dx`/`head_dy`
    move only the head and what rides it (tusk, eye, hat, head spots); `sway`
    tips the tail; `flipper` picks the pectoral fin pose; `blink` closes the eye
    for that frame; `horn` lifts the horn tip by extra pixels.
    """

    dx: int = 0
    dy: int = 0
    head_dx: int = 0
    head_dy: int = 0
    sway: int = 0
    flipper: str = "rest"  # rest | lift | raised | droop
    blink: bool = False
    horn: int = 0


def pose_for(kind, index):
    """The pose of frame `index` of `kind` (react-right reuses react-left)."""
    if kind == "react-left":
        # A poke from the left: lean 1 px and blink on the hit, then settle back
        # upright with the tail kicked the other way.
        if index == 0:
            return Pose(dx=-1, sway=1, blink=True)
        return Pose(sway=-1)
    if kind == "react-double":
        # Tickle: both fins up and the horn raised; frame 1 is the 1 px hop.
        return Pose(
            dy=0 if index == 0 else -1,
            sway=0 if index == 0 else 1,
            flipper="raised",
            horn=1,
        )
    if kind == "react-drag":
        # Held up: 2 px off the foot line, head tipped forward, fins hanging,
        # the hanging body swinging 1 px between the two frames.
        return Pose(
            dx=0 if index == 0 else -1,
            dy=-2,
            head_dx=-1,
            head_dy=1,
            sway=1 if index == 0 else -1,
            flipper="droop",
        )
    # State animations: the body stays on the baseline, the head lifts 1 px on
    # frame 1 (breathing) and the tail sways.
    head_dy = 0 if index == 0 else -1
    sway = 0 if index == 0 else (1 if kind != "working" else -1)
    return Pose(
        head_dy=head_dy,
        sway=sway,
        flipper="lift" if kind == "working" and index == 1 else "rest",
    )


def near_flipper(style):
    """The pectoral fin on camera: at rest, lifted a little, up, or hanging."""
    if style == "raised":
        # Up off the chest and out front, clear of the tusk's outline.
        return ellipse(4.6, 20.6, 3.0, 1.6) | ellipse(2.8, 19.4, 1.6, 1.2)
    if style == "droop":
        # Hanging from the chest down past the belly while the pet is held up.
        return polygon([(5, 23), (8, 24), (7, 28), (5, 27)])
    if style == "lift":
        return ellipse(8.0, 23.4, 2.8, 1.8)
    return ellipse(8.0, 24.4, 2.8, 1.8)


def far_flipper(style):
    """The far fin peeks over the back, only while both fins are up."""
    if style != "raised":
        return set()
    return ellipse(20.8, 13.2, 2.4, 1.6)


# -------------------------------------------------------------- character ---

def tail_mask(sway=0):
    """Two-lobe whale fluke on the right; `sway` moves the tips left/right."""
    s = sway
    upper = polygon([(23, 19), (27 + s, 14), (29 + s, 15), (27, 22)])
    lower = polygon([(23, 24), (27 + s, 27), (29 + s, 26), (27, 22)])
    return upper | lower


def tusk_pixels(horn=0, down=False):
    """Ivory horn, one pixel column at a time: 2 px at the base, 1 px at the tip.

    `horn` lifts the tip by extra pixels (a tickle swings the horn up), leaving
    the base where it grows out of the forehead, so the horn tilts rather than
    floats.
    """
    out = []
    for i in range(7):
        x = 7 - i
        tip_lift = horn if i >= 3 else 0
        base_y = 17 + i if down else 17 - i - tip_lift
        for t in range(2 if i < 4 else 1):
            out.append((x, base_y + t))
    return out


def render_frame(kind, index):
    """One 32x32 RGBA frame. `kind` in ALL_ANIMS, `index` 0/1.

    State frames keep the body on the baseline while the head (and with it the
    hat, tusk, eye and head spots) lifts 1 px on frame 1; the tail sways.
    Reaction frames move the whole character (lean, hop, hang) as `pose_for`
    describes. `react-right` is the `react-left` pose mirrored about `anchor.x`
    (16 px), so a poke from the right is a true mirror, not a second drawing.
    """
    flip = kind == "react-right"
    pose = pose_for("react-left" if flip else kind, index)
    dx, dy = pose.dx, pose.dy
    head_x, head_y = dx + pose.head_dx, dy + pose.head_dy

    frame = blank()
    torso = shift(ellipse(16.0, 21.0, 9.4, 5.8), dx, dy)
    head = shift(ellipse(11.5, 19.5, 6.2, 5.7), head_x, head_y)
    tail = shift(tail_mask(pose.sway), dx, dy)
    root = shift(polygon([(23, 19), (26, 20), (26, 24), (23, 25)]), dx, dy)
    near = shift(near_flipper(pose.flipper), dx, dy)
    far = shift(far_flipper(pose.flipper), dx, dy)
    body = torso | head | tail | root | near | far

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
    belly = shift(ellipse(12.5, 23.0, 5.2, 3.0), dx, dy) & body
    for x, y in belly:
        put(frame, x, y, BELLY)
    for x, y in belly:
        if (x, y + 1) not in body:
            put(frame, x, y, BELLY_SHADE)

    # ---- pectoral fin shaded onto the silhouette, and the far fin that a
    # tickle lifts over the back. No ink line: both are part of the outline.
    for x, y in near & body:
        put(frame, x, y, BODY_SHADE if (x, y + 1) not in near else BODY_MID)
    for x, y in far & body:
        put(frame, x, y, BODY_SHADE if (x, y + 1) not in far else BODY_MID)

    # ---- mottled spots on the back.
    for x, y in ((14, 16), (16, 17), (13, 18)):
        if (x + dx, y + head_y) in body:
            put(frame, x + dx, y + head_y, SPOT)

    # ---- tusk: a solid ivory horn from the forehead, up-left (idle/thinking)
    # or down-left (working), with faint cross bands for the spiral.
    tusk = shift(set(tusk_pixels(pose.horn, down=kind == "working")), head_x, head_y)
    for x, y in outline_of(tusk):
        put(frame, x, y, OUTLINE)
    for x, y in tusk:
        put(frame, x, y, TUSK_SHADE if (x + y) % 5 == 0 else TUSK)

    # ---- face: one 2x2 eye with a shine, squashed to a 2 px line on a blink.
    eye_x, eye_y = 10 + head_x, 16 + head_y
    if pose.blink:
        for dxx in (0, 1):
            put(frame, eye_x + dxx, eye_y + 1, EYE)
    else:
        for ddx, ddy in ((0, 0), (1, 0), (0, 1), (1, 1)):
            put(frame, eye_x + ddx, eye_y + ddy, EYE)
        put(frame, eye_x, eye_y, EYE_SHINE)

    # ---- Santa hat: white brim, red cone, white pom-pom; baked every frame and
    # riding the head (so it lifts, leans and hangs with it).
    cone = shift(polygon([(8, 12), (16, 12), (16, 4)]), head_x, head_y)
    for x, y in outline_of(cone):
        put(frame, x, y, OUTLINE)
    for x, y in cone:
        put(frame, x, y, HAT_RED)
    for x, y in cone:
        if (x + 1, y) not in cone or (x, y + 1) not in cone:
            put(frame, x, y, HAT_DARK)
        elif (x - 1, y) not in cone:
            put(frame, x, y, HAT_LIGHT)
    brim = shift(ellipse(12.0, 13.0, 4.9, 1.4), head_x, head_y)
    for x, y in outline_of(brim):
        put(frame, x, y, OUTLINE)
    for x, y in brim:
        put(frame, x, y, TRIM)
    for x, y in brim:
        if (x, y + 1) not in brim:
            put(frame, x, y, TRIM_SHADE)
    pom = shift(ellipse(16.2, 3.6, 1.9, 1.6), head_x, head_y)
    for x, y in outline_of(pom):
        put(frame, x, y, OUTLINE)
    for x, y in pom:
        put(frame, x, y, TRIM)
    for x, y in pom:
        if (x, y + 1) not in pom:
            put(frame, x, y, TRIM_SHADE)

    # ---- per-state props (off the body; never inside contentBox).
    if kind == "thinking":
        d = head_y
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

    if flip:
        frame = [row[::-1] for row in frame]
    return frame


def sheet(kind):
    img = Image.new("RGBA", (64, 32), CLEAR)
    for i in range(2):
        frame = Image.new("RGBA", (32, 32), CLEAR)
        frame.putdata([p for row in render_frame(kind, i) for p in row])
        img.paste(frame, (i * 32, 0))
    return img


# ------------------------------------------------------------------- pack ---

def animation(name, ms, loop):
    """One animation block: two 32x32 cells, `ms` per frame, looping or one-shot."""
    return {
        "sheet": f"{name}.png",
        "frameW": 32,
        "frameH": 32,
        "cols": 2,
        "box": {"x": 0, "y": 0, "w": 32, "h": 32},
        "loop": loop,
        "frames": [{"i": 0, "ms": ms}, {"i": 1, "ms": ms}],
    }


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
            **{name: animation(name, FRAME_MS, True) for name in ANIMS},
            **{name: animation(name, ms, False) for name, ms in REACTIONS.values()},
        },
        "states": {"idle": ["idle"], "working": ["working"], "thinking": ["thinking"]},
        "reactions": {key: name for key, (name, _) in REACTIONS.items()},
    }


# ------------------------------------------------------------------ output ---

def write_fixture(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name in ALL_ANIMS:
        sheet(name).save(os.path.join(out_dir, f"{name}.png"))
    with open(os.path.join(out_dir, "pack.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(pack_json(), f, ensure_ascii=False, indent=2)
        f.write("\n")


def write_zip(zip_path, out_dir):
    os.makedirs(os.path.dirname(os.path.abspath(zip_path)) or ".", exist_ok=True)
    names = ["pack.json", *(f"{name}.png" for name in ALL_ANIMS)]
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(os.path.join(out_dir, name), "rb") as f:
                zf.writestr(info, f.read())


def write_preview(preview_path, out_dir):
    """3x2 nearest-neighbour contact sheet at 8x.

    Row 1: idle frames 0/1. Row 2: one frame of each reaction, i.e. the left
    poke (frame 0), its mirror on the right, the tickle hop (frame 1) and the
    drag hang (frame 0).
    """
    os.makedirs(os.path.dirname(os.path.abspath(preview_path)) or ".", exist_ok=True)
    picks = [
        ("idle", 0),
        ("idle", 1),
        ("react-left", 0),
        ("react-right", 0),
        ("react-double", 1),
        ("react-drag", 0),
    ]
    cell = 32 * 8
    cols = 3
    rows = 2
    cells = []
    for name, index in picks:
        with Image.open(os.path.join(out_dir, f"{name}.png")) as sheet_img:
            cells.append(sheet_img.convert("RGBA").crop((index * 32, 0, index * 32 + 32, 32)))
    bg = Image.new("RGBA", (cols * cell, rows * cell), (20, 32, 42, 255))
    for i, art in enumerate(cells):
        scaled = art.resize((cell, cell), Image.NEAREST)
        # Composite the transparent cell over the backdrop instead of punching
        # its transparent pixels through it.
        bg.paste(scaled, ((i % cols) * cell, (i // cols) * cell), scaled)
    for x in range(1, cols):  # thin lines separating the cells
        for p in range(rows * cell):
            bg.putpixel((x * cell, p), (60, 86, 98, 255))
    for y in range(1, rows):
        for p in range(cols * cell):
            bg.putpixel((p, y * cell), (60, 86, 98, 255))
    bg.save(preview_path)
    return preview_path


def main(argv=None):
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        default=os.path.join(repo_root, "app", "test", "fixtures", "pets", "xmas-narwhal"),
        help="directory for pack.json and the seven sheets (default: the test fixture)",
    )
    parser.add_argument("--zip", help="also write an importable zip (pack.json + PNGs at its root)")
    parser.add_argument("--preview", help="also write a 3x2 nearest-neighbour preview PNG (8x)")
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
