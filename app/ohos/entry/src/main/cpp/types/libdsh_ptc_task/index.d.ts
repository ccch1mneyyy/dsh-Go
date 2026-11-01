export interface TaskStatus { pid: number; exited: number; signal: number; }
export interface TaskRead { bytes: Uint8Array; eof: number; error: number; }
interface NativeTask {
 launch(installedRoot: string, cwd: string, maxMessageBytes: number, heapMb: number): number;
 status(pid: number): TaskStatus;
 read(pid: number, streamIndex: number, maxBytes: number): TaskRead;
 write(pid: number, data: Uint8Array): number;
 end(pid: number): number;
 stop(pid: number): number;
 release(pid: number): number;
}
declare const task: NativeTask;
export default task;
