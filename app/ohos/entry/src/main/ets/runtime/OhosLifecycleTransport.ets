// Loopback lifecycle transport for HarmonyOS.
//
// Public SDK 26 APIs. The engine binds a fixed IPv4 loopback listener
// (127.0.0.1:port); @ohos.net.http cannot reach loopback on HarmonyOS NEXT,
// so this transport talks HTTP/1.1 over @ohos.net.socket (see LoopbackHttp).
import { LifecycleTransport, HostLifecycleObservation, HostLifecycleAck, LifecycleFailure } from './RuntimeLifecycle';
import { exchange, HttpResponse } from './LoopbackHttp';
import { emitDiagnostic } from './DiagnosticSink';

interface LifecycleAck extends HostLifecycleAck {
  observationRevision: number;
  v: number;
  host: HostLifecycleObservation;
  closed: boolean;
  blocked: boolean;
}

export class OhosLifecycleTransport implements LifecycleTransport {
  private generation: number = 0;
  private origin: string | null = null;
  private launchToken: string | null = null;
  private cookie: string | null = null;
  private static reportedOk: boolean = false;

  cancel(): void {
    this.generation++;
  }

  private current(generation: number): void {
    if (generation !== this.generation) throw new LifecycleFailure('ohos_lifecycle_cancelled');
  }

  async send(baseUrl: string, token: string, observation: HostLifecycleObservation): Promise<HostLifecycleAck> {
    // HostCore starts a fixed IPv4 loopback listener. Never accept a Dart URL.
    const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/?$/.exec(baseUrl);
    if (match === null || Number(match[1]) < 1 || Number(match[1]) > 65535 || token.length === 0) {
      emitDiagnostic('lifecycle.endpoint ' + JSON.stringify({ baseUrl, tokenLen: token.length }));
      throw new LifecycleFailure('ohos_lifecycle_endpoint');
    }
    const host = '127.0.0.1';
    const port = Number(match[1]);
    const origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    const generation = this.generation;
    if (this.origin !== origin || this.launchToken !== token) {
      this.origin = origin;
      this.launchToken = token;
      this.cookie = null;
    }
    if (this.cookie === null) {
      let login: HttpResponse;
      try {
        login = await exchange(host, port, 'GET', '/?token=' + encodeURIComponent(token), {}, null, 1000, 3000);
      } catch (e) {
        emitDiagnostic('lifecycle.transport ' + JSON.stringify({ code: 'ohos_lifecycle_unavailable', phase: 'login', detail: String(e) }));
        throw new LifecycleFailure('ohos_lifecycle_unavailable');
      }
      this.current(generation);
      const rawCookies = login.headers['set-cookie'];
      const cookies: string[] = rawCookies ? rawCookies.split(',') : [];
      const matches = cookies.map((value: string): string => value.split(';')[0])
        .filter((value: string): boolean => /^dsh-auth-[A-Za-z0-9_-]+=[A-Za-z0-9_.-]+$/.test(value));
      if (login.statusCode !== 303 || matches.length !== 1) {
        emitDiagnostic('lifecycle.auth ' + JSON.stringify({ statusCode: login.statusCode, cookieCount: cookies.length, matched: matches.length }));
        throw new LifecycleFailure('ohos_lifecycle_auth');
      }
      this.cookie = matches[0];
    }
    this.current(generation);
    let response: HttpResponse;
    try {
      response = await exchange(host, port, 'POST', '/dsh-go/v1/lifecycle', {
        'cookie': this.cookie ?? '',
        'content-type': 'application/json'
      }, JSON.stringify({
        operation: 'host',
        revision: observation.revision,
        foreground: observation.foreground,
        computePermission: observation.computePermission
      }), 1000, 3000);
    } catch (e) {
      emitDiagnostic('lifecycle.transport ' + JSON.stringify({ code: 'ohos_lifecycle_unavailable', phase: 'control', detail: String(e) }));
      throw new LifecycleFailure('ohos_lifecycle_unavailable');
    }
    this.current(generation);
    if (response.statusCode === 401) this.cookie = null;
    if (response.statusCode !== 200 || typeof response.body !== 'string') {
      emitDiagnostic('lifecycle.control ' + JSON.stringify({ statusCode: response.statusCode, hasResult: typeof response.body === 'string' }));
      throw new LifecycleFailure('ohos_lifecycle_control');
    }
    const rawResult = response.body;
    const ack: LifecycleAck = JSON.parse(rawResult) as LifecycleAck;
    // The caller revision correlates this response only. Native facts are not
    // required to equal untrusted HTTP foreground/permission input.
    if (ack.v !== 1 || ack.observationRevision !== observation.revision ||
        typeof ack.busy !== 'boolean' || typeof ack.manualPaused !== 'boolean' ||
        typeof ack.confirmedPause !== 'boolean' || ack.closed !== false || ack.blocked !== false) {
      emitDiagnostic('lifecycle.ack ' + JSON.stringify({ raw: rawResult.slice(0, 240), expectedRevision: observation.revision }));
      throw new LifecycleFailure('ohos_lifecycle_ack');
    }
    const native = ack.nativeHost;
    if (native === null || native === undefined || native.version !== 1 ||
        ![native.engineGeneration, native.ownerGeneration, native.revision, native.grantGeneration,
          native.deadlineMs, native.drainAtMs, native.phase].every((value: number): boolean => Number.isSafeInteger(value) && value >= 0) ||
        !Number.isSafeInteger(native.nowMs) || native.nowMs < -1 || native.phase > 7 ||
        ![0, 1].includes(native.available) || ![0, 1].includes(native.foreground) ||
        ![0, 1].includes(native.clockFailed)) {
      const snap = native;
      if (snap !== null && snap !== undefined) {
        emitDiagnostic('lifecycle.native ' + JSON.stringify({
          phase: snap.phase, version: snap.version, available: snap.available,
          foreground: snap.foreground, clockFailed: snap.clockFailed
        }));
      }
      throw new LifecycleFailure('ohos_lifecycle_native');
    }
    if (!OhosLifecycleTransport.reportedOk) {
      OhosLifecycleTransport.reportedOk = true;
      emitDiagnostic('lifecycle.ok ' + JSON.stringify({ available: native.available, foreground: native.foreground }));
    }
    return ack;
  }
}
