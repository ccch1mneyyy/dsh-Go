const fs = require('node:fs');
const path = require('node:path');
// 从唯一协议源码生成宿主JS；不维护第二份状态机。
const ts = require(process.argv[2] || 'typescript');
const source = path.join(__dirname, 'parent-broker.ts');
const destination = path.resolve(__dirname, '../../../../app/ohos/entry/src/main/ets/engineability/broker');
fs.mkdirSync(destination, { recursive: true });
const js = ts.transpileModule(fs.readFileSync(source, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 }, reportDiagnostics: true });
if (js.diagnostics.length) throw Error('协议源码转译失败');
fs.writeFileSync(path.join(destination, 'parent-broker.js'), '// 由 generate-host.cjs 生成，请修改原始 parent-broker.ts。\n' + js.outputText);
const program = ts.createProgram([source], { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020, declaration: true, emitDeclarationOnly: true, strict: true });
const emitted = program.emit(undefined, (name, text) => { if (name.endsWith('.d.ts')) fs.writeFileSync(path.join(destination, 'parent-broker.d.ts'), text); });
if (emitted.emitSkipped) throw Error('声明生成失败');
console.log('协议JS及声明已从唯一TS源码生成');
