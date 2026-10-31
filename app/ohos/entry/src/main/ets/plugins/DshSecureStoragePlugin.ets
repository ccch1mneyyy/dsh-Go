import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

class StorageFailure extends Error {
  code: string;

  constructor(code: string) {
    super(code);
    this.code = code;
  }
}

class SecretEntry {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

// 私钥和对称密钥均不导出；偏好只保存版本、随机 nonce 和认证密文。
class HuksSecretStore {
  private alias: string;
  private data: preferences.Preferences;
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  constructor(context: common.Context, namespace: string) {
    this.alias = 'dsh.secure.aes256gcm.v1.' + namespace;
    this.data = preferences.getPreferencesSync(context, { name: 'DshSecureStorage_v1_' + namespace });
  }

  private properties(purpose: number): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
    ];
  }

  private names(): string[] {
    return Object.keys(this.data.getAllSync());
  }

  private async ensureKey(create: boolean): Promise<void> {
    let exists = false;
    try {
      exists = await huks.isKeyItemExist(this.alias, { properties: [] });
    } catch (error) {
      // API9+ 的 isKeyItemExist 以 12000011 表示不存在，不等同旧接口返回 false。
      if ((error as BusinessError).code !== 12000011) {
        throw error as Error;
      }
    }
    if (exists) {
      return;
    }
    // 历史密文仍在时绝不生成替代密钥或清空，避免把密钥丢失伪装成正常空库。
    if (!create || this.names().length > 0) {
      throw new StorageFailure('KEY_MISSING');
    }
    await huks.generateKeyItem(this.alias, {
      properties: this.properties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT)
    });
  }

  private async id(key: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: this.encoder.encodeInto(key) });
    const result = await digest.digest();
    // 键名也可能含主机标识；只把摘要作为偏好键，原键名与值一同加密。
    return 'v1_' + this.base64.encodeToStringSync(result.data);
  }

  private merge(parts: Uint8Array[]): Uint8Array {
    let size = 0;
    for (const part of parts) {
      size += part.length;
    }
    const output = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      output.set(part, offset);
      offset += part.length;
    }
    return output;
  }

  private async crypt(input: Uint8Array, nonce: Uint8Array, id: string, decrypt: boolean,
    tag?: Uint8Array): Promise<Uint8Array> {
    const purpose = decrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT :
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT;
    const properties = this.properties(purpose);
    properties.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    properties.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: this.encoder.encodeInto(id) });
    if (tag !== undefined) {
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    }
    const session = await huks.initSession(this.alias, { properties: properties });
    let finished = false;
    try {
      const parts: Uint8Array[] = [];
      let offset = 0;
      // 分段传输私钥等较长内容；认证完成之前不向调用者返回任何解密内容。
      while (input.length - offset > 16384) {
        const update = await huks.updateSession(session.handle, {
          properties: properties, inData: input.slice(offset, offset + 16384)
        });
        if (update.outData !== undefined) {
          parts.push(update.outData);
        }
        offset += 16384;
      }
      const result = await huks.finishSession(session.handle, {
        properties: properties, inData: input.slice(offset)
      });
      finished = true;
      if (result.outData !== undefined) {
        parts.push(result.outData);
      }
      return this.merge(parts);
    } finally {
      if (!finished) {
        try {
          await huks.abortSession(session.handle, { properties: [] });
        } catch (_) {
          // 会话可能已由失败的 finish 释放；清理错误不覆盖原始认证/运算错误。
        }
      }
    }
  }

  async write(key: string, value: string): Promise<void> {
    await this.ensureKey(true);
    const id = await this.id(key);
    const nonce = (await cryptoFramework.createRandom().generateRandom(12)).data;
    const plain = this.encoder.encodeInto(JSON.stringify(new SecretEntry(key, value)));
    const encrypted = await this.crypt(plain, nonce, id, false);
    if (encrypted.length < 16) {
      throw new StorageFailure('INVALID_CIPHER_RESULT');
    }
    // HUKS 的 GCM 加密输出为密文后接 16 字节认证标签。
    await this.data.put(id, '1.' + this.base64.encodeToStringSync(nonce) + '.' +
      this.base64.encodeToStringSync(encrypted));
    await this.data.flush();
  }

  private async entry(id: string): Promise<SecretEntry> {
    await this.ensureKey(false);
    const stored = this.data.getSync(id, '');
    if (typeof stored !== 'string') {
      throw new StorageFailure('INVALID_STORED_DATA');
    }
    const fields = stored.split('.');
    if (fields.length !== 3 || fields[0] !== '1') {
      throw new StorageFailure('INVALID_STORED_DATA');
    }
    const nonce = this.base64.decodeSync(fields[1]);
    const encrypted = this.base64.decodeSync(fields[2]);
    if (nonce.length !== 12 || encrypted.length < 16) {
      throw new StorageFailure('INVALID_STORED_DATA');
    }
    const plain = await this.crypt(encrypted.slice(0, encrypted.length - 16), nonce, id, true,
      encrypted.slice(encrypted.length - 16));
    const payload = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true }).decodeWithStream(plain)) as SecretEntry;
    if (payload === null || typeof payload.key !== 'string' || typeof payload.value !== 'string' ||
      await this.id(payload.key) !== id) {
      throw new StorageFailure('INVALID_STORED_DATA');
    }
    return payload;
  }

  async read(key: string): Promise<string | null> {
    const id = await this.id(key);
    if (!this.data.hasSync(id)) {
      return null;
    }
    return (await this.entry(id)).value;
  }

  async containsKey(key: string): Promise<boolean> {
    return this.data.hasSync(await this.id(key));
  }

  async delete(key: string): Promise<void> {
    await this.data.delete(await this.id(key));
    await this.data.flush();
  }

  async readAll(): Promise<Map<string, string>> {
    const result = new Map<string, string>();
    for (const id of this.names()) {
      const entry = await this.entry(id);
      result.set(entry.key, entry.value);
    }
    return result;
  }

  async deleteAll(): Promise<void> {
    // 仅清理此插件自己的命名空间；保留系统密钥供后续写入，避免不必要的密钥轮换。
    await this.data.clear();
    await this.data.flush();
  }
}

