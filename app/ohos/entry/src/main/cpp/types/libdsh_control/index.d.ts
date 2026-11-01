declare const control: { forget(pid: number): number; signal(pid: number): number; reset(): number; watch(): number; stop(pid: number): number; exited(pid: number): number };
export default control;
