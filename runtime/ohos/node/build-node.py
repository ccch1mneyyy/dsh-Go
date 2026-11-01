#!/usr/bin/env python3
"""Build the pinned Node 24.22.1 source as an OpenHarmony arm64 shared library."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile


HERE = Path(__file__).resolve().parent
SOURCE_SHA256 = '4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def apply_patches(source):
    pins = json.loads((HERE / 'node24-ohos-pins.json').read_text())
    for name, pin in pins.items():
        if digest(source / name) != pin['before']:
            raise RuntimeError(f'Node input SHA256 mismatch: {name}')
    subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(HERE / 'node24-ohos.diff')],
                   cwd=source, check=True)
    for name, pin in pins.items():
        if digest(source / name) != pin['after']:
            raise RuntimeError(f'Node patched SHA256 mismatch: {name}')
    return pins


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path)
    parser.add_argument('--source-archive', required=True, type=Path)
    parser.add_argument('--host-node', required=True, type=Path,
                        help='Official Node 24.22.1 binary executable on the Linux build host')
    parser.add_argument('--work', required=True, type=Path, help='Fresh build directory')
    parser.add_argument('--output', required=True, type=Path, help='Fresh artifact directory')
    parser.add_argument('--host-cc', default='gcc')
    parser.add_argument('--host-cxx', default='g++')
    parser.add_argument('--jobs', default=4, type=int)
    args = parser.parse_args()
    sdk, archive, node, work, output = (p.resolve() for p in
        (args.sdk_native, args.source_archive, args.host_node, args.work, args.output))
    if sys.platform != 'linux':
        parser.error('This reproducible recipe currently supports a Linux build host')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    required = [sdk / 'llvm/bin' / name for name in
                ['clang', 'clang++', 'llvm-ar', 'llvm-readelf', 'llvm-strip']]
    required += [sdk / 'oh-uni-package.json', sdk / 'sysroot/usr/include/stdio.h']
    for file in required:
        if not file.is_file():
            parser.error(f'Missing SDK input: {file}')
    for file in [HERE / 'patch-undici.mjs', HERE / 'build-tools/node_modules/esbuild/package.json']:
        if not file.is_file():
            parser.error(f'Missing O7a input: {file}; apply O7a and install its locked build tools first')
    if work.exists() or output.exists():
        parser.error('--work and --output must be fresh; an interrupted build is kept for diagnosis')
    if subprocess.check_output([str(node), '--version'], text=True).strip() != 'v24.22.1':
        parser.error('--host-node must be Node 24.22.1')
    if digest(archive) != SOURCE_SHA256:
        parser.error('Source archive must be official node-v24.22.1.tar.xz with the pinned SHA256')
    for command in [args.host_cc, args.host_cxx, 'make', 'patch']:
        if shutil.which(command) is None:
            parser.error(f'Missing host build tool: {command}')
    work.parent.mkdir(parents=True, exist_ok=True)
    free_bytes = shutil.disk_usage(work.parent).free
    with tarfile.open(archive, 'r:xz') as source_tar:
        unpacked_bytes = sum(member.size for member in source_tar.getmembers() if member.isfile())
    if free_bytes < unpacked_bytes:
        parser.error(f'Source alone requires {unpacked_bytes} bytes; only {free_bytes} are free. Build objects need additional space.')
    work.mkdir(parents=True)
    output.mkdir(parents=True)
    with tarfile.open(archive, 'r:xz') as source_tar:
        source_tar.extractall(work, filter='data')
    source = work / 'node-v24.22.1'
    pins = apply_patches(source)
    with (work / 'undici-build.log').open('w') as log:
        subprocess.run([str(node), str(HERE / 'patch-undici.mjs'), str(source)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)

    wrappers = work / 'toolchain'
    wrappers.mkdir()
    for name in ['clang', 'clang++']:
        command = [str(sdk / 'llvm/bin' / name), '--target=aarch64-linux-ohos',
                   f'--sysroot={sdk / "sysroot"}', '-fPIC',
                   '-D__OHOS__=1', '-D__MUSL__=1', '-DDSH_GO_EMBEDDED_RUNTIME=1',
                   f'-ffile-prefix-map={source}=/node-v24.22.1']
        if name == 'clang++':
            command.append('-stdlib=libc++')
        wrapper = wrappers / name
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(command) + ' "$@"\n')
        wrapper.chmod(0o755)
    recipe = {
        'CC': str(wrappers / 'clang'), 'CC_target': str(wrappers / 'clang'),
        'CXX': str(wrappers / 'clang++'), 'CXX_target': str(wrappers / 'clang++'),
        'LINK_target': str(wrappers / 'clang++'), 'AR': str(sdk / 'llvm/bin/llvm-ar'),
        'AR_target': str(sdk / 'llvm/bin/llvm-ar'), 'CC_host': args.host_cc,
        'CXX_host': args.host_cxx, 'LINK_host': args.host_cxx, 'AR_host': 'ar',
        'LDFLAGS': '-Wl,-Bsymbolic-functions', 'LDFLAGS_host': '',
        'CFLAGS': '', 'CXXFLAGS': '', 'CPPFLAGS': '',
        'CFLAGS_host': '', 'CXXFLAGS_host': '', 'CPPFLAGS_host': '',
        'SOURCE_DATE_EPOCH': '0', 'LC_ALL': 'C', 'TZ': 'UTC',
    }
    environment = {**os.environ, **recipe}
    configure =[sys.executable, 'configure.py', '--dest-os=openharmony', '--dest-cpu=arm64',
                 '--cross-compiling', '--shared', '--use_clang', '--with-intl=small-icu',
                 '--with-icu-locales=root,en', '--v8-options=--jitless',
                 '--without-node-snapshot', '--without-node-code-cache',
                 '--without-node-options', '--without-inspector']
    plan ={'configure': configure, 'make': ['make', f'-j{args.jobs}'], 'environment': recipe,
            'nodeSourceSha256': SOURCE_SHA256, 'patches': pins,
            'diskFreeBefore': free_bytes, 'sourceUncompressedBytes': unpacked_bytes,
            'sdkManifest': json.loads((sdk / 'oh-uni-package.json').read_text()),
            'sdkManifestSha256': digest(sdk / 'oh-uni-package.json'),
            'compilerSha256': digest(sdk / 'llvm/bin/clang'),
            'compilerVersion': subprocess.check_output([str(sdk / 'llvm/bin/clang'), '--version'], text=True),
            'hostCompilerVersion': subprocess.check_output([args.host_cxx, '--version'], text=True)}
    (work / 'build-plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    with (work / 'configure.log').open('w') as log:
        subprocess.run(configure, cwd=source, env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    config_text = (source / 'config.gypi').read_text()
    config = json.loads('\n'.join(line for line in config_text.splitlines() if not line.startswith('#')))['variables']
    for key, expected in {'target_arch': 'arm64', 'node_shared': 'true',
                          'node_target_type': 'shared_library', 'shlib_suffix': 'so',
                          'node_use_sqlite': 'true', 'node_use_openssl': 'true',
                          'node_shared_zstd': 'false', 'icu_small': 'true',
                          'node_v8_options': '--jitless'}.items():
        if config.get(key) != expected:
            raise RuntimeError(f'Unexpected Node configuration: {key}={config.get(key)!r}')
    with (work / 'make.log').open('w') as log:
        subprocess.run(plan['make'], cwd=source, env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    library = source / 'out/Release/libnode.so'
    if not library.is_file():
        library = source / 'out/Release/lib.target/libnode.so'
    readelf = sdk / 'llvm/bin/llvm-readelf'
    elf = subprocess.check_output([str(readelf), '-h', '-l', '-d', str(library)], text=True)
    if ('AArch64' not in elf or 'DYN (Shared object file)' not in elf or 'INTERP' in elf
            or re.search(r'SONAME.*\[libnode\.so\]', elf) is None):
        raise RuntimeError('libnode must be AArch64 ET_DYN, no PT_INTERP, SONAME libnode.so')
    unstripped = {'bytes': library.stat().st_size, 'sha256': digest(library)}
    shutil.copyfile(library, output / 'libnode.so')
    subprocess.run([str(sdk / 'llvm/bin/llvm-strip'), '--strip-unneeded', str(output / 'libnode.so')], check=True)
    cxx_runtime = Path(subprocess.check_output([str(wrappers / 'clang++'),
                       '-print-file-name=libc++_shared.so'], text=True).strip())
    if not cxx_runtime.is_absolute() or not cxx_runtime.is_file():
        raise RuntimeError('SDK compiler could not resolve libc++_shared.so; do not package an incomplete runtime')
    shutil.copyfile(cxx_runtime, output / 'libc++_shared.so')
    shutil.copyfile(source / 'LICENSE', output / 'NODE-LICENSE.txt')
    plan.update({'scope': 'OHOS cross-build; HAP load and device behavior NOT_RUN',
                 'unstripped': unstripped, 'elf': elf,
                 'artifacts': {p.name: {'bytes': p.stat().st_size, 'sha256': digest(p)}
                               for p in output.iterdir() if p.is_file()}})
    (output / 'build.json').write_text(json.dumps(plan, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'artifacts': plan['artifacts']}, indent=2))


if __name__ == '__main__':
    main()