export default class DshSecureStoragePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | undefined;
  private context: common.Context | undefined;
  // 所有实例共用队列，首次建钥检查、写入和删除不并行交错。
  private static pending: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return 'DshSecureStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'plugins.it_nomads.com/flutter_secure_storage');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.context = undefined;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    DshSecureStoragePlugin.pending = DshSecureStoragePlugin.pending.then(async (): Promise<void> => {
      try {
        await this.execute(call, result);
      } catch (error) {
        if (error instanceof StorageFailure) {
          result.error(error.code, '安全存储操作失败', null);
        } else {
          // 不向日志或错误消息拼接键名、内容或原生异常文本。
          const code = (error as BusinessError).code;
          result.error('DSH_SECURE_STORAGE_ERROR', '安全存储操作失败', typeof code === 'number' ? code : null);
        }
      }
    });
  }

  private namespace(call: MethodCall): string {
    const options = call.argument('options') as Map<string, string>;
    if (!(options instanceof Map)) {
      throw new StorageFailure('INVALID_OPTIONS');
    }
    let namespace = 'default';
    options.forEach((value: string, key: string): void => {
      // 这是本项目探针隔离选项，不冒充上游的算法/认证/自动重置配置。
      if (key !== 'dshNamespace' || typeof value !== 'string' || !/^[a-z0-9_]{1,32}$/.test(value)) {
        throw new StorageFailure('UNSUPPORTED_OPTIONS');
      }
      namespace = value;
    });
    return namespace;
  }

  private key(call: MethodCall): string {
    const key: string | number | boolean | Object | null | undefined = call.argument('key');
    if (typeof key !== 'string') {
      throw new StorageFailure('INVALID_KEY');
    }
    return key;
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.context === undefined) {
      throw new StorageFailure('PLUGIN_DETACHED');
    }
    if (call.method === 'isProtectedDataAvailable') {
      result.success(null);
      return;
    }
    if (!['write', 'read', 'readAll', 'containsKey', 'delete', 'deleteAll'].includes(call.method)) {
      // 升级探测等未实现接口按通道契约返回未实现，不谎报迁移成功。
      result.notImplemented();
      return;
    }
    const store = new HuksSecretStore(this.context, this.namespace(call));
    switch (call.method) {
      case 'write': {
        const value: string | number | boolean | Object | null | undefined = call.argument('value');
        if (typeof value !== 'string') {
          throw new StorageFailure('INVALID_VALUE');
        }
        await store.write(this.key(call), value);
        result.success(null);
        break;
      }
      case 'read':
        result.success(await store.read(this.key(call)));
        break;
      case 'containsKey':
        result.success(await store.containsKey(this.key(call)));
        break;
      case 'delete':
        await store.delete(this.key(call));
        result.success(null);
        break;
      case 'readAll':
        result.success(await store.readAll());
        break;
      case 'deleteAll':
        await store.deleteAll();
        result.success(null);
        break;
    }
  }
}
