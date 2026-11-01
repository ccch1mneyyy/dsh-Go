import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

// 固定发行资产白名单；不读取用户preset、配置、环境或凭据。
const sources = {
  'dsh-tool-bash': ['function apply(ctx, config = {}) {', 'a1215d7bcaf82c0755be48321ef6bb45075f1cb33296d6263009e9d10fd596f6'],
  'dsh-tool-pwsh': ['function apply(ctx, config = {}) {', '94c7f68c425e62c8006907b3f4fea771935321581fd2327b7ee1f0ba8d15eec1'],
  'dsh-tool-fs-search': ['async function apply(ctx, config) {', '8d64d2e8a5310b442ae66bc0daf7d6957ec095dbe43cabd9eb208f7370e381ed'],
  'dsh-tool-terminal': ['function apply(ctx, config = {}) {', 'e75845292220ed21c0af6763ffa0a044d38f7b9b4d05c2b00248aea8718a7e83'],
  'dsh-tool-bash-persistent': ['function apply(ctx, config) {', 'e5da0d699ca999f7372cc67ae913b1b881362b3232f5b01b003709e76390bc82'],
  'dsh-tool-pwsh-persistent': ['function apply(ctx, config) {', 'b9ecb0e226244bf7da74519a9d725feaab6efbc6ce1e74e97f1c7d68261499a9'],
  'dsh-terminal-bash': ['function apply(ctx, config) {', '388ce251b94a919edcfb9c13f6ffc49bcd1f4caf9ee493c65b46b454786c8c8b'],
};
const guard = '\n\t// OHOS_TOOL_CAPABILITY：隔离PTC不能执行任意shell、终端或ripgrep。\n\tif (ctx.get("subprocess")?.ohosIsolatedPtc === true) return;';
const digest = source => createHash('sha256').update(source).digest('hex');
export function patchOhosToolCapability(source, name) {
  const anchor = sources[name]?.[0];
  if (!anchor || source.split(anchor).length !== 2 || source.includes('ohosIsolatedPtc')) throw Error('OHOS_TOOL_CAPABILITY_SOURCE_MISMATCH');
  return source.replace(anchor, anchor + guard);
}
export function installOhosToolCapabilities(installed, platform = process.platform) {
  if (platform !== 'openharmony') return { checked: 0, changed: 0 };
  if (!path.isAbsolute(installed)) throw Error('OHOS_TOOL_CAPABILITY_ROOT_INVALID');
  const changes = [];
  // 全部原摘要/精确补丁先核验，再写入，避免遇到未知模块时留下半套组合。
  for (const [name, [anchor, expected]] of Object.entries(sources)) {
    const file = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai', name, 'lib/index.js');
    const source = fs.readFileSync(file, 'utf8');
    if (digest(source) === expected) changes.push([file, patchOhosToolCapability(source, name)]);
    else {
      const original = source.replace(anchor + guard, anchor);
      if (original === source || digest(original) !== expected || patchOhosToolCapability(original, name) !== source) throw Error('OHOS_TOOL_CAPABILITY_DIGEST_MISMATCH');
    }
  }
  for (const [file, source] of changes) fs.writeFileSync(file, source, { mode: 0o600 });
  return { checked: Object.keys(sources).length, changed: changes.length };
}
