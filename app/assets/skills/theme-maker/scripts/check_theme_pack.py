#!/usr/bin/env python3
"""Checks a dsh-Go theme pack archive against the app's import gates.

    python3 check_theme_pack.py my-theme.zip
    python3 check_theme_pack.py my-theme.zip --market   # Workshop submission

It mirrors the checks the phone runs on import: the ZIP layout and budgets
(pet_archive.dart), strict JSON, the schema 1/2 theme.json fields
(theme_pack.dart), referenced PNG/font assets and their caps
(theme_pack_validator.dart), and the optional bundled pet (`pet.zip` + the
pet.id contract), validated by the pet rules (pet_pack_validator.dart).
Exit codes: 0 all checks pass, 1 problems found, 2 the archive cannot be read.

Standard library only: no network, no phone, no Flutter. A PASS here means the
app will accept the pack; it is not a substitute for looking at it once.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import re
import stat
import struct
import sys
import unicodedata
import zipfile
import zlib
from dataclasses import dataclass, field
from urllib.parse import urlsplit

# Limits from app/lib/pets/pet_pack_rules.g.dart and theme_pack_validator.dart.
ARCHIVE_CAP = 64 * 1024 * 1024
ARCHIVE_EXPANDED_CAP = 64 * 1024 * 1024
ARCHIVE_ENTRY_CAP = 256
THEME_JSON_CAP = 128 * 1024
IMAGE_CAP = 8 * 1024 * 1024
FONT_CAP = 16 * 1024 * 1024
TOTAL_ASSET_CAP = 32 * 1024 * 1024
IMAGE_SIDE_CAP = 4096
IMAGE_DECODED_CAP = 16 * 1024 * 1024
THEME_SCHEMA_MAX = 2
PET_JSON_CAP = 256 * 1024
PET_SHEET_CAP = 8 * 1024 * 1024
PET_SHEET_COUNT_CAP = 64
PET_TOTAL_SHEET_CAP = 48 * 1024 * 1024
PET_SIDE_CAP = 4096
PET_DECODED_CAP = 16 * 1024 * 1024
PET_MEMBER_CAP = ARCHIVE_CAP

WORKSHOP_LICENSES = frozenset({
    'CC0-1.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'MIT', 'Apache-2.0',
    'BSD-2-Clause', 'BSD-3-Clause', 'LicenseRef-Author-Permission',
})

THEME_ID_RE = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
HEX_COLOR_RE = re.compile(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
ASSET_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')
USER_PET_ID_RE = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
PNG_SIG = b'\x89PNG\r\n\x1a\n'

COLOR_TOKENS = (
    'backdropTop', 'backdropBottom', 'glowPrimary', 'glowSecondary',
    'surface', 'onSurface', 'onSurfaceVariant', 'outline', 'outlineVariant',
    'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
    'userBubble', 'onUserBubble', 'assistantBubble', 'onAssistantBubble',
    'codeWellBg', 'codeWellHeader', 'codeWellFg', 'codeWellBorder',
)
PALETTE_KEYS = ('seed', 'seedDark', 'tintHue', 'tintChroma', 'glowOpacity', 'light', 'dark')
PALETTE_NUMBERS = {'tintHue': (0, 360), 'tintChroma': (0, 2), 'glowOpacity': (0, 1)}
SURFACE_PRESETS = ('glass', 'paper', 'flat', 'outlined')
SURFACE_KEYS = ('preset', 'chromeBlur', 'sheetBlur', 'cardOpacity', 'pillOpacity',
                'hairlineWidth', 'rimOpacity', 'shadowOpacity', 'backdropImage',
                'backdropOpacity', 'backdropRepeat')
SURFACE_NUMBERS = {
    'chromeBlur': (0, 40), 'sheetBlur': (0, 40), 'cardOpacity': (0, 1),
    'pillOpacity': (0, 1), 'hairlineWidth': (0, 3), 'rimOpacity': (0, 1),
    'shadowOpacity': (0, 1), 'backdropOpacity': (0, 1),
}
BUILT_IN_FONTS = frozenset({'system', 'serif', 'mono', 'JetBrainsMono', 'monospace'})
TYPOGRAPHY_KEYS = ('uiFont', 'readingFont', 'headingFont', 'codeFont',
                   'readingScale', 'readingLineHeight', 'headingScale')
TYPOGRAPHY_NUMBERS = {'readingScale': (0.85, 1.25), 'readingLineHeight': (1.2, 2.0),
                      'headingScale': (0.85, 1.35)}
SHAPE_NUMBERS = {'cornerScale': (0, 1.6), 'borderWidth': (0, 2.5), 'turnGap': (12, 40),
                 'inTurnGap': (4, 20), 'gutter': (10, 28)}
COMPONENT_ENUMS = {
    'headerStyle': ('glass', 'ghost', 'outlined', 'minimal'),
    'composerStyle': ('floatingGlass', 'solidPaper', 'outlined'),
    'sendButtonStyle': ('primary', 'ink', 'tonal'),
    'userBubbleStyle': ('soft', 'outlined', 'accent', 'minimal'),
    'assistantStyle': ('plain', 'card', 'leftRule'),
    'suggestionCardStyle': ('glass', 'paper', 'outlined', 'minimal'),
    'codeBlockStyle': ('well', 'outlined', 'card'),
}
COMPONENT_BOOLS = ('useReadingFontForReply',)
EMPTY_ENUMS = {
    'layout': ('centered', 'editorial', 'compact'),
    'heroStyle': ('whale', 'badge', 'customImage', 'hidden'),
    'suggestionsDisplay': ('expanded', 'collapsible', 'grid'),
}
EMPTY_BOOLS = ('useReadingFontForGreeting', 'showConnectedSubtitle')
TOP_KEYS = (
    'schema', 'id', 'name', 'title', 'description', 'tags', 'author', 'license',
    'source', 'palette', 'surfaces', 'typography', 'shapes', 'components',
    'emptyState', 'pet',
)


@dataclass(frozen=True)
class Problem:
    """One stable failure: the same code the app's validator uses."""

    code: str
    detail: str | None = None

    def __str__(self) -> str:
        return self.code if self.detail is None else f'{self.code}: {self.detail}'


