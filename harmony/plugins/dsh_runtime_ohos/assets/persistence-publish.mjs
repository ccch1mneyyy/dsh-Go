import path from 'node:path';

let binding;
export function publishNoReplace(source, target) {
  if (process.platform !== 'openharmony') throw new Error('PUBLISH_UNSUPPORTED_PLATFORM');
  if (!binding) {
    const root = process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;
    if (!root || !path.isAbsolute(root)) throw new Error('SIGNED_LIBRARY_DIRECTORY_MISSING');
    const loaded = { exports: {} };
    process.dlopen(loaded, path.join(root, 'libdsh_publish.so'));
    if (typeof loaded.exports.publishNoReplaceSync !== 'function') throw new Error('PUBLISH_BINDING_MISSING');
    binding = loaded.exports;
  }
  // 只执行一次本地原子文件操作；目录同步仍由持久化调用方完成。
  return binding.publishNoReplaceSync(source, target);
}

export function patchPersistence(source, helperUrl) {
  const marker = 'HARMONY_EXCLUSIVE_PUBLISH_V1';
  if (source.includes(marker)) return source;
  // 兼容旧缓存的错误替换，恢复精确锚点后统一应用排他发布。
  source = source.replace('if (process.platform === "openharmony") { await rename(staged, currentPath); } else { await internals.fs.link(staged, currentPath); } /* HARMONY_LINK_FALLBACK */', 'await internals.fs.link(staged, currentPath);');
  source = source.replace('if (process.platform === "openharmony") { await rename(tmp, finalPath); } else { await link(tmp, finalPath); }', 'await link(tmp, finalPath);');
  const replacements = [
    ['await internals.fs.link(staged, currentPath);', 'if (process.platform === "openharmony") { harmonyPublishNoReplace(staged, currentPath); return true; } else await internals.fs.link(staged, currentPath);'],
    ['await link(tmp, finalPath);', 'if (process.platform === "openharmony") harmonyPublishNoReplace(tmp, finalPath); else await link(tmp, finalPath);'],
    ['if (published && internals.platform === "win32") staged = {', 'if (published && (internals.platform === "win32" || process.platform === "openharmony")) staged = {'],
    ['await internals.barrier("after-publication", 1);', 'if (published && process.platform === "openharmony") await syncDirectory(dirname(currentPath), internals); await internals.barrier("after-publication", 1);'],
  ];
  for (const [from, to] of replacements) {
    if (source.split(from).length !== 2) throw new Error('PERSISTENCE_PUBLISH_PATCH_MISMATCH');
    source = source.replace(from, to);
  }
  return `import { publishNoReplace as harmonyPublishNoReplace } from ${JSON.stringify(helperUrl)}; /* ${marker} */\n` + source;
}
