import { createHash } from 'node:crypto';

export const FS_SOURCE_SHA256 = 'b275b221acdc4a0ce217b9c552b6ad4a61922874cb9257b618cdf5a560af8dbd';
const anchor = '\tconst linkFile = internals.linkFile ?? link;';
const replacement = '\tconst linkFile = internals.linkFile ?? (process.platform === "openharmony" ? harmonyFsPublishNoReplace : link);';
const watchAnchor = '\tasync watch(target, changed, signal) {';
const watchPatched = watchAnchor + ' throw new Error("ENOSYS: fs.watch unsupported on openharmony"); /* HARMONY_NO_WATCH */';

// 保留原文件和许可正文，只替换默认发布原语；测试边界仍优先。
export function patchFsPublish(source, helperUrl) {
  const prefix = `import { publishNoReplace as harmonyFsPublishNoReplace } from ${JSON.stringify(helperUrl)}; /* HARMONY_FS_EXCLUSIVE_PUBLISH_V1 */\n`;
  let original = source;
  if (source.startsWith(prefix)) {
    const body = source.slice(prefix.length);
    if (body.split(replacement).length !== 2) throw Error('FS_PUBLISH_PATCH_MISMATCH');
    original = body.replace(replacement, anchor);
  }
  // 缓存可能已有启动器的精确watch补丁；仅还原已知字节核验，输出保留它。
  const normalized = original.includes(watchPatched) ? original.replace(watchPatched, watchAnchor) : original;
  if (createHash('sha256').update(normalized).digest('hex') !== FS_SOURCE_SHA256) throw Error('FS_PUBLISH_SOURCE_HASH_MISMATCH');
  if (original.split(anchor).length !== 2) throw Error('FS_PUBLISH_PATCH_MISMATCH');
  return prefix + original.replace(anchor, replacement);
}