class _Stop(Exception):
    """A failure that ends validation, as the app stops at the first one."""

    def __init__(self, code: str, detail: str | None = None):
        super().__init__(code)
        self.problem = Problem(code, detail)


class _Schema(Exception):
    """A theme.json field problem; the caller reports it as theme-schema."""


@dataclass
class ThemeInfo:
    schema: int
    id: str
    pet_id: str | None = None
    pet_name: str | None = None
    images: set = field(default_factory=set)
    fonts: set = field(default_factory=set)


# --------------------------------------------------------------------------- #
# Small shared helpers


def _is_num(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _only_keys(raw: dict, allowed, path: str) -> None:
    for key in raw:
        if not isinstance(key, str) or key not in allowed:
            raise _Schema(f'{path}.{key} is not supported')


def _text(value, cap: int, path: str) -> str:
    if not isinstance(value, str):
        raise _Schema(f'{path} must be a string')
    if not value.strip():
        raise _Schema(f'{path} must not be blank')
    if len(value) > cap:
        raise _Schema(f'{path} must be at most {cap} characters')
    for ch in value:
        cp = ord(ch)
        if cp < 32 or 0xD800 <= cp <= 0xDFFF:
            raise _Schema(f'{path} contains a control character or unpaired surrogate')
    return value


def _safe_asset(value, extensions, path: str) -> str:
    if not isinstance(value, str) or not ASSET_NAME_RE.fullmatch(value) or '..' in value:
        raise _Schema(f'{path} must be a plain filename')
    if not any(value.lower().endswith(ext) for ext in extensions):
        raise _Schema(f'{path} must end with {" or ".join(extensions)}')
    return value


def _color(value, path: str) -> None:
    if value is None:
        return
    if not isinstance(value, str) or not HEX_COLOR_RE.fullmatch(value.strip()):
        raise _Schema(f'{path} must be #RRGGBB or #AARRGGBB')


def _bounded_map(raw: dict, ranges: dict, path: str) -> None:
    for key, (low, high) in ranges.items():
        value = raw.get(key)
        if value is not None and (not _is_num(value) or value < low or value > high):
            raise _Schema(f'{path}.{key} must be between {low:g} and {high:g}')


def _enum(raw: dict, key: str, values, path: str) -> None:
    value = raw.get(key)
    if value is not None and (not isinstance(value, str) or value not in values):
        raise _Schema(f'{path}.{key} is invalid')


def _boolean(raw: dict, key: str, path: str) -> None:
    value = raw.get(key)
    if value is not None and not isinstance(value, bool):
        raise _Schema(f'{path}.{key} must be a boolean')


def pet_name_alias(name: str) -> str:
    return unicodedata.normalize('NFC', name).casefold()


def user_pet_id_for(pack_id: str) -> str:
    """The on-disk id a pet pack is installed under (pet_ids.dart)."""
    bare = pack_id[len('user-'):] if pack_id.startswith('user-') else pack_id
    if len(bare) <= 48 and USER_PET_ID_RE.fullmatch(bare):
        return 'user-' + bare
    slug = re.sub(r'[^a-z0-9]+', '-', bare.lower()).strip('-')
    if len(slug) > 32:
        slug = slug[:32].rstrip('-')
    digest = hashlib.sha256(pack_id.encode('utf-8')).hexdigest()[:8]
    return f'user-{slug or "pet"}-{digest}'


def _float32(value: float) -> float:
    return struct.unpack('<f', struct.pack('<f', value))[0]


# --------------------------------------------------------------------------- #
# Strict JSON (app/lib/pets/pet_json.dart)


def _json_depth(value, depth: int = 0) -> int:
    if isinstance(value, dict):
        return max([depth] + [_json_depth(v, depth + 1) for v in value.values()])
    if isinstance(value, list):
        return max([depth] + [_json_depth(v, depth + 1) for v in value])
    return depth


def _has_surrogate(value) -> bool:
    if isinstance(value, str):
        return any(0xD800 <= ord(ch) <= 0xDFFF for ch in value)
    if isinstance(value, dict):
        return any(_has_surrogate(k) or _has_surrogate(v) for k, v in value.items())
    if isinstance(value, list):
        return any(_has_surrogate(v) for v in value)
    return False


def decode_json(data: bytes, cap: int, size_code: str) -> object:
    """Strict UTF-8 JSON: no BOM, duplicate keys, NaN/Infinity or isolated surrogates."""
    if len(data) > cap:
        raise _Stop(size_code)
    if data.startswith(b'\xef\xbb\xbf'):
        raise _Stop('json-bom')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        raise _Stop('json-syntax') from None

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise _Stop('json-duplicate-key', key)
            result[key] = value
        return result

    def non_finite(_token):
        raise _Stop('json-number')

    def finite_float(token):
        value = float(token)
        if not math.isfinite(value):
            raise _Stop('json-number')
        return value

    try:
        value = json.loads(text, object_pairs_hook=pairs,
                           parse_constant=non_finite, parse_float=finite_float)
    except json.JSONDecodeError:
        raise _Stop('json-syntax') from None
    if _has_surrogate(value):
        raise _Stop('json-unicode')
    if _json_depth(value) > 64:
        raise _Stop('json-depth')
    return value


# --------------------------------------------------------------------------- #
# ZIP structure (app/lib/pets/pet_archive.dart)


def _check_entry_name(name: str) -> None:
    parts = name.rstrip('/').split('/')
    if (not name or name.startswith('/') or '\\' in name or '\x00' in name or
            any(part == '' or part in ('.', '..') or ':' in part for part in parts)):
        raise _Stop('archive-path', name)


def open_archive(data: bytes) -> zipfile.ZipFile:
    if len(data) > ARCHIVE_CAP:
        raise _Stop('archive-size')
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
        infos = archive.infolist()
    except (zipfile.BadZipFile, OSError, ValueError):
        raise _Stop('archive-invalid') from None
    if len(infos) > ARCHIVE_ENTRY_CAP:
        raise _Stop('archive-entries')
    aliases: set[str] = set()
    expanded = 0
    for info in infos:
        name = info.filename
        _check_entry_name(name)
        alias = pet_name_alias(name)
        if alias in aliases:
            raise _Stop('archive-duplicate', name)
        aliases.add(alias)
        mode = info.external_attr >> 16
        kind = mode & 0o170000
        is_dir = name.endswith('/')
        if kind and kind not in (stat.S_IFREG, stat.S_IFDIR):
            raise _Stop('archive-type', name)
        if (kind == stat.S_IFDIR) != is_dir and kind:
            raise _Stop('archive-type', name)
        if info.flag_bits & 0x1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise _Stop('archive-encoding', name)
        expanded += info.file_size
        if expanded > ARCHIVE_EXPANDED_CAP:
            raise _Stop('archive-expanded-size', name)
    return archive


def read_member(archive: zipfile.ZipFile, path: str, cap: int) -> bytes | None:
    """Reads one member under a byte budget; None when it is not in the archive."""
    try:
        info = archive.getinfo(path)
    except KeyError:
        return None
    if info.is_dir() or info.file_size > cap:
        raise _Stop('archive-member-size', path)
    try:
        data = archive.read(info)
    except zipfile.BadZipFile:
        raise _Stop('archive-member-crc', path) from None
    except (zipfile.LargeZipFile, OSError, ValueError, zlib.error):
        raise _Stop('archive-member-invalid', path) from None
    if len(data) > cap:
        raise _Stop('archive-member-size', path)
    return data


# --------------------------------------------------------------------------- #
# PNG and font assets (app/lib/pets/pet_png.dart, theme_pack_validator.dart)


def _png_intact(data: bytes) -> bool:
    if len(data) < 33 or not data.startswith(PNG_SIG):
        return False
    pos = 8
    first = True
    saw_idat = saw_iend = saw_plte = False
    idat = bytearray()
    width = height = 0
    bit_depth = color_type = interlace = 0
    while pos < len(data):
        if pos + 12 > len(data):
            return False
        length, ctype = struct.unpack('>I4s', data[pos:pos + 8])
        if pos + 12 + length > len(data):
            return False
        body = data[pos + 8:pos + 8 + length]
        crc = struct.unpack('>I', data[pos + 8 + length:pos + 12 + length])[0]
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc:
            return False
        if ctype == b'IHDR':
            if not first or length != 13:
                return False
            width, height = struct.unpack('>II', body[:8])
            bit_depth, color_type, compression, filtering, interlace = body[8:13]
            legal = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                     4: (8, 16), 6: (8, 16)}
            if color_type not in legal or bit_depth not in legal[color_type]:
                return False
            if compression != 0 or filtering != 0 or interlace not in (0, 1):
                return False
        elif ctype == b'PLTE':
            saw_plte = True
            if saw_idat or length == 0 or length % 3 or length > 256 * 3:
                return False
        elif ctype == b'IDAT':
            saw_idat = True
            idat += body
        elif ctype == b'IEND':
            saw_iend = True
            if length != 0 or pos + 12 != len(data):
                return False
        elif ctype in (b'acTL', b'fcTL', b'fdAT'):
            return False  # APNG is not accepted as a still theme image.
        elif ctype != b'tRNS' and ctype[0] & 0x20 == 0:
            return False  # unknown critical chunk
        first = False
        pos += 12 + length
    if not (saw_idat and saw_iend and width and height):
        return False
    if color_type == 3 and not saw_plte:
        return False

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    bits_per_pixel = channels * bit_depth
    passes = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
              (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
    if interlace == 0:
        expected = height * (1 + (width * bits_per_pixel + 7) // 8)
    else:
        expected = 0
        for x0, y0, dx, dy in passes:
            pw = 0 if width <= x0 else (width - x0 + dx - 1) // dx
            ph = 0 if height <= y0 else (height - y0 + dy - 1) // dy
            if pw and ph:
                expected += ph * (1 + (pw * bits_per_pixel + 7) // 8)
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error:
        return False
    if len(raw) != expected:
        return False
    cursor = 0
    for x0, y0, dx, dy in passes[:1] if interlace == 0 else passes:
        pw = width if interlace == 0 else (0 if width <= x0 else (width - x0 + dx - 1) // dx)
        ph = height if interlace == 0 else (0 if height <= y0 else (height - y0 + dy - 1) // dy)
        if not (pw and ph):
            continue
        stride = 1 + (pw * bits_per_pixel + 7) // 8
        for row in range(ph):
            if raw[cursor + row * stride] > 4:
                return False
        cursor += ph * stride
    return True


def png_problems(data: bytes, name: str, side_cap: int = IMAGE_SIDE_CAP,
                 decoded_cap: int = IMAGE_DECODED_CAP) -> list[Problem]:
    if len(data) < 24 or not data.startswith(PNG_SIG) or data[12:16] != b'IHDR':
        return [Problem('theme-png-header', name)]
    width, height = struct.unpack('>II', data[16:24])
    if not (1 <= width <= side_cap and 1 <= height <= side_cap) or width * height * 4 > decoded_cap:
        return [Problem('theme-png-dimensions', name)]
    if not _png_intact(data):
        return [Problem('theme-png-corrupt', name)]
    return []


def font_problems(data: bytes, name: str) -> list[Problem]:
    if len(data) < 12 or len(data) > FONT_CAP:
        return [Problem('theme-font-invalid', name)]
    if data[:4] in (b'\x00\x01\x00\x00', b'OTTO', b'true'):
        return []
    return [Problem('theme-font-invalid', name)]


# --------------------------------------------------------------------------- #
# theme.json schema 1/2 (app/lib/themes/theme_pack.dart)


def _parse_theme(raw: dict) -> ThemeInfo:
    for key in raw:
        if not isinstance(key, str) or key not in TOP_KEYS:
            raise _Schema(f'Unknown theme.json field: {key}')

    schema = raw.get('schema')
    if not (isinstance(schema, int) and not isinstance(schema, bool)):
        raise _Schema('theme.json schema must be 1 or 2')
    if schema > THEME_SCHEMA_MAX:
        raise _Stop('theme-schema-version', f'theme.json schema {schema} is newer than {THEME_SCHEMA_MAX}')
    if schema < 1:
        raise _Schema('theme.json schema must be 1 or 2')

    pet = raw.get('pet')
    pet_id = pet_name = None
    if pet is not None:
        if not isinstance(pet, dict):
            raise _Schema('theme.json pet must be an object')
        for key in pet:
            if key not in ('id', 'name'):
                raise _Schema(f'theme.json pet.{key} is not supported')
        candidate = pet.get('id')
        if not (isinstance(candidate, str) and candidate.startswith('user-') and len(candidate) <= 64 and
                USER_PET_ID_RE.fullmatch(candidate[len('user-'):])):
            raise _Schema('theme.json pet.id must be an installed user pet id (user-…)')
        pet_id = candidate
        if pet.get('name') is not None:
            pet_name = _text(pet['name'], 120, 'theme.json pet.name')
        if schema != 2:
            raise _Schema('theme.json pet requires schema 2')

    theme_id = raw.get('id')
    if not (isinstance(theme_id, str) and len(theme_id) <= 40 and THEME_ID_RE.fullmatch(theme_id)):
        raise _Schema('theme.json id must be lower-case kebab-case up to 40 chars')
    _text(raw.get('name'), 120, 'theme.json name')

    title = raw.get('title')
    if title is not None:
        if not isinstance(title, dict):
            raise _Schema('theme.json title must be an object')
        for key in title:
            if key not in ('zh', 'en'):
                raise _Schema(f'theme.json title.{key} is not supported')
        for key in ('zh', 'en'):
            if title.get(key) is not None:
                _text(title[key], 120, f'theme.json title.{key}')

    description = raw.get('description')
    if description not in (None, ''):
        _text(description, 512, 'theme.json description')

    tags = raw.get('tags')
    if tags is not None:
        if not isinstance(tags, list) or len(tags) > 8:
            raise _Schema('theme.json tags must be a list of up to 8 strings')
        seen: set[str] = set()
        for tag in tags:
            _text(tag, 32, 'theme.json tag')
            if tag in seen:
                raise _Schema('theme.json tags must be unique')
            seen.add(tag)

    for key, cap in (('author', 256), ('license', 100), ('source', 2048)):
        if raw.get(key) is not None:
            _text(raw[key], cap, f'theme.json {key}')
    source = raw.get('source')
    if source is not None:
        parts = urlsplit(source)
        if (re.search(r'\s', source) or parts.scheme != 'https' or not parts.hostname or
                '@' in parts.netloc):
            raise _Schema('theme.json source must be a valid https URL')

    info = ThemeInfo(schema=schema, id=theme_id, pet_id=pet_id, pet_name=pet_name)
    _parse_palette(raw.get('palette'))
    _parse_surfaces(raw.get('surfaces'), info)
    _parse_typography(raw.get('typography'), info)
    _parse_shapes(raw.get('shapes'))
    _parse_components(raw.get('components'))
    _parse_empty_state(raw.get('emptyState'), info)
    return info


def _parse_palette(raw) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('palette must be an object')
    _only_keys(raw, PALETTE_KEYS, 'palette')
    _color(raw.get('seed'), 'palette.seed')
    _color(raw.get('seedDark'), 'palette.seedDark')
    _bounded_map(raw, PALETTE_NUMBERS, 'palette')
    for mode in ('light', 'dark'):
        overrides = raw.get(mode)
        if overrides is None:
            continue
        if not isinstance(overrides, dict):
            raise _Schema(f'palette.{mode} must be an object')
        for key in overrides:
            if key not in COLOR_TOKENS:
                raise _Schema(f'palette.{mode}.{key} is not a supported color token')
        for key in overrides:
            _color(overrides[key], f'palette.{mode}.{key}')


def _parse_surfaces(raw, info: ThemeInfo) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('surfaces must be an object')
    _only_keys(raw, SURFACE_KEYS, 'surfaces')
    _enum(raw, 'preset', SURFACE_PRESETS, 'surfaces')
    _bounded_map(raw, SURFACE_NUMBERS, 'surfaces')
    if raw.get('backdropImage') is not None:
        info.images.add(_safe_asset(raw['backdropImage'], ('.png',), 'surfaces.backdropImage'))
    _boolean(raw, 'backdropRepeat', 'surfaces')


def _parse_typography(raw, info: ThemeInfo) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('typography must be an object')
    _only_keys(raw, TYPOGRAPHY_KEYS, 'typography')
    for key in ('uiFont', 'readingFont', 'headingFont', 'codeFont'):
        value = raw.get(key)
        if value is None:
            continue
        if not isinstance(value, str):
            raise _Schema(f'typography.{key} must be a string')
        if value in BUILT_IN_FONTS:
            continue
        if (not ASSET_NAME_RE.fullmatch(value) or '..' in value or
                not value.lower().endswith(('.ttf', '.otf'))):
            raise _Schema(f'typography.{key} must be system, serif, mono, or a local .ttf/.otf filename')
        info.fonts.add(value)
    _bounded_map(raw, TYPOGRAPHY_NUMBERS, 'typography')
    if len(info.fonts) > 2:
        raise _Schema('typography may reference at most 2 bundled font files')


def _parse_shapes(raw) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('shapes must be an object')
    _only_keys(raw, tuple(SHAPE_NUMBERS), 'shapes')
    _bounded_map(raw, SHAPE_NUMBERS, 'shapes')


def _parse_components(raw) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('components must be an object')
    _only_keys(raw, (*COMPONENT_ENUMS, *COMPONENT_BOOLS), 'components')
    for key, values in COMPONENT_ENUMS.items():
        _enum(raw, key, values, 'components')
    for key in COMPONENT_BOOLS:
        _boolean(raw, key, 'components')


def _parse_empty_state(raw, info: ThemeInfo) -> None:
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise _Schema('emptyState must be an object')
    _only_keys(raw, (*EMPTY_ENUMS, 'heroImage', *EMPTY_BOOLS), 'emptyState')
    for key, values in EMPTY_ENUMS.items():
        _enum(raw, key, values, 'emptyState')
    for key in EMPTY_BOOLS:
        _boolean(raw, key, 'emptyState')
    hero = raw.get('heroImage')
    if hero is not None:
        info.images.add(_safe_asset(hero, ('.png',), 'emptyState.heroImage'))
    if raw.get('heroStyle') == 'customImage' and hero is None:
        raise _Schema('emptyState.heroImage is required when heroStyle is customImage')


# --------------------------------------------------------------------------- #
# Bundled pet: pet.zip + the pet.id contract


def _parse_pet_pack(raw: dict) -> tuple[str, str | None, set[str], list[tuple]]:
    """The pet pack's (id, name, sheets, animations), under the pet rules an import applies."""

    def bad(message: str):
        raise _Schema(message)

    if raw.get('schema') != 1:
        bad('pack.json: schema must be 1')
    pack_id = raw.get('id')
    if not isinstance(pack_id, str) or not pack_id:
        bad('pack.json: id must be a non-empty string')
    pet_name = raw.get('name') if isinstance(raw.get('name'), str) else None

    canvas = raw.get('canvas')
    if not isinstance(canvas, dict) or not all(_is_num(canvas.get(k)) and canvas[k] > 0 for k in ('w', 'h')):
        bad('pack.json: canvas needs numeric w and h greater than 0')

    def rect(value) -> bool:
        return (isinstance(value, dict) and
                all(_is_num(value.get(k)) for k in ('x', 'y', 'w', 'h')) and
                value['w'] > 0 and value['h'] > 0)

    if not rect(raw.get('contentBox')):
        bad('pack.json: contentBox needs numeric x, y, w, h with positive w and h')

    animations = raw.get('animations')
    if not isinstance(animations, dict) or not animations:
        bad('pack.json: animations must be a non-empty object')
    sheets: set[str] = set()
    geometry: list[tuple] = []
    for name, animation in animations.items():
        if not isinstance(animation, dict):
            bad(f'pack.json: animation {name} must be an object')
        sheet = animation.get('sheet')
        if not isinstance(sheet, str) or not sheet:
            bad(f'pack.json: animation {name} needs a sheet filename')
        sheets.add(sheet)
        for key in ('frameW', 'frameH', 'cols'):
            value = animation.get(key)
            if not (_is_num(value) and value > 0 and value == round(value)):
                bad(f'pack.json: animation {name} needs a positive whole {key}')
        if not rect(animation.get('box')):
            bad(f'pack.json: animation {name} needs a box')
        frames = animation.get('frames')
        if not isinstance(frames, list):
            bad(f'pack.json: animation {name} needs a frames list')
        kept = [f for f in frames if isinstance(f, dict) and _is_num(f.get('i')) and _is_num(f.get('ms'))]
        if not kept or any(f['i'] < 0 or f['ms'] <= 0 for f in kept):
            bad(f'pack.json: frames of {name} are invalid')
        geometry.append((name, sheet, int(animation['frameW']), int(animation['frameH']),
                         int(animation['cols']), max(int(f['i']) for f in kept)))

    states = raw.get('states')
    if not isinstance(states, dict):
        bad('pack.json: states must be an object')
    for key, names in states.items():
        for anim in (names if isinstance(names, list) else []):
            if anim not in animations:
                bad(f'pack.json: states.{key} refers to unknown animation {anim}')
    if not isinstance(states.get('idle'), list) or not states['idle']:
        bad('pack.json: states.idle must list at least one animation')

    # The overlay import gate (PetPack.kt / overlayPackProblem): whole numbers
    # and frameWidth/Height == trunc(Float32(Float32(box) * scale)).
    scale = raw.get('scale')
    if scale is None:
        scale = 1
    if not (_is_num(scale) and scale == round(scale) and 1 <= scale <= PET_SIDE_CAP):
        bad('pack.json: scale must be a whole number from 1 to 4096')
    scale = int(scale)
    for key in ('w', 'h'):
        if canvas[key] != round(canvas[key]) or canvas[key] > 1 << 30:
            bad('pack.json: canvas must be whole numbers')
    for name, animation in animations.items():
        for key in ('frameW', 'frameH', 'cols'):
            if animation[key] > PET_SIDE_CAP:
                bad(f'pack.json: animation {name} {key} must be at most 4096')
        for frame in animation['frames']:
            if not isinstance(frame, dict):
                bad(f'pack.json: frames of {name} must be objects')
            for key in ('i', 'ms'):
                value = frame.get(key)
                if not (_is_num(value) and value == round(value) and value <= 1 << 30):
                    bad(f'pack.json: frames of {name} must have whole i and ms')
            if frame.get('ms', 0) <= 0:
                bad(f'pack.json: frames of {name} must have ms > 0')
        for axis, field_name in (('w', 'frameW'), ('h', 'frameH')):
            expected = int(_float32(_float32(animation['box'][axis]) * scale))
            if expected != int(animation[field_name]):
                bad(f'pack.json: {field_name} of {name} must equal box.{axis} × scale')

    reactions = raw.get('reactions')
    for key, names in (reactions if isinstance(reactions, dict) else {}).items():
        for anim in (names if isinstance(names, list) else [names]):
            if anim not in animations:
                bad(f'pack.json: reactions.{key} refers to unknown animation {anim}')
    roam = raw.get('roam')
    if isinstance(roam, dict) and roam.get('anim') is not None and roam['anim'] not in animations:
        bad(f'pack.json: roam.anim refers to unknown animation {roam["anim"]}')
    return pack_id, pet_name, sheets, geometry


def _check_pet(outer: zipfile.ZipFile, prefix: str, pet_id: str | None) -> list[Problem]:
    pet_path = prefix + 'pet.zip'
    has_member = pet_path in outer.namelist()
    if pet_id is None:
        return [Problem('theme-pet-unexpected', 'pet.zip')] if has_member else []
    if not has_member:
        return [Problem('theme-pet-missing', 'pet.zip')]
    try:
        pet_bytes = read_member(outer, pet_path, PET_MEMBER_CAP)
    except _Stop as error:
        code = 'theme-pet-too-large' if error.problem.code == 'archive-member-size' else 'theme-pet-archive'
        return [Problem(code, 'pet.zip')]
    if pet_bytes is None:
        return [Problem('theme-pet-missing', 'pet.zip')]

    try:
        inner = zipfile.ZipFile(io.BytesIO(pet_bytes))
    except (zipfile.BadZipFile, OSError, ValueError):
        return [Problem('theme-pet-archive', 'pet.zip')]

    problems: list[Problem] = []
    try:
        infos = inner.infolist()
        if len(infos) > ARCHIVE_ENTRY_CAP or sum(i.file_size for i in infos) > ARCHIVE_EXPANDED_CAP:
            return [Problem('theme-pet-too-large', 'pet.zip')]
        names = [i.filename for i in infos if not i.filename.endswith('/')]
        aliases: set[str] = set()
        for name in names:
            _check_entry_name(name)
            if pet_name_alias(name) in aliases:
                return [Problem('theme-pet-archive', name)]
            aliases.add(pet_name_alias(name))

        candidates = [n for n in names if n == 'pack.json' or
                      (n.endswith('/pack.json') and len(n.split('/')) == 2)]
        if len(candidates) != 1:
            return [Problem('theme-pet-pack', 'pack.json')]
        manifest = candidates[0]
        prefix_inner = manifest[:-len('pack.json')]
        raw_bytes = read_member(inner, manifest, PET_JSON_CAP)
        if raw_bytes is None:
            return [Problem('theme-pet-pack', 'pack.json')]
        try:
            decoded = decode_json(raw_bytes, PET_JSON_CAP, 'theme-pet-too-large')
        except _Stop as error:
            return [Problem('theme-pet-pack', str(error.problem))]
        if not isinstance(decoded, dict):
            return [Problem('theme-pet-pack', 'pack.json')]
        if _json_depth(decoded) > 60:
            return [Problem('theme-pet-pack', 'pack.json: nested too deep')]
        try:
            pack_id, _, sheets, geometry = _parse_pet_pack(decoded)
        except _Schema as error:
            return [Problem('theme-pet-pack', str(error))]

        if len(sheets) > PET_SHEET_COUNT_CAP:
            problems.append(Problem('theme-pet-too-large', 'sheet-count'))
        total = 0
        sheet_pixels: dict[str, tuple[int, int]] = {}
        for sheet in sorted(sheets):
            if (not sheet or len(sheet) > 120 or len(sheet.encode('utf-8')) > 255 or
                    sheet.startswith('.') or any(c in sheet for c in ('/', '\\', '\x00')) or
                    not sheet.lower().endswith('.png')):
                problems.append(Problem('theme-pet-asset', sheet))
                continue
            try:
                sheet_bytes = read_member(inner, prefix_inner + sheet, PET_SHEET_CAP)
            except _Stop as error:
                code = 'theme-pet-too-large' if error.problem.code in (
                    'archive-size', 'archive-entries', 'archive-expanded-size', 'archive-member-size',
                ) else 'theme-pet-asset'
                problems.append(Problem(code, sheet))
                continue
            if not sheet_bytes:
                problems.append(Problem('theme-pet-asset', sheet))
                continue
            total += len(sheet_bytes)
            if total > PET_TOTAL_SHEET_CAP:
                problems.append(Problem('theme-pet-too-large', 'sheet-total-size'))
            problems.extend(png_problems(sheet_bytes, sheet, PET_SIDE_CAP, PET_DECODED_CAP))
            if sheet_bytes.startswith(PNG_SIG) and len(sheet_bytes) >= 24:
                sheet_pixels[sheet] = struct.unpack('>II', sheet_bytes[16:24])

        # Every frame of every animation must fall inside its sheet (sheet-frame-bounds).
        for name, sheet, frame_w, frame_h, cols, last in geometry:
            size = sheet_pixels.get(sheet)
            if size is None:
                continue  # already reported as a sheet problem
            width, height = size
            if frame_w <= 0 or frame_h <= 0 or cols <= 0:
                continue
            if cols > width // frame_w or (last // cols + 1) > height // frame_h:
                problems.append(Problem('theme-pet-asset', f'sheet-frame-bounds: {name}'))

        expected = user_pet_id_for(pack_id)
        if pet_id != expected:
            problems.append(Problem('theme-pet-id', f'{pet_id} != {expected}'))
        return problems
    finally:
        inner.close()


# --------------------------------------------------------------------------- #
# Top level


def validate_bytes(data: bytes, *, market: bool = False) -> list[Problem]:
    """Checks an archive held in memory, the way the app's import does."""
    return validate_report(data, market=market)[0]


def validate_report(data: bytes, *, market: bool = False) -> tuple[list[Problem], dict]:
    problems: list[Problem] = []
    summary: dict = {}
    try:
        archive = open_archive(data)
        try:
            names = [i.filename for i in archive.infolist() if not i.filename.endswith('/')]
            candidates = [name for name in names if name == 'theme.json' or
                          (name.endswith('/theme.json') and len(name.split('/')) == 2)]
            if len(candidates) != 1:
                raise _Stop('archive-theme-count')
            manifest = candidates[0]
            prefix = manifest[:-len('theme.json')]
            raw_bytes = read_member(archive, manifest, THEME_JSON_CAP)
            if raw_bytes is None:
                raise _Stop('archive-theme-count')
            decoded = decode_json(raw_bytes, THEME_JSON_CAP, 'archive-member-size')
            if not isinstance(decoded, dict):
                raise _Stop('theme-json-object')
            try:
                info = _parse_theme(decoded)
            except _Schema as error:
                raise _Stop('theme-schema', str(error)) from None

            if market:
                missing = [key for key in ('author', 'license', 'source')
                           if decoded.get(key) is None]
                if missing or decoded.get('license') not in WORKSHOP_LICENSES:
                    raise _Stop('theme-metadata')

            referenced = info.images | info.fonts
            aliases: dict[str, str] = {}
            for name in sorted(referenced):
                alias = pet_name_alias(name)
                if alias in aliases:
                    problems.append(Problem('theme-asset-alias', name))
                aliases[alias] = name

            total = 0
            for name in sorted(referenced):
                try:
                    member = read_member(archive, prefix + name, min(
                        IMAGE_CAP if name in info.images else FONT_CAP, TOTAL_ASSET_CAP - total))
                except _Stop as error:
                    code = ('theme-asset-too-large'
                            if error.problem.code == 'archive-member-size' else error.problem.code)
                    problems.append(Problem(code, name))
                    continue
                if member is None:
                    problems.append(Problem('theme-asset-missing', name))
                    continue
                if not member:
                    problems.append(Problem('theme-asset-too-large', name))
                    continue
                total += len(member)
                if total > TOTAL_ASSET_CAP:
                    problems.append(Problem('theme-asset-total-size'))
                    continue
                if name in info.images:
                    problems.extend(png_problems(member, name))
                else:
                    problems.extend(font_problems(member, name))

            problems.extend(_check_pet(archive, prefix, info.pet_id))
            summary = {
                'schema': info.schema,
                'assets': len(referenced),
                'images': len(info.images),
                'fonts': len(info.fonts),
                'pet': info.pet_id is not None,
            }
        finally:
            archive.close()
    except _Stop as error:
        problems.append(error.problem)
    return problems, summary


def validate_file(path: str, *, market: bool = False) -> tuple[list[Problem], dict]:
    with open(path, 'rb') as handle:
        data = handle.read()
    return validate_report(data, market=market)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Check a dsh-Go theme pack (.zip) before importing it on the phone.')
    parser.add_argument('pack', help='theme pack zip')
    parser.add_argument('--market', action='store_true',
                        help='also require author/license/source as a Workshop submission does')
    args = parser.parse_args(argv)
    try:
        problems, summary = validate_file(args.pack, market=args.market)
    except OSError as error:
        print(f'cannot read {args.pack}: {error}', file=sys.stderr)
        return 2
    if problems:
        print(f'FAIL {args.pack} ({len(problems)} problem(s))')
        for problem in problems:
            print(f'  {problem}')
        return 1
    pet = ', with bundled pet' if summary.get('pet') else ''
    print(f'PASS {args.pack} (schema {summary.get("schema")}, {summary.get("assets", 0)} '
          f'referenced asset(s): {summary.get("images", 0)} image(s) + '
          f'{summary.get("fonts", 0)} font(s){pet})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
