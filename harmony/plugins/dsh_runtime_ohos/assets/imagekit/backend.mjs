import { ImageFailure } from './container.mjs';
import { createHeaderReader } from './header-reader.mjs';
export const IMAGEKIT_TRANSFORM_VERSION = 'request-image-imagekit-candidate-v2';
const fail = code => { throw new ImageFailure(code); };
const integer = value => Number.isSafeInteger(value) && value > 0;
const defaultLimits = { maxImageBytes: 20971520, maxImagePixels: 64000000, maxImageDimension: 8192 };
function limitsOf(given = {}) {
  const limits = { ...defaultLimits, ...given };
  if (!Object.values(limits).every(integer) || limits.maxImageBytes > 20971520 || limits.maxImagePixels > 64000000 || limits.maxImageDimension > 8192) fail('INVALID_IMAGE');
  return limits;
}
function checkLimits(data, info, limits) {
  if (data.byteLength > limits.maxImageBytes) fail('IMAGE_TOO_LARGE');
  if (info.width * info.height > limits.maxImagePixels) fail('IMAGE_TOO_MANY_PIXELS');
  if (Math.max(info.width, info.height) > limits.maxImageDimension) fail('IMAGE_DIMENSION_TOO_LARGE');
}
function dimensions(info, policy) {
  if (![policy.maxPixels, policy.maxDimension, policy.maxBytes].every(integer)) fail('INVALID_IMAGE');
  let width = info.width, height = info.height;
  if (width * height > policy.maxPixels) {
    const scale = Math.sqrt(policy.maxPixels / (width * height));
    if (width >= height) {
      width = Math.max(1, Math.floor(info.width * scale)); height = Math.max(1, Math.round(width * info.height / info.width));
      while (width * height > policy.maxPixels && width > 1) { width--; height = Math.max(1, Math.round(width * info.height / info.width)); }
    } else {
      height = Math.max(1, Math.floor(info.height * scale)); width = Math.max(1, Math.round(height * info.width / info.height));
      while (width * height > policy.maxPixels && height > 1) { height--; width = Math.max(1, Math.round(height * info.width / info.height)); }
    }
  }
  const edge = Math.max(width, height);
  if (edge > policy.maxDimension) { width = Math.max(1, Math.floor(width * policy.maxDimension / edge)); height = Math.max(1, Math.floor(height * policy.maxDimension / edge)); }
  return { width, height };
}
export function createImageKitBackend(binding) {
  const headers = createHeaderReader();
  const active = new Set(); let closed = false;
  const operation = body => (...args) => {
    if (closed) return Promise.reject(new ImageFailure('IMAGE_BACKEND_CLOSED'));
    const task = body(...args); active.add(task);
    task.then(() => active.delete(task), () => active.delete(task)); return task;
  };
  async function run(data, info, limits, options, signal) {
    signal?.throwIfAborted();
    let result;
    // 取消仅在native工作settle后返回；不能Promise.race后让像素工作继续无人持有。
    try { result = await binding.run(Buffer.from(data), { width: info.rawWidth, height: info.rawHeight, frames: info.pages,
      maxPixels: limits.maxImagePixels, maxDimension: limits.maxImageDimension, orientation: info.orientation, encode: false, ...options }); }
    catch (error) { signal?.throwIfAborted(); throw error; }
    signal?.throwIfAborted(); return result;
  }
  async function inspect(data, { fullDecode = true, limits: given, signal } = {}) {
    signal?.throwIfAborted(); const info = await headers.read(data), limits = limitsOf(given); signal?.throwIfAborted();
    checkLimits(data, info, limits);
    if (!fullDecode) return info;
    const decoded = await run(data, info, limits, {}, signal);
    if (decoded.width !== info.rawWidth || decoded.height !== info.rawHeight || typeof decoded.transparent !== 'boolean') fail('IMAGE_BACKEND_MISMATCH');
    if (!info.hasAlpha && decoded.transparent) fail('IMAGE_BACKEND_MISMATCH');
    return { ...info, transparent: decoded.transparent };
  }
  async function encoded(data, info, limits, target, maxBytes, signal) {
    const mediaType = info.hasAlpha ? 'image/webp' : 'image/jpeg'; let smallest;
    for (const quality of [85, 75, 60]) {
      const result = await run(data, info, limits, { encode: true, outWidth: target.width, outHeight: target.height, mediaType, quality }, signal);
      if (!Buffer.isBuffer(result.data) || result.data.length > 33554432 || result.width !== target.width || result.height !== target.height) fail('IMAGE_BACKEND_MISMATCH');
      signal?.throwIfAborted(); let cleaned;
      try { cleaned = await headers.cleanEncoded(result.data, mediaType); }
      catch (error) { signal?.throwIfAborted(); throw error; }
      signal?.throwIfAborted();
      const verified = await inspect(cleaned.data, { fullDecode: true, signal });
      if (verified.mediaType !== mediaType || verified.width !== result.width || verified.height !== result.height || verified.animated || verified.carriesMetadata ||
          verified.depth !== 'uchar' || verified.space !== 'srgb' || verified.orientation !== 1 ||
          (!info.hasAlpha && verified.hasAlpha) || (info.hasAlpha && !verified.hasAlpha && (mediaType !== 'image/webp' || info.transparent))) fail('ATTACHMENT_WRITE_FAILED');
      if (info.transparent && !verified.transparent) fail('ATTACHMENT_WRITE_FAILED');
      const candidate = { data: cleaned.data, mediaType, width: result.width, height: result.height };
      if (candidate.data.length <= maxBytes) return candidate;
      if (!smallest || candidate.data.length < smallest.data.length) smallest = candidate;
    }
    // 与原包一致：字节预算为编码目标，耗尽质量梯度时保留最小结果，不伪装已达硬上限。
    return smallest;
  }
  return {
    async close() { closed = true; await Promise.allSettled([...active]); await headers.close(); },
    inspect: operation(inspect),
    normalize: operation(async (input, policy, given, signal) => {
      const limits = limitsOf(given); if (input.data.byteLength > limits.maxImageBytes) fail('IMAGE_TOO_LARGE');
      const info = await inspect(input.data, { limits, signal });
      if (info.mediaType !== input.mediaType) fail('IMAGE_TYPE_MISMATCH');
      const target = dimensions(info, policy);
      if (info.mediaType !== 'image/gif' && !info.animated && !info.carriesMetadata && info.orientation === 1 && info.depth === 'uchar' && info.space === 'srgb' &&
          input.data.length <= policy.maxBytes && info.width * info.height <= policy.maxPixels && Math.max(info.width, info.height) <= policy.maxDimension) {
        return { data: input.data, mediaType: info.mediaType, width: info.width, height: info.height };
      }
      return encoded(input.data, info, limits, target, policy.maxBytes, signal);
    }),
    resizeNormalized: operation(async (attachment, target, signal) => {
      if (![target.width, target.height, target.maxBytes].every(integer)) fail('INVALID_ATTACHMENT_REF');
      const info = await inspect(attachment.data, { fullDecode: false, signal });
      if (info.width !== attachment.ref.width || info.height !== attachment.ref.height || info.mediaType !== attachment.ref.mediaType ||
          info.carriesMetadata || info.animated || info.depth !== 'uchar' || info.space !== 'srgb' || info.orientation !== 1) fail('ATTACHMENT_CORRUPT');
      if (target.width >= info.width && target.height >= info.height && attachment.data.length <= target.maxBytes) return { data: attachment.data, mediaType: info.mediaType, width: info.width, height: info.height };
      const full = await inspect(attachment.data, { signal });
      const scale = Math.min(1, info.width >= info.height ? target.width / info.width : target.height / info.height);
      return encoded(attachment.data, full, limitsOf(), { width: Math.max(1, Math.round(info.width * scale)), height: Math.max(1, Math.round(info.height * scale)) }, target.maxBytes, signal);
    })
  };
}
