// Minimal HTTP/1.1 client over @ohos.net.socket (raw TCP).
//
// Why this exists: HarmonyOS NEXT's @ohos.net.http cannot reach the IPv4
// loopback listener that the dsh HostCore engine binds to (127.0.0.1:port),
// while dart:io and raw TCP sockets can. The lifecycle transport is the only
// native path that talks to the engine, so it must use a loopback-capable
// transport. @ohos.net.socket reaches loopback, so we implement the two
// requests (GET login + POST lifecycle) as plain HTTP/1.1 over TCP.
import socket from '@ohos.net.socket';
import { emitDiagnostic } from './DiagnosticSink';

export interface HttpResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

interface TcpMessage {
  message: ArrayBuffer;
  remoteInfo: Object;
}

function abToString(ab: ArrayBuffer): string {
  const u8 = new Uint8Array(ab);
  let s = '';
  const CHUNK = 8192;
  for (let i = 0; i < u8.length; i += CHUNK) {
    const end = Math.min(i + CHUNK, u8.length);
    for (let j = i; j < end; j++) {
      s += String.fromCharCode(u8[j]);
    }
  }
  return s;
}

function concat(list: ArrayBuffer[]): ArrayBuffer {
  let total = 0;
  for (const b of list) total += b.byteLength;
  const out = new Uint8Array(total);
  let off = 0;
  for (const b of list) {
    out.set(new Uint8Array(b), off);
    off += b.byteLength;
  }
  return out.buffer;
}

function parseHeaders(headerText: string): Record<string, string> {
  const headers: Record<string, string> = {};
  const lines = headerText.split('\r\n');
  for (const line of lines) {
    const idx = line.indexOf(':');
    if (idx <= 0) continue;
    const key = line.substring(0, idx).trim().toLowerCase();
    const value = line.substring(idx + 1).trim();
    const existing = headers[key];
    if (existing !== undefined) {
      headers[key] = existing + ', ' + value;
    } else {
      headers[key] = value;
    }
  }
  return headers;
}

function decodeChunked(encoded: string): string {
  let result = '';
  let i = 0;
  while (i < encoded.length) {
    const lineEnd = encoded.indexOf('\r\n', i);
    if (lineEnd === -1) break;
    const sizeLine = encoded.substring(i, lineEnd).trim().split(';')[0];
    const size = parseInt(sizeLine, 16);
    if (!Number.isFinite(size) || size < 0) break;
    i = lineEnd + 2;
    if (size === 0) break;
    if (i + size > encoded.length) break;
    result += encoded.substring(i, i + size);
    i = i + size + 2;
  }
  return result;
}

export async function exchange(
  host: string,
  port: number,
  method: string,
  path: string,
  headers: Record<string, string>,
  body: string | null,
  connectTimeout: number,
  readTimeout: number
): Promise<HttpResponse> {
  const tcp = socket.constructTCPSocketInstance();
  const buffers: ArrayBuffer[] = [];
  let settled = false;
  let resolveFn: ((r: HttpResponse) => void) | null = null;
  let rejectFn: ((e: Error) => void) | null = null;

  let headerEnd = -1;
  let statusCode = 0;
  let parsedHeaders: Record<string, string> = {};
  let chunked = false;
  let contentLength = -1;
  let timer: number = 0;

  const promise = new Promise<HttpResponse>((resolve, reject) => {
    resolveFn = resolve;
    rejectFn = reject;
  });

  const settle = (r: HttpResponse | null, e: Error | null): void => {
    if (settled) return;
    settled = true;
    if (timer !== 0) clearTimeout(timer);
    try {
      tcp.close();
    } catch (_) {
    }
    if (r !== null) resolveFn?.(r);
    else rejectFn?.(e ?? new Error('unknown'));
  };

  const tryRead = (): void => {
    if (settled) return;
    const text = abToString(concat(buffers));
    if (headerEnd === -1) {
      headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd === -1) return;
      const headerText = text.substring(0, headerEnd);
      const firstLine = headerText.split('\r\n')[0];
      const statusMatch = /^HTTP\/\d\.\d\s+(\d{3})/.exec(firstLine);
      statusCode = statusMatch ? parseInt(statusMatch[1]) : 0;
      parsedHeaders = parseHeaders(headerText);
      const te = parsedHeaders['transfer-encoding'];
      if (te !== undefined && te.toLowerCase().includes('chunked')) {
        chunked = true;
      } else {
        const cl = parsedHeaders['content-length'];
        if (cl !== undefined) contentLength = parseInt(cl);
      }
    }
    const bodyText = text.substring(headerEnd + 4);
    if (chunked) {
      if (bodyText.indexOf('\r\n0\r\n') !== -1) {
        settle({ statusCode, headers: parsedHeaders, body: decodeChunked(bodyText) }, null);
      }
    } else if (contentLength >= 0) {
      if (bodyText.length >= contentLength) {
        settle({ statusCode, headers: parsedHeaders, body: bodyText.substring(0, contentLength) }, null);
      }
    }
  };

  tcp.on('message', (data: Object): void => {
    const msg = (data as TcpMessage).message;
    buffers.push(msg);
    tryRead();
  });
  tcp.on('close', (): void => {
    if (settled) return;
    if (headerEnd === -1) {
      emitDiagnostic('lifecycle.socket ' + JSON.stringify({ phase: 'close_no_headers', statusCode }));
      settle(null, new Error('socket_closed_no_headers'));
      return;
    }
    // We always send `Connection: close`, so the response body is whatever
    // bytes follow the headers before the peer closes. This is the standard
    // close-delimited body and also covers Content-Length: 0 and missing
    // Content-Length. Chunked responses are decoded best-effort even without
    // the terminating 0-chunk (the engine closes the socket right after the
    // body, so the terminator may arrive in the same close frame).
    const text = abToString(concat(buffers));
    let bodyText = text.substring(headerEnd + 4);
    if (chunked) bodyText = decodeChunked(bodyText);
    settle({ statusCode, headers: parsedHeaders, body: bodyText }, null);
  });
  tcp.on('error', (err: Error): void => {
    emitDiagnostic('lifecycle.socket ' + JSON.stringify({ phase: 'error', detail: err.message }));
    settle(null, new Error('socket_error ' + err.message));
  });

  let req = method + ' ' + path + ' HTTP/1.1\r\n';
  req += 'Host: ' + host + ':' + port + '\r\n';
  for (const k of Object.keys(headers)) req += k + ': ' + headers[k] + '\r\n';
  req += 'Connection: close\r\n';
  if (body !== null) req += 'Content-Length: ' + body.length + '\r\n';
  req += '\r\n';
  if (body !== null) req += body;

  timer = setTimeout((): void => {
    emitDiagnostic('lifecycle.socket ' + JSON.stringify({ phase: 'timeout' }));
    settle(null, new Error('timeout'));
  }, readTimeout);

  try {
    await tcp.connect({ address: { address: host, port: port, family: 1 }, timeout: connectTimeout });
    await tcp.send({ data: req, encoding: 'utf-8' });
  } catch (e) {
    const err = e as Error;
    emitDiagnostic('lifecycle.socket ' + JSON.stringify({ phase: 'connect_send', detail: err.message }));
    settle(null, new Error('connect_send ' + err.message));
    return promise;
  }
  return promise;
}
