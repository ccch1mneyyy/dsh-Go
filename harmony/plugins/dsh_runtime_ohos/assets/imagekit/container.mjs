// 有界容器事实解析；未知元数据/颜色明确拒绝，不把缺少系统字段解释成clean。
export class ImageFailure extends Error { constructor(code) { super('图像候选拒绝输入'); this.code = code; } }
const fail = (code = 'INVALID_IMAGE') => { throw new ImageFailure(code); };
const text = (b, a, z) => b.toString('latin1', a, z);
const u24 = (b, at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16;
function crc32(bytes) { let crc = 0xffffffff; for (const byte of bytes) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); } return (crc ^ 0xffffffff) >>> 0; }
function orientationExif(bytes) {
  let b = bytes;
  if (text(b, 0, 6) === 'Exif\0\0') b = b.subarray(6);
  const little = text(b, 0, 2) === 'II';
  if (!little && text(b, 0, 2) !== 'MM') fail();
  const read16 = at => little ? b.readUInt16LE(at) : b.readUInt16BE(at);
  const read32 = at => little ? b.readUInt32LE(at) : b.readUInt32BE(at);
  if (read16(2) !== 42) fail();
  const offset = read32(4), count = read16(offset);
  if (count > 4096 || offset + 2 + count * 12 + 4 > b.length) fail();
  let orientation = 1;
  for (let i = 0; i < count; i++) {
    const at = offset + 2 + i * 12;
    if (read16(at) === 0x112) {
      if (read16(at + 2) !== 3 || read32(at + 4) !== 1) fail();
      orientation = read16(at + 8); if (orientation < 1 || orientation > 8) fail();
    }
  }
  return orientation;
}
function png(b) {
  let at = 8, width, height, depth, colour, alpha = false, orientation = 1, ended = false, data = false;
  const metadata = [];
  while (at + 12 <= b.length) {
    const n = b.readUInt32BE(at), type = text(b, at + 4, at + 8), start = at + 8, end = start + n;
    if (end + 4 > b.length || crc32(b.subarray(at + 4, end)) !== b.readUInt32BE(end)) fail();
    if (type === 'IHDR') {
      if (at !== 8 || n !== 13) fail();
      width = b.readUInt32BE(start); height = b.readUInt32BE(start + 4); depth = b[start + 8]; colour = b[start + 9];
      if (![0, 2, 3, 4, 6].includes(colour) || ![1, 2, 4, 8, 16].includes(depth) ||
          ([2, 4, 6].includes(colour) && depth < 8) || (colour === 3 && depth === 16) || b[start + 10] || b[start + 11] || b[start + 12] > 1) fail();
      alpha = colour === 4 || colour === 6;
    } else if (type === 'IDAT') data = true;
    else if (type === 'IEND') { if (n || end + 4 !== b.length) fail(); ended = true; break; }
    else if (type === 'tRNS') alpha = true;
    else if (type === 'eXIf') { metadata.push('exif'); orientation = orientationExif(b.subarray(start, end)); }
    else if (['tEXt', 'zTXt', 'iTXt', 'tIME'].includes(type)) metadata.push(type);
    else if (['iCCP', 'gAMA', 'cHRM', 'cICP', 'mDCv', 'cLLi'].includes(type)) fail('IMAGE_COLOR_PROFILE_UNSUPPORTED');
    else if (type === 'sRGB') { if (n !== 1 || b[start] > 3) fail(); }
    else if (!['PLTE', 'pHYs', 'sBIT', 'bKGD', 'hIST'].includes(type)) fail('IMAGE_METADATA_UNSUPPORTED');
    at = end + 4;
  }
  if (!ended || !data) fail();
  return { mediaType: 'image/png', rawWidth: width, rawHeight: height, orientation, pages: 1, hasAlpha: alpha, depth: depth === 16 ? 'ushort' : 'uchar', space: [0, 4].includes(colour) ? 'b-w' : depth === 16 ? 'rgb16' : 'srgb', metadata };
}
function jpeg(b) {
  let at = 2, width, height, components, orientation = 1, ended = false, entropy = false;
  const metadata = [];
  while (at < b.length) {
    if (entropy) {
      if (b[at++] !== 255) continue;
      while (b[at] === 255) at++;
      if (b[at] === 0 || b[at] >= 0xd0 && b[at] <= 0xd7) { at++; continue; }
      at--; entropy = false;
    }
    if (b[at++] !== 255) fail(); while (b[at] === 255) at++;
    const marker = b[at++];
    if (marker === 0xd9) { ended = at === b.length; break; }
    if (marker === 0xd8 || marker === 0 || marker >= 0xd0 && marker <= 0xd7) fail();
    const length = b.readUInt16BE(at), start = at + 2, end = at + length;
    if (length < 2 || end > b.length) fail();
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (width || b[start] !== 8) fail('IMAGE_COLOR_PROFILE_UNSUPPORTED');
      height = b.readUInt16BE(start + 1); width = b.readUInt16BE(start + 3); components = b[start + 5];
      if (![1, 3].includes(components)) fail('IMAGE_COLOR_PROFILE_UNSUPPORTED');
    } else if (marker === 0xe1) {
      metadata.push('app1');
      if (text(b, start, start + 6) === 'Exif\0\0') orientation = orientationExif(b.subarray(start, end));
      else if (!text(b, start, end).startsWith('http://ns.adobe.com/xap/1.0/')) fail('IMAGE_METADATA_UNSUPPORTED');
    } else if (marker === 0xe2 || marker === 0xee) fail('IMAGE_COLOR_PROFILE_UNSUPPORTED');
    else if (marker === 0xed || marker === 0xfe) metadata.push('jpeg-metadata');
    else if (marker === 0xe0) { if (!['JFIF\0', 'JFXX\0'].includes(text(b, start, start + 5))) fail('IMAGE_METADATA_UNSUPPORTED'); }
    else if (marker >= 0xe3 && marker <= 0xef) fail('IMAGE_METADATA_UNSUPPORTED');
    else if (![0xda, 0xdb, 0xc4, 0xdd].includes(marker) && ![0xc0, 0xc1, 0xc2].includes(marker)) fail();
    at = end; if (marker === 0xda) entropy = true;
  }
  if (!ended || !width || !height) fail();
  return { mediaType: 'image/jpeg', rawWidth: width, rawHeight: height, orientation, pages: 1, hasAlpha: false, depth: 'uchar', space: components === 1 ? 'b-w' : 'srgb', metadata };
}
function webp(b) {
  if (b.readUInt32LE(4) + 8 !== b.length) fail();
  let at = 12, width, height, alpha = false, image = false, orientation = 1; const metadata = [];
  while (at + 8 <= b.length) {
    const type = text(b, at, at + 4), n = b.readUInt32LE(at + 4), start = at + 8, end = start + n;
    if (end > b.length) fail();
    if (type === 'VP8X') {
      if (n !== 10 || b[start] & 0xc1 || b[start + 1] || b[start + 2] || b[start + 3]) fail();
      if (b[start] & 2) fail('IMAGE_ANIMATION_UNSUPPORTED');
      width = u24(b, start + 4) + 1; height = u24(b, start + 7) + 1; alpha = !!(b[start] & 16);
    } else if (type === 'VP8 ') {
      if (n < 10 || text(b, start + 3, start + 6) !== '\x9d\x01\x2a') fail();
      width ??= b.readUInt16LE(start + 6) & 0x3fff; height ??= b.readUInt16LE(start + 8) & 0x3fff; image = true;
    } else if (type === 'VP8L') {
      if (n < 5 || b[start] !== 47) fail(); const bits = b.readUInt32LE(start + 1);
      if (bits >>> 29) fail(); width ??= (bits & 0x3fff) + 1; height ??= (bits >>> 14 & 0x3fff) + 1; alpha ||= !!(bits >>> 28 & 1); image = true;
    } else if (type === 'ALPH') alpha = true;
    else if (type === 'EXIF') { metadata.push('exif'); orientation = orientationExif(b.subarray(start, end)); }
    else if (type === 'XMP ') metadata.push('xmp');
    else if (type === 'ICCP') fail('IMAGE_COLOR_PROFILE_UNSUPPORTED');
    else fail('IMAGE_METADATA_UNSUPPORTED');
    at = end + (n & 1);
  }
  if (at !== b.length || !image) fail();
  return { mediaType: 'image/webp', rawWidth: width, rawHeight: height, orientation, pages: 1, hasAlpha: alpha, depth: 'uchar', space: 'srgb', metadata };
}
function gif(b) {
  const width = b.readUInt16LE(6), height = b.readUInt16LE(8); let at = 13, pages = 0, alpha = false, transparency = false, ended = false;
  if (b[10] & 128) at += 3 * (1 << ((b[10] & 7) + 1)); const metadata = [];
  const blocks = () => { while (true) { if (at >= b.length) fail(); const n = b[at++]; if (!n) return; at += n; if (at > b.length) fail(); } };
  while (at < b.length) {
    const kind = b[at++];
    if (kind === 0x3b) { ended = at === b.length; break; }
    if (kind === 0x21) {
      const label = b[at++];
      if (label === 0xf9) { if (b[at] !== 4 || at + 6 > b.length || b[at + 5]) fail(); transparency = !!(b[at + 1] & 1); at += 6; }
      else if (label === 0xff) { const n = b[at++]; const id = text(b, at, at + n); at += n; if (!['NETSCAPE2.0', 'ANIMEXTS1.0'].includes(id)) fail('IMAGE_METADATA_UNSUPPORTED'); blocks(); }
      else if (label === 0xfe) { metadata.push('comments'); blocks(); }
      else fail('IMAGE_METADATA_UNSUPPORTED');
    } else if (kind === 0x2c) {
      if (at + 9 > b.length) fail();
      const left = b.readUInt16LE(at), top = b.readUInt16LE(at + 2), w = b.readUInt16LE(at + 4), h = b.readUInt16LE(at + 6), flags = b[at + 8];
      if (!w || !h || left + w > width || top + h > height) fail(); at += 9;
      if (flags & 128) at += 3 * (1 << ((flags & 7) + 1));
      if (b[at] < 2 || b[at] > 8) fail(); at++; blocks(); pages++;
      if (pages === 1) alpha = transparency; transparency = false;
    } else fail();
  }
  if (!ended || !pages) fail();
  return { mediaType: 'image/gif', rawWidth: width, rawHeight: height, orientation: 1, pages, hasAlpha: alpha, depth: 'uchar', space: 'srgb', metadata };
}
export function inspectContainer(bytes) {
  try {
    const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength); if (!b.length) fail(); if (b.length > 20971520) fail('IMAGE_TOO_LARGE');
    let info;
    if (b.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) info = png(b);
    else if (b[0] === 255 && b[1] === 216) info = jpeg(b);
    else if (text(b, 0, 4) === 'RIFF' && text(b, 8, 12) === 'WEBP') info = webp(b);
    else if (['GIF87a', 'GIF89a'].includes(text(b, 0, 6))) info = gif(b);
    else fail();
    if (!Number.isSafeInteger(info.rawWidth) || !Number.isSafeInteger(info.rawHeight) || !info.rawWidth || !info.rawHeight) fail();
    return { ...info, width: info.orientation >= 5 ? info.rawHeight : info.rawWidth, height: info.orientation >= 5 ? info.rawWidth : info.rawHeight, animated: info.pages > 1, carriesMetadata: info.metadata.length > 0, metadataKnown: true };
  } catch (error) { if (error instanceof ImageFailure) throw error; fail(); }
}
