import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
export const SOURCE_SHA256 = 'e2d31fe1292e11f79080f65f69af24d7d288dfe8fb11948a5194051189c29d8d';
export function patchOhosPtc(source) {
  if (createHash('sha256').update(source).digest('hex') !== SOURCE_SHA256) throw Error('PTC_SOURCE_HASH_MISMATCH');
  let text = source.toString('utf8');
  const start = text.indexOf('var NodePtcRuntime = class extends PtcRuntime {');
  const before = text.slice(0, start); let body = text.slice(start);
  function replace(anchor, replacement) {
    if (body.split(anchor).length !== 2) throw Error('PTC_PATCH_ANCHOR_MISMATCH');
    body = body.replace(anchor, replacement);
  }
  replace('var NodePtcRuntime = class extends PtcRuntime {', 'var OhosIsolatedPtcRuntime = class extends PtcRuntime {');
  replace('\t\t"sandbox",\n', '');
  const instructions = '\t\treturn "The program is the body of an async TypeScript function; only erasable syntax is accepted, with no enum or namespaces. Type annotations are advisory. Top-level await and return are supported. Emit output with console.log(...) or return a lossless JSON value. Only printed values and the returned value become program output. Each call runs in a fresh Node process. Node APIs are available through await import(...). Relative paths use the supplied working directory; process.env starts empty. Direct filesystem access follows this execution\'s sandbox policy.";';
  replace(instructions, '\t\treturn "鸿蒙绑定执行模式：程序是一次性异步 TypeScript 函数体，可 await 和 return。每次在官方独立 UID 子进程中运行，真实 process.cwd() 固定为 /，环境为空。请求中的工作目录只保留为宿主工具上下文，不映射为子进程目录；直接 Node 文件 API 不能访问宿主工作区。请通过本次提供的 tools 绑定访问工作区，工具原有权限、审批与取消规则继续生效。文件策略执行能力为 partial，不提供原版同文件世界的 workspace-write 或 unrestricted direct filesystem 能力。通过 console.log 或返回无损 JSON 输出；不保留跨调用内存。";');
  replace('\tconstructor(ctx, config) {\n\t\tsuper(ctx);', '\tconstructor(ctx, config) {\n\t\tif (config.executionMode !== "per-call") throw new Error("OHOS_PTC_PERSISTENT_UNSUPPORTED");\n\t\tif (config.launch?.kind !== "node-script") throw new Error("OHOS_PTC_LAUNCH_UNSUPPORTED");\n\t\tif (ctx.subprocess.ohosIsolatedPtc !== true) throw new Error("OHOS_PTC_ISOLATION_PROVIDER_REQUIRED");\n\t\tsuper(ctx);');
  replace('\t\t\tcwd,\n\t\t\ttimeoutMs:', '\t\t\tcwd,\n\t\t\tworkerCwd: "/",\n\t\t\texecutionScope: "isolated-bindings",\n\t\t\ttimeoutMs:');
  replace('\t\tif (this.disposed) throw new Error("ptc-runtime-node: run after disposal");', '\t\tif (this.disposed) throw new Error("ptc-runtime-node: run after disposal");\n\t\tif (spec.workerCwd !== "/" || spec.executionScope !== "isolated-bindings") throw new Error("OHOS_PTC_UNRESOLVED_SCOPE");');
  replace('\t\t\tdenied: false\n', '\t\t\tdenied: false,\n\t\t\tenforcement: "partial"\n');
  replace('\t\t\tconfined = policy.mode === "danger-full-access" ? void 0 : await this.ctx.sandbox.confine(argv, {\n\t\t\t\t...policy,\n\t\t\t\tmode: policy.mode\n\t\t\t}, signal);', '\t\t\t// 官方独立UID隔离由专用subprocess强制执行；不冒充同文件世界confine。\n\t\t\tif (this.ctx.subprocess.ohosIsolatedPtc !== true) throw new Error("OHOS_PTC_ISOLATION_PROVIDER_REQUIRED");');
  replace('\t\t\t\tcwd: spec.cwd,', '\t\t\t\tcwd: spec.workerCwd,');
  // 临时真机验收钩子，只传结构化种类；提交PR前移除。
  replace('\t\t\treturn await this.execute(spec, spec.sandboxPolicy, bindings, controller);', '\t\t\tconst outcome = await this.execute(spec, spec.sandboxPolicy, bindings, controller);\n\t\t\ttry { globalThis.__dshPtcProbeKind?.(outcome.error?.kind ?? "none"); } catch {}\n\t\t\treturn outcome;');
  replace('export { NodePtcRuntime, NodePtcRuntime as default };', 'export { OhosIsolatedPtcRuntime, OhosIsolatedPtcRuntime as default };');
  return before + body;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output || resolve(input) === resolve(output)) throw Error('用法: node patch-ptc-runtime.mjs 原index.js 输出ohos-index.js');
  writeFileSync(output, patchOhosPtc(readFileSync(input)));
  console.log('已验证固定源摘要并生成独立鸿蒙PTC入口；原文件未改动');
}
