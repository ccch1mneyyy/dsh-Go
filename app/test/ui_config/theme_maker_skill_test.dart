// The theme-maker skill: one bundle for appearance theme packs, pet packs and
// theme packs that carry a pet. Its files ship flat in
// assets/skills/theme-maker/ and land under references/ + scripts/ in the skill
// folder, so the agent on the host can read and run them. The pet scripts must
// stay identical to app/tool; the second test fails when one is edited without
// re-copying.

import 'dart:io';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String _path(List<String> segments) => segments.join('/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundle: manifest maps SKILL.md, both references and all six scripts', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    expect(bundle.name, themeMakerSkillName);
    expect(bundle.files.keys, containsAll([
      'SKILL.md',
      _path(['references', 'appearance-theme.md']),
      _path(['references', 'pet-pack.md']),
      _path(['scripts', 'check_theme_pack.py']),
      _path(['scripts', 'make_theme_pack.py']),
      _path(['scripts', 'pet_theme_convert.py']),
      _path(['scripts', 'pet_pack_check.py']),
      _path(['scripts', 'make_pet_pack.py']),
      _path(['scripts', 'pet_svg_frames.py']),
    ]));
    expect(bundle.writeOrder.last.key, 'SKILL.md');
    expect(isManagedUiSkill(bundle.skillMd), isTrue);
    expect(bundle.skillMd, contains('name: theme-maker'));
  });

  test('SKILL.md routes the three products and their import paths', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    final skill = bundle.skillMd;
    // The three decision branches: look-only, pet-only, both.
    expect(skill, contains('外观主题包'));
    expect(skill, contains('宠物包'));
    expect(skill, contains('带配套宠物的主题包'));
    // The combined branch names the contract it has to satisfy.
    expect(skill, contains('pet.zip'));
    expect(skill, contains('schema **2**'));
    // Each branch points at the script and the on-phone import path.
    expect(skill, contains('check_theme_pack.py'));
    expect(skill, contains('pet_pack_check.py'));
    expect(skill, contains('设置 › 外观 › 导入主题包'));
    expect(skill, contains('设置 › 宠物 › 导入'));
    // Boundaries: data packages, not app changes.
    expect(skill, contains('不改 App 代码'));
    expect(skill, contains('不执行代码'));
  });

  test('the references carry the field tables and the pet contract', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    final theme = bundle.files[_path(['references', 'appearance-theme.md'])]!;
    expect(theme, contains('schema'));
    expect(theme, contains('#AARRGGBB'));
    expect(theme, contains('theme-asset-missing'));
    expect(theme, contains('pet.zip'));
    expect(theme, contains('userPetIdFor'));
    final pet = bundle.files[_path(['references', 'pet-pack.md'])]!;
    expect(pet, contains('pack.json'));
    expect(pet, contains('frameW'));
    expect(pet, contains('reactions'));
    expect(pet, contains('states.idle'));
  });

  test('the shipped pet scripts are the app/tool originals, not forks', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    for (final name in ['pet_theme_convert.py', 'pet_pack_check.py', 'make_pet_pack.py', 'pet_svg_frames.py']) {
      expect(
        bundle.files[_path(['scripts', name])],
        File(_path(['tool', name])).readAsStringSync(),
        reason: 'app/tool/$name changed: copy it to assets/skills/theme-maker/scripts/$name',
      );
    }
  });

  test('the new scripts are real validators/builders, not stubs', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    final check = bundle.files[_path(['scripts', 'check_theme_pack.py'])]!;
    expect(check, contains('def validate_bytes'));
    expect(check, contains('def user_pet_id_for'));
    expect(check, contains("if __name__ == '__main__':"));
    final make = bundle.files[_path(['scripts', 'make_theme_pack.py'])]!;
    expect(make, contains('def build('));
    expect(make, contains('--pet'));
    expect(make, contains('check.validate_bytes'));
  });

  test('installs into the engine home with its references and scripts', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, themeMakerSkillName);
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.installed);
    final installed = Directory([root.path, 'root', '.dsh', 'skills', themeMakerSkillName].join('/'));
    expect(File([installed.path, 'SKILL.md'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'references', 'appearance-theme.md'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'references', 'pet-pack.md'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'scripts', 'check_theme_pack.py'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'scripts', 'make_theme_pack.py'].join('/')).existsSync(), isTrue);
    expect(File([installed.path, 'scripts', 'pet_pack_check.py'].join('/')).existsSync(), isTrue);
  });
}
