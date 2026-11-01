export interface BrokerConnection { handle?: number; fd?: number; error: number; }
export interface BrokerRead { bytes: Uint8Array; eof: number; error: number; }
interface Broker {
  create(): BrokerConnection;
  attached(handle: number): number;
  read(handle: number): BrokerRead;
  write(handle: number, bytes: Uint8Array): number;
  close(handle: number): number;
}
declare const broker: Broker;
export default broker;
