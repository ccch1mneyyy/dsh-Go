export type StreamName = 'stdout' | 'stderr' | 'control';
export interface ExitFacts {
    exitCode: number | null;
    signal: string | null;
}
export interface SpawnSpec {
    kind: 'ptc-oneshot';
    argv: string[];
    cwd: string;
    envSet: Record<string, string>;
    envUnset: string[];
    stdio: {
        stdin: 'ignore';
        stdout: 'pipe';
        stderr: 'pipe';
        control: 'pipe';
    };
    graceMs: number;
}
export interface Task {
    read(stream: StreamName, maxBytes: number): {
        data: Uint8Array;
        eof: boolean;
    };
    writeControl(data: Uint8Array): number;
    endControl(): void;
    stop(): void;
    pollExit(): ExitFacts | null;
    reap(): Promise<void>;
}
export interface Codec {
    encodeText(text: string): Uint8Array;
    decodeText(data: Uint8Array): string;
    base64(data: Uint8Array): string;
    unbase64(text: string): Uint8Array;
}
export declare class Cancellation {
    aborted: boolean;
    private listeners;
    subscribe(listener: () => void): () => void;
    cancel(): void;
}
export interface StartFailure {
    startFailed: true;
    reaped: true;
    code: string;
}
export interface TaskDriver {
    start(spec: SpawnSpec, signal: Cancellation): Promise<Task | StartFailure>;
}
/** 纯协议状态机；调用方须持续pump，断连调用disconnect并保留对象至settled。 */
export declare class ParentBroker {
    private generation;
    private driver;
    private writeTransport;
    private allowSpec;
    private codec;
    private input;
    private output;
    private outputBytes;
    private states;
    private pending;
    private lastId;
    private closed;
    failure: string | null;
    constructor(generation: string, driver: TaskDriver, writeTransport: (data: Uint8Array) => number, allowSpec: (spec: SpawnSpec) => boolean, codec: Codec);
    private track;
    private send;
    accept(chunk: Uint8Array): void;
    private receive;
    pump(): void;
    private cleanup;
    disconnect(code?: string): void;
    settled(): Promise<void>;
}
