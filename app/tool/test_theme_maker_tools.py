#!/usr/bin/env python3
"""Checks the theme-maker scripts against synthetic theme packs.

Run from app/ (standard library only, unlike test_pet_theme_convert.py):

    python3 app/tool/test_theme_maker_tools.py

No real artwork is used: 16x16 flat-colour PNGs built here exercise the asset
checks. The scripts live in the skill bundle (app/assets/skills/theme-maker/
scripts/) and are the ones installed on the phone, so this drives the same
files a user gets.
"""
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), 'assets', 'skills', 'theme-maker', 'scripts')
sys.path.insert(0, SCRIPTS)

import check_theme_pack as C  # noqa: E402
import make_theme_pack as M  # noqa: E402

CHECK = os.path.join(SCRIPTS, 'check_theme_pack.py')
MAKE = os.path.join(SCRIPTS, 'make_theme_pack.py')


def _chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)


def png(width=16, height=16, rgba=(80, 160, 240, 255)):
    """A valid, opaque RGBA PNG."""
    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    row = b'\x00' + bytes(rgba) * width
    return (b'\x89PNG\r\n\x1a\n' + _chunk(b'IHDR', header) +
            _chunk(b'IDAT', zlib.compress(row * height)) + _chunk(b'IEND', b''))


