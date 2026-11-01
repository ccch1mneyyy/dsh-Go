import { Socket } from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SubprocessRuntime } from '../opt/dsh/node_modules/@deepseek-ai/dsh-subprocess/lib/index.js';
import { createOhosSubprocessProvider } from './subprocess-ohos.mjs';
import { brokerOptions } from './ohos-runtime-setup.mjs';
// 此模块只由显式平台覆盖行加载；不替代通用shell或终端provider。
export default function apply(ctx) {
  const options = brokerOptions(process.env);
  if (!options) throw Error('OHOS_BROKER_NOT_ENABLED');
  const installed = fileURLToPath(new URL('../', import.meta.url));
  const transport = new Socket({ fd: options.fd, readable: true, writable: true, allowHalfOpen: true });
  const Runtime = createOhosSubprocessProvider(SubprocessRuntime, {
    transport, generation: options.generation, executable: '/ohos/node',
    bootstrapPath: path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/process.js'),
    allowCwd: cwd => cwd === '/'
  });
  return ctx.plugin(Runtime);
}
