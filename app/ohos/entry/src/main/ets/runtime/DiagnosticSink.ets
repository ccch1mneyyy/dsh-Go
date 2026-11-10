// v12 诊断探针通道。
// RuntimeController（单例）在构造时注册 sink；其它 ETS 模块通过 emitDiagnostic
// 把失败细节写进同一张「引擎日志」卡（与 Node 引擎日志同源，经 RuntimeController.logNote）。
// 这样做是为了在真机侧载后能直接从已可读的日志卡取证，绕开 hdc / 文件导出。
export type DiagnosticSink = (text: string) => void;

let sink: DiagnosticSink | null = null;

export function setDiagnosticSink(next: DiagnosticSink | null): void {
  sink = next;
}

export function emitDiagnostic(text: string): void {
  try {
    sink?.(text);
  } catch (_) {
    // 探针写入失败绝不能影响主流程（生命周期同步 / 附件选择）。
  }
}
