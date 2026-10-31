const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const excludedDirectories = new Set(['.dart_tool', '.git', 'build', 'oh_modules', '.hvigor', 'node_modules']);
const excludedFiles = new Set(['.flutter-plugins-dependencies', '.packages', 'BuildProfile.ets', 'oh-package-lock.json5']);
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');

function inventory(root, prefix = '') {
  const files = [];
  for (const entry of fs.readdirSync(path.join(root, prefix), { withFileTypes: true })) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isSymbolicLink()) throw new Error(`原始包含符号链接，停止：${relative}`);
    if (entry.isDirectory()) {
      if (!excludedDirectories.has(entry.name)) files.push(...inventory(root, relative));
    } else if (!excludedFiles.has(entry.name)) {
      files.push({ file: relative, sha256: sha256(fs.readFileSync(path.join(root, relative))) });
    }
  }
  return files.sort((left, right) => left.file < right.file ? -1 : left.file > right.file ? 1 : 0);
}

function treeHash(files) {
  return sha256(files.map(file => `${file.file}\0${file.sha256}\n`).join(''));
}

function gitApply(directory, patch, check) {
  const result = spawnSync('git', ['-C', directory, '-c', 'core.autocrlf=false', 'apply', ...(check ? ['--check'] : []), patch], { encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(`补丁${check ? '预检查' : '应用'}失败：${result.error?.message ?? result.stderr}`);
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--pub-cache' || args[2] !== '--output') {
    throw new Error('用法：node replay.cjs --pub-cache 原始pub缓存根目录 --output 新的隔离输出目录');
  }
  const cache = path.resolve(args[1]);
  const output = path.resolve(args[3]);
  const repository = path.resolve(__dirname, '../../..');
  for (const protectedRoot of [cache, repository]) {
    const relative = path.relative(protectedRoot, output);
    if (!relative || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
      throw new Error('输出须位于pub缓存和仓库之外的独立work目录，不覆盖来源。');
    }
  }
  if (fs.existsSync(output) && fs.readdirSync(output).length > 0) throw new Error('输出目录已有内容，停止以免覆盖。');
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'packages.json'), 'utf8'));
  const prepared = manifest.packages.map(item => {
    const source = path.join(cache, 'hosted/pub.dev', `${item.name}-${item.version}`);
    const archiveMetadata = fs.readFileSync(path.join(cache, 'hosted-hashes/pub.dev', `${item.name}-${item.version}.sha256`), 'utf8').trim();
    if (archiveMetadata !== item.archiveSha256) throw new Error(`归档元数据与固定锁文件不符：${item.name}`);
    const files = inventory(source);
    if (files.length !== item.sourceFileCount || treeHash(files) !== item.sourceTreeSha256) {
      throw new Error(`原始源码树不匹配：${item.name}；不从网络更新或猜测替代来源。`);
    }
    const patch = path.join(__dirname, item.patch);
    if (sha256(fs.readFileSync(patch)) !== item.patchSha256 ||
        sha256(fs.readFileSync(path.join(__dirname, item.license))) !== item.licenseSha256) {
      throw new Error(`交付补丁或许可证校验失败：${item.name}`);
    }
    return { item, source, files, patch };
  });
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, '.gitignore'), '*\n');
  const overrides = ['# 本机生成，只含这5个补丁包；整合其他平台依赖后再决定是否用于主app。', 'dependency_overrides:'];
  const results = [];
  for (const { item, source, files, patch } of prepared) {
    const target = path.join(output, `${item.name}-${item.version}`);
    for (const file of files) {
      const destination = path.join(target, file.file);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(path.join(source, file.file), destination);
    }
    gitApply(target, patch, true);
    gitApply(target, patch, false);
    for (const ending of item.lineEndingsAfterPatch) {
      if (ending.style !== 'crlf') throw new Error('未知换行后处理，停止。');
      const destination = path.join(target, ending.file);
      const text = fs.readFileSync(destination, 'utf8');
      if (text.includes('\r')) throw new Error('后处理前的源码换行不匹配。');
      fs.writeFileSync(destination, text.replaceAll('\n', '\r\n'));
    }
    const fingerprint = treeHash(inventory(target));
    if (fingerprint !== item.patchedTreeSha256) throw new Error(`补丁产物与已验证副本不一致：${item.name}`);
    overrides.push(`  ${item.name}:`, `    path: ${JSON.stringify(target.replaceAll('\\', '/'))}`);
    results.push({ name: item.name, version: item.version, files: files.length, patchedTreeSha256: fingerprint });
  }
  fs.writeFileSync(path.join(output, 'pubspec_overrides.yaml'), `${overrides.join('\n')}\n`);
  fs.writeFileSync(path.join(output, 'replay-result.json'), `${JSON.stringify({ packages: results }, null, 2)}\n`);
  console.log(`已离线重放并逐字节校验${results.length}个包；本机overrides位于输出目录，未替换主应用。`);
}

try { main(); } catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
