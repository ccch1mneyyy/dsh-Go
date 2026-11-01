const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// 只排除本地工具生成物；原包的有效源码、资源和许可证全部参加校验。
const excludedDirectories = new Set(['.git', '.dart_tool', 'build', 'oh_modules', '.hvigor', 'node_modules']);
const excludedFiles = new Set(['.flutter-plugins-dependencies', '.packages', 'BuildProfile.ets', 'oh-package-lock.json5']);
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
const effective = file => !file.split('/').some(part => excludedDirectories.has(part)) && !excludedFiles.has(path.posix.basename(file));
const treeHash = files => sha256(files.map(file => `${file.file}\0${file.sha256}\n`).join(''));

function git(source, args, options = {}) {
  const result = spawnSync('git', ['--no-replace-objects', '-C', source, ...args], { maxBuffer: 128 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw new Error(`Git只读/补丁操作失败：${result.error?.message ?? result.stderr.toString()}`);
  return result.stdout;
}

function gitSnapshot(source, item) {
  if (git(source, ['remote', 'get-url', 'origin']).toString().trim() !== item.repository) throw new Error(`来源URL不匹配：${item.name}`);
  if (git(source, ['rev-parse', '--verify', `${item.commit}^{commit}`]).toString().trim() !== item.commit) throw new Error(`固定提交不匹配：${item.name}`);
  const entries = git(source, ['ls-tree', '-rz', '--full-tree', item.commit, '--', `${item.packagePath}/`]).toString().split('\0').filter(Boolean).map(row => {
    const match = /^(\d+) blob ([0-9a-f]+)\t(.+)$/.exec(row);
    if (!match || !['100644', '100755'].includes(match[1])) throw new Error('源码包含未支持对象或符号链接，停止。');
    return { file: match[3].slice(item.packagePath.length + 1), oid: match[2] };
  }).filter(entry => effective(entry.file)).sort((a, b) => a.file < b.file ? -1 : a.file > b.file ? 1 : 0);
  if (!entries.length) throw new Error(`固定提交没有目标包：${item.name}`);
  // 从固定Git对象读取二进制字节，不依赖工作树的换行设置或当前分支。
  const content = git(source, ['cat-file', '--batch'], { input: entries.map(entry => entry.oid).join('\n') + '\n' });
  let offset = 0;
  return entries.map(entry => {
    const end = content.indexOf(10, offset);
    const header = content.subarray(offset, end).toString();
    const match = /^([0-9a-f]+) blob (\d+)$/.exec(header);
    if (!match || match[1] !== entry.oid) throw new Error('Git对象读取响应不匹配。');
    const length = Number(match[2]);
    const bytes = content.subarray(end + 1, end + 1 + length);
    offset = end + 2 + length;
    return { file: entry.file, bytes, sha256: sha256(bytes) };
  });
}

function inventory(root, prefix = '') {
  const files = [];
  for (const entry of fs.readdirSync(path.join(root, prefix), { withFileTypes: true })) {
    const file = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (!effective(file)) continue;
    if (entry.isSymbolicLink()) throw new Error(`有效源码包含符号链接，停止：${file}`);
    if (entry.isDirectory()) files.push(...inventory(root, file));
    else files.push({ file, sha256: sha256(fs.readFileSync(path.join(root, file))) });
  }
  return files.sort((a, b) => a.file < b.file ? -1 : a.file > b.file ? 1 : 0);
}

function inside(parent, child) {
  const relative = path.relative(parent, child);
  return !relative || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--sources' || args[2] !== '--output') throw new Error('用法：node replay.cjs --sources 官方克隆父目录 --output 新的D盘隔离work目录');
  const sources = fs.realpathSync(args[1]);
  const output = path.resolve(args[3]);
  const repository = path.resolve(__dirname, '../../..');
  if (!/^D:\\/i.test(output) || inside(sources, output) || inside(repository, output)) throw new Error('输出必须位于D盘，且在原始克隆和项目仓库之外。');
  // 限制输出祖先无链接，防止路径表面隔离但实际写回来源。
  let ancestor = output;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  if (fs.realpathSync(ancestor).toLowerCase() !== ancestor.toLowerCase()) throw new Error('输出路径祖先含链接，停止。');
  if (fs.existsSync(output) && fs.readdirSync(output).length) throw new Error('输出目录已有内容，不覆盖。');
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'packages.json'), 'utf8'));
  const prepared = manifest.packages.map(item => {
    const source = path.join(sources, item.cloneDirectory);
    const files = gitSnapshot(source, item);
    if (files.length !== item.sourceFileCount || treeHash(files) !== item.sourceTreeSha256) throw new Error(`原始Git对象树校验失败：${item.name}`);
    for (const artifact of [item.license, ...(item.patch ? [item.patch] : [])]) {
      if (sha256(fs.readFileSync(path.join(__dirname, artifact.file))) !== artifact.sha256) throw new Error(`交付文件校验失败：${artifact.file}`);
    }
    return { item, files };
  });
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, '.gitignore'), '*\n');
  const overrides = ['# 仅四个官方OHOS后端的候选；主线程合并其他现有override后再使用。', 'dependency_overrides:'];
  const results = [];
  for (const { item, files } of prepared) {
    const target = path.join(output, item.name);
    for (const file of files) {
      const destination = path.join(target, file.file);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.writeFileSync(destination, file.bytes);
    }
    if (item.patch) {
      const patch = path.join(__dirname, item.patch.file);
      git(target, ['-c', 'core.autocrlf=false', 'apply', '--check', patch]);
      git(target, ['-c', 'core.autocrlf=false', 'apply', patch]);
    }
    // 原成功副本经Windows检出；仅按固定清单恢复其CRLF字节，不扩大功能补丁。
    for (const file of item.lineEndingsAfterPatch) {
      const destination = path.join(target, file);
      const text = fs.readFileSync(destination, 'utf8');
      if (text.includes('\r')) throw new Error('换行后处理前不是固定LF源码，停止。');
      fs.writeFileSync(destination, text.replaceAll('\n', '\r\n'));
    }
    const actual = inventory(target);
    if (actual.length !== item.patchedFileCount || treeHash(actual) !== item.patchedTreeSha256) throw new Error(`重放结果不等于已成功副本：${item.name}`);
    overrides.push(`  ${item.name}:`, `    path: ${JSON.stringify(target.replaceAll('\\', '/'))}`);
    results.push({ name: item.name, commit: item.commit, files: actual.length, treeSha256: treeHash(actual) });
  }
  fs.writeFileSync(path.join(output, 'pubspec_overrides.yaml'), overrides.join('\n') + '\n');
  fs.writeFileSync(path.join(output, 'replay-result.json'), JSON.stringify({ packages: results }, null, 2) + '\n');
  console.log(`已离线导出并核验${results.length}个OHOS后端；未修改主app或来源。`);
}

module.exports = { gitSnapshot, inventory, treeHash, sha256 };
if (require.main === module) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