def zip_bytes(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def theme_zip(theme, files=None):
    files = files or {}
    return zip_bytes({'theme.json': json.dumps(theme, ensure_ascii=False).encode('utf-8'), **files})


PET_PACK = {
    'schema': 1,
    'id': 'cat',
    'name': '小猫',
    'pixelArt': True,
    'scale': 1,
    'canvas': {'w': 16, 'h': 16},
    'contentBox': {'x': 2, 'y': 2, 'w': 12, 'h': 12},
    'animations': {
        'idle': {
            'sheet': 'idle.png', 'frameW': 12, 'frameH': 12, 'cols': 1,
            'box': {'x': 2, 'y': 2, 'w': 12, 'h': 12},
            'frames': [{'i': 0, 'ms': 100}],
        },
    },
    'states': {'idle': ['idle']},
}


def pet_zip():
    return zip_bytes({'pack.json': json.dumps(PET_PACK, ensure_ascii=False).encode('utf-8'),
                      'idle.png': png()})


def codes(problems):
    return [problem.code for problem in problems]


class CheckThemePackTest(unittest.TestCase):
    def test_minimal_schema1_passes(self):
        theme = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist',
                 'palette': {'seed': '#3F6FD8'}, 'surfaces': {'preset': 'paper'}}
        self.assertEqual(C.validate_bytes(theme_zip(theme)), [])

    def test_unknown_field_is_rejected(self):
        theme = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist', 'nope': True}
        problems = C.validate_bytes(theme_zip(theme))
        self.assertEqual(codes(problems), ['theme-schema'])
        self.assertIn('Unknown theme.json field: nope', problems[0].detail)

    def test_nested_unknown_field_is_rejected(self):
        theme = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist',
                 'palette': {'seed': '#3F6FD8', 'nope': 1}}
        self.assertEqual(codes(C.validate_bytes(theme_zip(theme))), ['theme-schema'])

    def test_bad_colour_is_rejected(self):
        for bad in ('#ABC', 'rgb(0,0,0)', 'red', '3F6FD8', '#12345'):
            theme = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist',
                     'palette': {'seed': bad}}
            problems = C.validate_bytes(theme_zip(theme))
            self.assertEqual(codes(problems), ['theme-schema'], bad)
            self.assertIn('palette.seed', problems[0].detail)

    def test_out_of_range_and_bad_enum_are_rejected(self):
        base = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist'}
        self.assertEqual(codes(C.validate_bytes(theme_zip({**base, 'surfaces': {'preset': 'nope'}}))),
                         ['theme-schema'])
        self.assertEqual(codes(C.validate_bytes(theme_zip({**base, 'shapes': {'cornerScale': 2}}))),
                         ['theme-schema'])

    def test_missing_asset_is_reported(self):
        theme = {'schema': 1, 'id': 'ink-scroll', 'name': '墨卷',
                 'surfaces': {'backdropImage': 'bg.png'}}
        problems = C.validate_bytes(theme_zip(theme))
        self.assertEqual(codes(problems), ['theme-asset-missing'])
        self.assertEqual(problems[0].detail, 'bg.png')

    def test_valid_png_and_font_pass(self):
        theme = {'schema': 1, 'id': 'ink-scroll', 'name': '墨卷',
                 'surfaces': {'backdropImage': 'bg.png'},
                 'typography': {'readingFont': 'book.otf'}}
        archive = theme_zip(theme, {'bg.png': png(), 'book.otf': b'OTTO' + b'\x00' * 8})
        self.assertEqual(C.validate_bytes(archive), [])

    def test_truncated_png_fails(self):
        good = png()
        theme = {'schema': 1, 'id': 'ink-scroll', 'name': '墨卷',
                 'surfaces': {'backdropImage': 'bg.png'}}
        problems = C.validate_bytes(theme_zip(theme, {'bg.png': good[:len(good) // 2]}))
        self.assertEqual(codes(problems), ['theme-png-corrupt'])

    def test_jpeg_renamed_to_png_fails(self):
        theme = {'schema': 1, 'id': 'ink-scroll', 'name': '墨卷',
                 'surfaces': {'backdropImage': 'bg.png'}}
        problems = C.validate_bytes(theme_zip(theme, {'bg.png': b'\xff\xd8\xff\xe0' + b'\x00' * 64}))
        self.assertEqual(codes(problems), ['theme-png-header'])

    def test_asset_in_a_subdirectory_is_rejected_by_schema(self):
        theme = {'schema': 1, 'id': 'ink-scroll', 'name': '墨卷',
                 'surfaces': {'backdropImage': 'assets/bg.png'}}
        self.assertEqual(codes(C.validate_bytes(theme_zip(theme))), ['theme-schema'])

    def test_schema_newer_than_the_app(self):
        theme = {'schema': 3, 'id': 'future', 'name': 'Future'}
        problems = C.validate_bytes(theme_zip(theme))
        self.assertEqual(codes(problems), ['theme-schema-version'])

    def test_pet_requires_schema2(self):
        theme = {'schema': 1, 'id': 'with-pet', 'name': 'With pet',
                 'pet': {'id': 'user-cat'}}
        self.assertEqual(codes(C.validate_bytes(theme_zip(theme))), ['theme-schema'])

    def test_schema2_with_matching_pet_passes(self):
        theme = {'schema': 2, 'id': 'with-pet', 'name': 'With pet',
                 'pet': {'id': 'user-cat', 'name': '小猫'}}
        self.assertEqual(C.validate_bytes(theme_zip(theme, {'pet.zip': pet_zip()})), [])

    def test_pet_id_mismatch_fails(self):
        theme = {'schema': 2, 'id': 'with-pet', 'name': 'With pet',
                 'pet': {'id': 'user-dog'}}
        problems = C.validate_bytes(theme_zip(theme, {'pet.zip': pet_zip()}))
        self.assertEqual(codes(problems), ['theme-pet-id'])
        self.assertIn('user-dog != user-cat', problems[0].detail)

    def test_pet_member_missing_or_unexpected(self):
        with_block = {'schema': 2, 'id': 'with-pet', 'name': 'With pet',
                      'pet': {'id': 'user-cat'}}
        self.assertEqual(codes(C.validate_bytes(theme_zip(with_block))), ['theme-pet-missing'])
        without_block = {'schema': 1, 'id': 'alone', 'name': 'Alone'}
        self.assertEqual(codes(C.validate_bytes(theme_zip(without_block, {'pet.zip': pet_zip()}))),
                         ['theme-pet-unexpected'])

    def test_pet_pack_id_with_hash_still_matches(self):
        pack = {'schema': 1, 'id': '小猫', 'name': '小猫',
                'canvas': {'w': 16, 'h': 16},
                'contentBox': {'x': 2, 'y': 2, 'w': 12, 'h': 12},
                'animations': {'idle': {'sheet': 'idle.png', 'frameW': 12, 'frameH': 12,
                                        'cols': 1, 'box': {'x': 2, 'y': 2, 'w': 12, 'h': 12},
                                        'frames': [{'i': 0, 'ms': 100}]}},
                'states': {'idle': ['idle']}}
        expected = C.user_pet_id_for('小猫')
        self.assertTrue(expected.startswith('user-') and expected.endswith('-3ecbdba2'), expected)
        theme = {'schema': 2, 'id': 'with-pet', 'name': 'With pet', 'pet': {'id': expected}}
        archive = theme_zip(theme, {'pet.zip': zip_bytes({
            'pack.json': json.dumps(pack, ensure_ascii=False).encode('utf-8'),
            'idle.png': png(),
        })})
        self.assertEqual(C.validate_bytes(archive), [])

    def test_pet_frame_outside_its_sheet_fails(self):
        pack = json.loads(json.dumps(PET_PACK))
        pack['animations']['idle']['cols'] = 2  # 2 * 12px > 16px sheet
        theme = {'schema': 2, 'id': 'with-pet', 'name': 'With pet',
                 'pet': {'id': 'user-cat'}}
        archive = theme_zip(theme, {'pet.zip': zip_bytes({
            'pack.json': json.dumps(pack, ensure_ascii=False).encode('utf-8'),
            'idle.png': png(),
        })})
        problems = C.validate_bytes(archive)
        self.assertEqual(codes(problems), ['theme-pet-asset'])
        self.assertIn('sheet-frame-bounds: idle', problems[0].detail)

    def test_market_metadata(self):
        theme = {'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet Mist'}
        self.assertEqual(codes(C.validate_bytes(theme_zip(theme), market=True)), ['theme-metadata'])
        theme.update({'author': 'A', 'license': 'CC0-1.0',
                      'source': 'https://example.com/theme'})
        self.assertEqual(C.validate_bytes(theme_zip(theme), market=True), [])


class MakeThemePackTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='theme-maker-')
        self.dir = self.temp.name

    def tearDown(self):
        self.temp.cleanup()

    def path(self, name):
        return os.path.join(self.dir, name)

    def test_minimal_light_and_dark_packs_pass(self):
        for mode in ('light', 'dark'):
            out = self.path(f'{mode}.zip')
            self.assertEqual(M.main(['--id', f'{mode}-mist', '--name', f'{mode} mist',
                                     '--seed', '#3F6FD8', '--mode', mode, '--out', out]), 0)
            problems, summary = C.validate_file(out)
            self.assertEqual(problems, [])
            self.assertEqual(summary['schema'], 1)

    def test_artwork_and_font_are_referenced(self):
        background = self.path('bg.png')
        font = self.path('book.otf')
        with open(background, 'wb') as handle:
            handle.write(png(64, 32))
        with open(font, 'wb') as handle:
            handle.write(b'OTTO' + b'\x00' * 8)
        out = self.path('ink.zip')
        self.assertEqual(M.main([
            '--id', 'ink-scroll', '--name', '墨卷', '--seed', '#8A5A3C', '--mode', 'dark',
            '--backdrop', background, '--hero', background, '--font', f'readingFont={font}',
            '--out', out, '--preview', self.path('preview.html'),
        ]), 0)
        problems, summary = C.validate_file(out)
        self.assertEqual(problems, [])
        self.assertEqual((summary['images'], summary['fonts']), (1, 1))
        with open(self.path('preview.html'), encoding='utf-8') as handle:
            self.assertIn('墨卷', handle.read())

    def test_bundled_pet_makes_schema2_and_passes(self):
        pet_path = self.path('cat.zip')
        with open(pet_path, 'wb') as handle:
            handle.write(pet_zip())
        out = self.path('with-pet.zip')
        self.assertEqual(M.main([
            '--id', 'cat-theme', '--name', '小猫主题', '--seed', '#4B67B4',
            '--mode', 'light', '--pet', pet_path, '--out', out,
        ]), 0)
        problems, summary = C.validate_file(out)
        self.assertEqual(problems, [])
        self.assertTrue(summary['pet'])
        with zipfile.ZipFile(out) as archive:
            theme = json.loads(archive.read('theme.json'))
            self.assertEqual(theme['schema'], 2)
            self.assertEqual(theme['pet']['id'], 'user-cat')
            self.assertIn('pet.zip', archive.namelist())

    def test_existing_output_needs_force(self):
        out = self.path('taken.zip')
        with open(out, 'wb') as handle:
            handle.write(b'keep me')
        self.assertEqual(M.main(['--id', 'quiet-mist', '--name', 'Quiet', '--out', out]), 2)
        with open(out, 'rb') as handle:
            self.assertEqual(handle.read(), b'keep me')

    def test_bad_id_is_refused_before_writing(self):
        out = self.path('bad.zip')
        self.assertEqual(M.main(['--id', 'Bad_ID', '--name', 'Bad', '--out', out]), 1)
        self.assertFalse(os.path.exists(out))


class CheckCliTest(unittest.TestCase):
    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory(prefix='theme-maker-cli-') as temp:
            good = os.path.join(temp, 'good.zip')
            self.assertEqual(subprocess.run(
                [sys.executable, MAKE, '--id', 'quiet-mist', '--name', 'Quiet Mist',
                 '--seed', '#3F6FD8', '--out', good],
                capture_output=True, text=True).returncode, 0)
            run = subprocess.run([sys.executable, CHECK, good], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('PASS', run.stdout)

            bad = os.path.join(temp, 'bad.zip')
            with open(bad, 'wb') as handle:
                handle.write(theme_zip({'schema': 1, 'id': 'quiet-mist', 'name': 'Quiet',
                                        'palette': {'seed': '#ABC'}}))
            run = subprocess.run([sys.executable, CHECK, bad], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn('FAIL', run.stdout)
            self.assertIn('theme-schema', run.stdout)


if __name__ == '__main__':
    unittest.main()
