#!/usr/bin/env python3
"""Compare Android source/recipe and execute both real patchers on all vendor inputs.

To avoid duplicating a large npm tree, the real target patchers receive private
copies of every file mentioned by either target's pins. Unaffected files keep
their original complete-prefix inventory. This is an exact logical tree proof,
not a claim that a new Android image or a second full npm tree was built.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[3]

# Exact reviewed main/tip/OH plumbing differences, never a directory exemption.
APPROVED_SOURCE_DIFFERENCES = {'app/pubspec.yaml': {'main': {'mode': 420,
                               'kind': 'file',
                               'bytes': 9327,
                               'sha256': '13f53f113f4364adddc9ed37273f045074d7a9714b6f5562593552a465dfd6c1'},
                      'tipSHA256': '4bee91734bf7782b037e7249ae7eff4ceef2c40724c2388d3ae0b436084637bd',
                      'candidate': {'mode': 420,
                                    'kind': 'file',
                                    'bytes': 9327,
                                    'sha256': '525c152eb091d35552c309b94abbfb0901930a9d982537c891ca6f9f7323254a'}},
 'runtime/build-runtime.sh': {'main': {'mode': 493,
                                       'kind': 'file',
                                       'bytes': 30566,
                                       'sha256': 'e544ad161dd3abce4c535c1e2863fb3875b40853b0f7b52693875e2dd269afe4'},
                              'tipSHA256': 'f18e3023a2287335702c8a47f33815752f76577ee2d5cc3601a51c4dc192b214',
                              'candidate': {'mode': 493,
                                            'kind': 'file',
                                            'bytes': 30615,
                                            'sha256': 'f18e3023a2287335702c8a47f33815752f76577ee2d5cc3601a51c4dc192b214'}},
 'runtime/lib/rtbuild.py': {'main': {'mode': 420,
                                     'kind': 'file',
                                     'bytes': 85020,
                                     'sha256': '904e61535a38a9a4464ab56f9ae444af538b91251f06bc73280fa35481bb972e'},
                            'tipSHA256': '384725b33f59e83076bb181f6db540646ae76cf40d6410ebda37eb97f4956286',
                            'candidate': {'mode': 420,
                                          'kind': 'file',
                                          'bytes': 91043,
                                          'sha256': '3b31f7d71574300ac8984597d264cc98ad65a345621cf6119bb326a536212917'}},
 'runtime/lib/android_recipe.py': {'main': None,
                                   'tipSHA256': '4246d329dfbafc92906a5aa4dac3efa2d0f2bd4af43b15506d6f81597ada5d46',
                                   'candidate': {'mode': 420,
                                                 'kind': 'file',
                                                 'bytes': 3797,
                                                 'sha256': '4246d329dfbafc92906a5aa4dac3efa2d0f2bd4af43b15506d6f81597ada5d46'}},
 'runtime/locks/android-recipe-compat.json': {'main': None,
                                              'tipSHA256': '582da6af2c1abfb04ae6512ae9eb2a865e8cbd14ddb12b65dd7678dd36d06b03',
                                              'candidate': {'mode': 420,
                                                            'kind': 'file',
                                                            'bytes': 1170,
                                                            'sha256': '3be2d1bf4ec5bd4b18fb0154fcd7c0f341de4f766c4e717ab98853f5e9e079ca'}},
 'runtime/session-deletion/generate.py': {'main': {'mode': 420,
                                                   'kind': 'file',
                                                   'bytes': 14969,
                                                   'sha256': '44aab75244ef5035d58ba2e03f4976fee514bf531bf7ca5abe5f854f889991a7'},
                                          'tipSHA256': '3464c520c643eba3ae5fb88ceac803b8b5852ee4ba40c5bb1333d35ccd8a62b1',
                                          'candidate': {'mode': 420,
                                                        'kind': 'file',
                                                        'bytes': 15066,
                                                        'sha256': '3464c520c643eba3ae5fb88ceac803b8b5852ee4ba40c5bb1333d35ccd8a62b1'}}}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')


def inventory(root):
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            item = {'mode': stat.S_IMODE(info.st_mode)}
            if path.is_symlink():
                item.update(kind='symlink', target=os.readlink(path))
            elif path.is_dir():
                item['kind'] = 'directory'
            else:
                assert path.is_file()
                data = path.read_bytes()
                item.update(kind='file', bytes=len(data), sha256=sha(data))
            result[relative] = item
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'unpatched-prefix', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    baseline, prefix, out = args.baseline.resolve(), args.unpatched_prefix.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    protected = ['app/android', 'runtime/bridge', 'runtime/boot', 'runtime/direct', 'runtime/session-deletion', 'runtime/locks']
    sources = []
    observed_differences = {}
    def check_sources(scope, before, after):
        for rel in sorted(set(before) | set(after)):
            if before.get(rel) == after.get(rel):
                continue
            full = scope + '/' + rel if scope else rel
            approved = APPROVED_SOURCE_DIFFERENCES.get(full)
            assert approved is not None, 'Unreviewed protected source change: ' + full
            assert before.get(rel) == approved['main'] and after.get(rel) == approved['candidate'], 'Reviewed source identity drift: ' + full
            observed_differences[full] = approved
    for name in protected:
        before, after = inventory(baseline / name), inventory(ROOT / name)
        check_sources(name, before, after)
        sources.append({'path': name, 'baselineEntries': len(before), 'candidateEntries': len(after),
                        'baselineInventorySha256': sha(json.dumps(before, sort_keys=True).encode()),
                        'candidateInventorySha256': sha(json.dumps(after, sort_keys=True).encode())})
    def file_item(path):
        try:
            info = path.lstat()
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(info.st_mode):
            return {'kind': 'symlink', 'mode': stat.S_IMODE(info.st_mode), 'target': os.readlink(path)}
        assert stat.S_ISREG(info.st_mode), 'Protected source must be a regular file: ' + str(path)
        data = path.read_bytes()
        return {'kind': 'file', 'mode': stat.S_IMODE(info.st_mode), 'bytes': len(data), 'sha256': sha(data)}
    for name in ['app/pubspec.yaml', 'runtime/build-runtime.sh', 'runtime/lib/rtbuild.py', 'runtime/lib/android_recipe.py']:
        before, after = file_item(baseline / name), file_item(ROOT / name)
        check_sources('', {name: before}, {name: after})
        sources.append({'path': name, 'baseline': before, 'candidate': after})
    # A later authoritative baseline may already contain all reviewed plumbing.
    assert not observed_differences or set(observed_differences) == set(APPROVED_SOURCE_DIFFERENCES), 'Reviewed difference set changed'
    save(out / 'protected-source.json', sources)
    save(out / 'approved-source-differences.json', observed_differences)

    adapter = load('real_android_target_adapter', ROOT / 'runtime/tests/ohos/current-android-targets.py')
    selected = {}
    paths = set()
    commands = []
    targets = {}
    for name, tree in [('before', baseline), ('after', ROOT)]:
        pins, names, selected[name], identity, legacy = adapter.android_inputs(tree)
        if name == 'after': assert not legacy
        for patch in pins['patches'].values():
            paths.update(patch['0.2.2-rc.1'])
        targets[name] = {'tree': tree, 'identity': identity, 'legacy': legacy, 'names': names}
    assert selected['before'] == selected['after'], 'Android target inputs changed'
    assert sha((prefix / 'package-lock.json').read_bytes()) == sha((ROOT / 'runtime/locks/dsh-0.2.2-rc.1/package-lock.json').read_bytes())
    original = inventory(prefix)
    save(out / 'original-full-tree.json', original)
    logical_trees = {}
    for name, target in targets.items():
        sparse = out / (name + '-vendor-inputs')
        sparse.mkdir()
        for relative in sorted(paths):
            file = sparse / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(prefix / relative, file)
        argv, legacy = adapter.patch_argv(target['tree'], sparse, 'android',
                                          out / (name + '-patches.json'), out / (name + '-target.json'))
        result = subprocess.run(argv, capture_output=True, text=True)
        (out / (name + '.stdout.log')).write_text(result.stdout)
        (out / (name + '.stderr.log')).write_text(result.stderr)
        commands.append({'argv': argv, 'exitCode': result.returncode})
        save(out / 'commands.json', commands)
        result.check_returncode()
        changed = {path: item for path, item in inventory(sparse).items() if item['kind'] != 'directory'}
        logical_trees[name] = {**original, **changed}
        save(out / (name + '-actual-patched-files.json'), changed)
        assert json.loads((out / (name + '-patches.json')).read_text()) == target['names']
        if not legacy:
            assert json.loads((out / (name + '-target.json')).read_text())['inputSha256'] == target['identity']
    assert logical_trees['before'] == logical_trees['after'], 'Android target logical trees differ'
    save(out / 'logical-target-tree.json', logical_trees['after'])

    recipe = load('actual_shell_recipe', ROOT / 'runtime/tests/ohos/android-recipe-compat.test.py')
    fixtures = out / 'identical-external-fixtures'
    fixtures.mkdir()
    for name in ('base', 'node', 'python', 'proot', 'talloc', 'shmem', 'extra1', 'extra2'):
        (fixtures / name).write_text('identical external fixture ' + name + '\n')
    cases = []
    for abi in ('x86_64', 'arm64-v8a'):
        before = recipe.run_recipe(baseline / 'runtime', fixtures, abi, stream=True)
        after = recipe.run_recipe(ROOT / 'runtime', fixtures, abi, stream=True)
        old_suffix = recipe.run_recipe(baseline / 'runtime', fixtures, abi)
        new_suffix = recipe.run_recipe(ROOT / 'runtime', fixtures, abi)
        assert all(value.returncode == 0 for value in [before, after, old_suffix, new_suffix])
        assert before.stdout == after.stdout and old_suffix.stdout == new_suffix.stdout
        assert new_suffix.stdout.decode().strip() == sha(after.stdout)[:12]
        (out / (abi + '-recipe-inputs.txt')).write_bytes(after.stdout)
        cases.append({'abi': abi, 'inputBytes': len(after.stdout), 'inputSha256': sha(after.stdout),
                      'versionSuffix': new_suffix.stdout.decode().strip()})
    assert inventory(prefix) == original, 'Read-only pristine source changed'
    save(out / 'report.json', {'scope': __doc__, 'passed': True, 'protectedSourceUnchangedExceptReviewed': True,
        'approvedSourceDifferences': sorted(observed_differences), 'baselineLegacySchema1': targets['before']['legacy'],
        'androidTargetInputSha256': targets['after']['identity'], 'actualVendorInputFiles': len(paths),
        'logicalTargetTreeEntries': len(logical_trees['after']),
        'logicalTargetTreeSha256': sha((out / 'logical-target-tree.json').read_bytes()),
        'recipeExternalInputs': 'same synthetic archive bytes for both real shell recipe executions; no APK/rootfs build',
        'recipe': cases})
    print(json.dumps({'passed': True, 'vendorInputs': len(paths), 'recipe': cases}))


if __name__ == '__main__':
    main()
