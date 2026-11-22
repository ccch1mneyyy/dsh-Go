#!/usr/bin/env python3
"""Scaffolds, checks and packages a dsh-Go theme pack.

    python3 make_theme_pack.py --id ocean-mist --name "海雾" \\
        --seed "#3F6FD8" --mode light --out /tmp/ocean-mist.zip

Optional artwork, fonts and a bundled pet:

    python3 make_theme_pack.py --id ink-scroll --name "墨卷" --seed "#8A5A3C" \\
        --mode dark --out /tmp/ink-scroll.zip \\
        --backdrop texture.png --hero hero.png --font readingFont=book.otf \\
        --pet /tmp/pet-pack/cat.zip

The generated theme.json is schema 1; with --pet it becomes schema 2 and the
pet pack is embedded as `pet.zip` with `pet.id` set to the id the phone installs
it under (the same contract the app checks). Everything is validated with
check_theme_pack.py before it is written: the command fails instead of handing
out a pack the phone would reject.

--preview PATH writes a small HTML swatch preview next to the archive.
"""
from __future__ import annotations

import argparse
import html
import io
import json
import os
import re
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_theme_pack as check  # noqa: E402  (same folder when installed)

HEX_RE = re.compile(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
FONT_ROLES = ('uiFont', 'readingFont', 'headingFont', 'codeFont')


def _rgb(color: str) -> tuple[int, int, int]:
    value = color.strip()
    if not HEX_RE.fullmatch(value):
        raise ValueError(f'{color!r} is not #RRGGBB or #AARRGGBB')
    digits = value[1:]
    if len(digits) == 8:
        digits = digits[2:]  # AARRGGBB: drop alpha
    return int(digits[0:2], 16), int(digits[2:4], 16), int(digits[4:6], 16)


def _hex(rgb: tuple[int, int, int]) -> str:
    return '#%02X%02X%02X' % rgb


def _blend(rgb: tuple[int, int, int], target: tuple[int, int, int], amount: float) -> str:
    return _hex(tuple(round(a + (b - a) * amount) for a, b in zip(rgb, target)))


def _palette(seed: str, mode: str) -> dict:
    rgb = _rgb(seed)
    palette = {'seed': _hex(rgb)}
    if mode == 'dark':
        # A dark backdrop derived from the same hue, so the pack reads as one
        # design instead of "light theme with the system dark mode".
        palette['dark'] = {
            'backdropTop': _blend(rgb, (0, 0, 0), 0.90),
            'backdropBottom': _blend(rgb, (0, 0, 0), 0.86),
            'surface': _blend(rgb, (0, 0, 0), 0.82),
            'onSurface': '#F2F2F2',
        }
    else:
        palette['light'] = {
            'backdropTop': _blend(rgb, (255, 255, 255), 0.94),
            'backdropBottom': _blend(rgb, (255, 255, 255), 0.90),
            'surface': _blend(rgb, (255, 255, 255), 0.97),
        }
    return palette


def _pet_block(pet_zip: bytes) -> tuple[dict, bytes]:
    try:
        with zipfile.ZipFile(io.BytesIO(pet_zip)) as archive:
            names = [i.filename for i in archive.infolist() if not i.filename.endswith('/')]
            candidates = [n for n in names if n == 'pack.json' or
                          (n.endswith('/pack.json') and len(n.split('/')) == 2)]
            if len(candidates) != 1:
                raise ValueError('pet pack must hold exactly one pack.json at its root or in one folder')
            raw = archive.read(candidates[0])
    except zipfile.BadZipFile:
        raise ValueError('pet pack is not a zip archive') from None
    try:
        pack = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError('pet pack.json is not valid JSON') from None
    if not isinstance(pack, dict) or not isinstance(pack.get('id'), str) or not pack['id']:
        raise ValueError('pet pack.json needs a non-empty id')
    pet = {'id': check.user_pet_id_for(pack['id'])}
    if isinstance(pack.get('name'), str) and pack['name']:
        pet['name'] = pack['name']
    return pet, pet_zip


def build(args) -> tuple[dict, dict[str, bytes], bytes]:
    """Returns (theme.json object, extra members, theme.json bytes)."""
    theme: dict = {
        'schema': 1,
        'id': args.id,
        'name': args.name,
        'palette': _palette(args.seed, args.mode),
        'surfaces': {'preset': 'flat' if args.mode == 'dark' else 'glass'},
    }
    if args.title_zh or args.title_en:
        theme['title'] = {
            key: value for key, value in
            (('zh', args.title_zh), ('en', args.title_en)) if value is not None
        }
    if args.description:
        theme['description'] = args.description
    if args.tags:
        theme['tags'] = [tag for tag in (t.strip() for t in args.tags.split(',')) if tag]
    for key, value in (('author', args.author), ('license', args.license),
                       ('source', args.source)):
        if value:
            theme[key] = value

    members: dict[str, bytes] = {}
    if args.backdrop:
        name = _member_name(args.backdrop, '.png')
        members[name] = _read(args.backdrop)
        theme['surfaces']['backdropImage'] = name
        theme['surfaces']['backdropOpacity'] = 0.18
    if args.hero:
        name = _member_name(args.hero, '.png')
        members[name] = _read(args.hero)
        theme.setdefault('emptyState', {})['heroStyle'] = 'customImage'
        theme['emptyState']['heroImage'] = name
    fonts: dict[str, str] = {}
    for spec in args.font or []:
        role, _, path = spec.partition('=')
        if role not in FONT_ROLES or not path:
            raise ValueError(f'--font must be ROLE=PATH with ROLE in {", ".join(FONT_ROLES)}')
        name = _member_name(path, '.ttf', '.otf')
        members[name] = _read(path)
        fonts[role] = name
    if len(set(fonts.values())) > 2:
        raise ValueError('a theme pack may carry at most 2 custom font files')
    if fonts:
        theme['typography'] = fonts

    if args.pet:
        pet, pet_zip = _pet_block(_read(args.pet))
        theme['schema'] = 2
        theme['pet'] = pet
        members['pet.zip'] = pet_zip

    payload = json.dumps(theme, ensure_ascii=False, indent=2).encode('utf-8') + b'\n'
    return theme, members, payload


def _read(path: str) -> bytes:
    with open(path, 'rb') as handle:
        return handle.read()


def _member_name(path: str, *extensions: str) -> str:
    name = os.path.basename(path)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', name) or '..' in name:
        raise ValueError(f'{path!r} does not give a safe archive filename')
    if not name.lower().endswith(extensions):
        raise ValueError(f'{path!r} must end with {" or ".join(extensions)}')
    return name


def write_zip(path: str, theme_payload: bytes, members: dict[str, bytes], *, force: bool) -> None:
    if os.path.exists(path) and not force:
        raise ValueError(f'{path} already exists; pass --force to replace it')
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('theme.json', theme_payload)
        for name, data in members.items():
            archive.writestr(name, data)


def write_preview(path: str, theme: dict, members: dict[str, bytes]) -> None:
    palette = theme.get('palette', {})
    light = palette.get('light') or palette.get('dark') or {}
    swatches = ''.join(
        f'<div class="swatch" style="background:{html.escape(value)}">'
        f'<span>{html.escape(key)}<br>{html.escape(value)}</span></div>'
        for key, value in light.items()
    )
    texture = ' · '.join(html.escape(name) for name in members) or 'no artwork'
    page = f"""<!doctype html>
<meta charset="utf-8">
<title>{html.escape(theme['name'])} — theme pack preview</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #17181c; color: #eee; }}
  h1 {{ font-size: 1.4rem; }}
  .row {{ display: flex; gap: .75rem; flex-wrap: wrap; margin: 1rem 0; }}
  .swatch {{ min-width: 8rem; height: 5rem; border-radius: .75rem; color: #111;
             display: flex; align-items: flex-end; padding: .5rem; font-size: .7rem; }}
  .card {{ border: 1px solid #333; border-radius: 1rem; padding: 1rem; max-width: 32rem; }}
  .bubble {{ background: {html.escape(palette.get('seed', '#4B67B4'))}; color: #fff;
             border-radius: 1rem; padding: .5rem .75rem; display: inline-block; }}
</style>
<h1>{html.escape(theme['name'])} <small>({html.escape(theme['id'])}, schema {theme['schema']})</small></h1>
<div class="row">{swatches}</div>
<div class="card">
  <p>How the conversation will read with seed
    <strong>{html.escape(palette.get('seed', '#4B67B4'))}</strong>:</p>
  <p class="bubble">Show me around.</p>
  <p>Sure — try the composer, then a code block.</p>
  <pre style="background:#0d1117;color:#c9d1d9;padding:.75rem;border-radius:.5rem">print("hello")</pre>
  <p style="color:#999">Artwork: {texture}</p>
</div>
"""
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(page)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Scaffold a dsh-Go theme pack (.zip) that passes check_theme_pack.py.')
    parser.add_argument('--id', required=True, help='lower-case kebab-case id, up to 40 chars')
    parser.add_argument('--name', required=True, help='display name')
    parser.add_argument('--seed', default='#4B67B4', help='seed colour, #RRGGBB (default #4B67B4)')
    parser.add_argument('--mode', choices=('light', 'dark'), default='light',
                        help='starting mode; dark adds dark backdrop colours (default light)')
    parser.add_argument('--out', required=True, help='output .zip path')
    parser.add_argument('--title-zh')
    parser.add_argument('--title-en')
    parser.add_argument('--description')
    parser.add_argument('--tags', help='comma-separated, at most 8')
    parser.add_argument('--author')
    parser.add_argument('--license')
    parser.add_argument('--source', help='https URL')
    parser.add_argument('--backdrop', help='PNG used as the chat backdrop')
    parser.add_argument('--hero', help='PNG used as the empty-state illustration')
    parser.add_argument('--font', action='append', metavar='ROLE=PATH',
                        help=f'repeated; ROLE in {", ".join(FONT_ROLES)}')
    parser.add_argument('--pet', help='pet pack .zip to bundle (theme becomes schema 2)')
    parser.add_argument('--preview', help='write an HTML swatch preview to this path')
    parser.add_argument('--force', action='store_true', help='replace an existing --out file')
    args = parser.parse_args(argv)

    try:
        theme, members, payload = build(args)
    except (OSError, ValueError) as error:
        print(f'cannot build the pack: {error}', file=sys.stderr)
        return 2

    # Validate exactly what will be written, before writing it.
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('theme.json', payload)
        for name, data in members.items():
            archive.writestr(name, data)
    problems = check.validate_bytes(buffer.getvalue())
    if problems:
        print('FAIL: the generated pack would be rejected:')
        for problem in problems:
            print(f'  {problem}')
        return 1

    try:
        write_zip(args.out, payload, members, force=args.force)
        if args.preview:
            write_preview(args.preview, theme, members)
    except (OSError, ValueError) as error:
        print(f'cannot write the pack: {error}', file=sys.stderr)
        return 2

    print(f'PASS wrote {args.out} (schema {theme["schema"]}, {len(members)} extra member(s))')
    if args.preview:
        print(f'preview: {args.preview}')
    print('Import on the phone: Settings › Appearance › Import Theme Pack (.zip)')
    if theme['schema'] == 2:
        print('The bundled pet is installed with the theme (Settings › Pets shows it).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
