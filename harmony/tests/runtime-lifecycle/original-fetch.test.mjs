import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import vm from 'node:vm';
import path from 'node:path';
const root = new URL('../../plugins/dsh_runtime_ohos/', import.meta.url);
const source = await readFile(new URL('assets/probe-bootstrap.mjs', root), 'utf8');
const start = source.indexOf('  if (!nativeDirectory');
const end = source.indexOf('  process.argv =', start);
assert(start > 0 && end > start);
const originalFetch = globalThis.fetch;
const sandbox = { path, nativeDirectory:'/signed', installed:'/installed', fresh:'/fresh', privateBroker:null,
  fs:{existsSync:()=>false,promises:{}}, syncBuiltinESMExports(){}, process:{env:{NODE_OPTIONS:'untrusted'},chdir(){}}, installOhosToolCapabilities(){}, prepareOhosRuntime:()=>'/fixed', fetch:originalFetch };
// 此处只隔离 VM 内建模块边界；真实 ESM 绑定同步契约由 bootstrap-watch.test.mjs 验证。
// 执行实际启动环境整理与平台适配代码；只mock本机路径和原生模块边界。
vm.runInNewContext(source.slice(start, end), sandbox);
assert.equal(sandbox.fetch, originalFetch);
assert.equal(sandbox.process.env.NODE_OPTIONS, undefined);
const native = await readFile(new URL('native/runtime_process.c', root), 'utf8');
assert.match(native, /"node", "--jitless", "--wasm-jitless", script, installed, data, result, "38081", NULL/);
assert.match(native, /dsh_pack_arguments\(8, argv, 9,/);
assert.match(native, /start\(8, argv\)/);
assert.doesNotMatch(native, /nodeflags|NODE_OPTIONS/);
const server=createServer((request,response)=>{response.setHeader('Content-Type','application/json');response.end('{"fixed":42}');});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
try { const response=await sandbox.fetch(`http://127.0.0.1:${server.address().port}/`); assert(response instanceof Response); assert.deepEqual(await response.json(),{fixed:42}); }
finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
console.log('实际启动段保留原fetch、清除NODE_OPTIONS、原fetch回环与8项argv校验通过；不替代鸿蒙真机验证');
