"""从固定官方 APK 导出原始安装资产；不执行 npm、脚本或二进制。"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import tarfile
import zipfile

APK_SHA256 = '1afb3b363ba47418291ac56c17d661dd25a7520b94901700bfd19ed82859ba17'
ROOTFS_SHA256 = 'eb5f1318a55b4663faa991ca553c335f1127b8c3f853ba04288f65a9ba18d171'
RUNTIME_VERSION = 'r12-dsh0.2.1-rc.4-node24.22.1-ubuntu24.04.5-d4f8a19ec932'
LOCK_SHA256 = '9b61c5b60c82a3b64fb252af5c142d40d0c86aff30a17cdd5e1ca9d73df9a25c'
RELEASE_URL = 'https://github.com/ccch1mneyyy/dsh-Go/releases/tag/v1.0.2'
APK_URL = 'https://github.com/ccch1mneyyy/dsh-Go/releases/download/v1.0.2/dsh-go-1.0.2-arm64.apk'


def digest(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_name(name):
    if name.startswith('./'):
        name = name[2:]
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
        raise ValueError('归档路径不安全')
    return path.as_posix()


def prepare(apk, output):
    if output.exists():
        raise ValueError('输出必须是不存在的新目录；不覆盖已有资产')
    if digest(apk) != APK_SHA256:
        raise ValueError('APK 摘要不符')
    files = {}
    links = []
    with zipfile.ZipFile(apk) as archive:
        runtime = json.loads(archive.read('assets/runtime/manifest.json'))
        if runtime['runtimeVersion'] != RUNTIME_VERSION or runtime['rootfsSha256'] != ROOTFS_SHA256:
            raise ValueError('运行时来源不符')
        rootfs = 'assets/runtime/' + safe_name(runtime['rootfs'])
        with archive.open(rootfs) as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != ROOTFS_SHA256:
                raise ValueError('rootfs 摘要不符')
        output.mkdir(parents=True)
        with archive.open(rootfs) as stream, tarfile.open(fileobj=stream, mode='r|xz') as tree:
            for member in tree:
                name = member.name.removeprefix('./')
                if not (name.startswith('opt/dsh/') or name.startswith('opt/dsh-go/dsh-go-bridge/')):
                    continue
                name = safe_name(name)
                if member.isdir():
                    continue
                if name in files or any(link['path'] == name for link in links):
                    raise ValueError('重复归档条目')
                if member.issym():
                    target = member.linkname
                    if PurePosixPath(target).is_absolute() or '\\' in target or ':' in target:
                        raise ValueError('命令目标不安全')
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                    if not name.startswith('opt/dsh/node_modules/.bin/') or '/' in name.removeprefix('opt/dsh/node_modules/.bin/'):
                        raise ValueError('非命令符号链接不受支持')
                    if not resolved.startswith('opt/dsh/node_modules/'):
                        raise ValueError('命令目标越界')
                    links.append({'path': name, 'target': target, 'resolved': resolved})
                    continue
                if not member.isfile():
                    raise ValueError('不支持硬链接或设备节点')
                destination = output.joinpath(*PurePosixPath(name).parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with tree.extractfile(member) as source, destination.open('xb') as target:
                    shutil.copyfileobj(source, target)
                files[name] = {'path': name, 'sha256': digest(destination), 'bytes': member.size}
    if len(files) != 14576 or len(links) != 12:
        raise ValueError('固定发行资产计数不符')
    commands = []
    for link in links:
        if link['resolved'] not in files:
            raise ValueError('命令目标不存在或不是普通文件')
        commands.append({'entry': link['path'], 'target': link['resolved'], 'sha256': files[link['resolved']]['sha256']})
    if digest(output / 'opt/dsh/package-lock.json') != LOCK_SHA256:
        raise ValueError('固定 npm 锁摘要不符')
    record = {'schema': 1, 'releaseUrl': RELEASE_URL, 'apkUrl': APK_URL,
              'apkSha256': APK_SHA256, 'rootfsSha256': ROOTFS_SHA256,
              'runtimeVersion': RUNTIME_VERSION, 'npmLockSha256': LOCK_SHA256,
              'files': [files[name] for name in sorted(files)],
              'commandEntries': commands, 'symlinksCreated': 0,
              'executed': False, 'nativeFilesRetainedAsInertSource': True}
    (output / 'PREPARED-SOURCE.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    (output / 'COMMAND-ENTRIES.json').write_text(json.dumps(commands, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'files': len(files), 'commandEntries': len(commands), 'symlinksCreated': 0, 'executed': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.apk.resolve(), args.output.resolve())
