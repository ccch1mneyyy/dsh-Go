import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { patchOhosPtc } from '../scripts/patch-ptc-runtime.mjs';
export function brokerOptions(env) {
  const fd = env.DSH_HARMONY_BROKER_FD, generation = env.DSH_HARMONY_BROKER_GENERATION;
  if (fd === undefined && generation === undefined) return null;
  if (typeof fd !== 'string' || !/^[0-9]+$/.test(fd) || !Number.isSafeInteger(Number(fd)) || Number(fd) < 64 ||
      typeof generation !== 'string' || !/^engine-[0-9]+-[0-9]+$/.test(generation)) throw Error('OHOS_BROKER_OPTIONS_INVALID');
  return { fd: Number(fd), generation };
}
function generatedOnly(file, value) {
  if (fs.existsSync(file)) {
    if (fs.readFileSync(file, 'utf8') !== value) throw Error('OHOS_GENERATED_ASSET_CONFLICT');
  } else fs.writeFileSync(file, value, { flag: 'wx', mode: 0o600 });
}
// 只写已安装资产中的独立派生文件，不读写DSH_HOME用户配置或凭据。
export function prepareOhosRuntime(installed, env) {
  const options = brokerOptions(env);
  const normalPatch = path.join(installed, 'transport/cordis-min.yml');
  if (options === null) return normalPatch;
  const lib = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib');
  generatedOnly(path.join(lib, 'ohos-index.js'), patchOhosPtc(fs.readFileSync(path.join(lib, 'index.js'))));
  // 原Loader把name视为匹配条件，不能用它重命名旧行；禁用旧provider并插入独立行。
  const extra = [
    { id: 'subprocess', disabled: true }, { id: 'subprocess-local', disabled: true },
    { id: 'ptc-runtime', disabled: true }, { id: 'ptc-runtime-node', disabled: true },
    { insert: [
      { id: 'ohos-isolated-subprocess', name: pathToFileURL(path.join(installed, 'transport/subprocess-ohos-loader.mjs')).href },
      { id: 'ohos-isolated-ptc', name: pathToFileURL(path.join(lib, 'ohos-index.js')).href, config: {
        executionMode: 'per-call', launch: { kind: 'node-script', executable: '/ohos/node', bootstrapPath: path.join(lib, 'process.js') }
      } }
    ] }
  ];
  // JSON是YAML子集；原覆盖清单与明确平台选择一起供同一个--patch加载。
  const body = fs.readFileSync(normalPatch, 'utf8') + '\n' + extra.map(item => '- ' + JSON.stringify(item)).join('\n') + '\n';
  const file = path.join(installed, 'transport/cordis-ohos.generated.yml');
  generatedOnly(file, body); return file;
}
