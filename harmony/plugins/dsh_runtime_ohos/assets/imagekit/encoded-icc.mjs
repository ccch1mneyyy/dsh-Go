// 仅供已验证SRGB/RGBA8的系统新编码结果；禁止用于原输入或绕过strict容器解析。
import { ImageFailure } from './container.mjs';
const fail = () => { throw new ImageFailure('IMAGE_ENCODED_ICC_INVALID'); };
const signature = Buffer.from('ICC_PROFILE\0', 'latin1');
function profileComplete(parts) {
  const profile = Buffer.concat(parts);
  if (profile.length < 128 || profile.readUInt32BE(0) !== profile.length || profile.toString('latin1',36,40) !== 'acsp') fail();
}
function jpeg(data) {
  if (data[0] !== 255 || data[1] !== 216) fail();
  let at = 2, entropy = false, ended = false, count = 0;
  const groups = new Map(), remove = [];
  while (at < data.length) {
    if (entropy) {
      while (at < data.length) {
        if (data[at] !== 255) { at++; continue; }
        const begin = at++;
        while (data[at] === 255) at++;
        if (at >= data.length) fail();
        if (data[at] === 0 || data[at] >= 0xd0 && data[at] <= 0xd7) { at++; continue; }
        at = begin; entropy = false; break;
      }
      if (entropy) fail();
    }
    if (data[at++] !== 255) fail();
    while (data[at] === 255) at++;
    const marker = data[at++], markerStart = at - 2;
    if (marker === 0xd9) { if (at !== data.length) fail(); ended = true; break; }
    if (marker === 0xd8 || marker === 0 || marker >= 0xd0 && marker <= 0xd7 || at + 2 > data.length) fail();
    const length = data.readUInt16BE(at), start = at + 2, end = at + length;
    if (length < 2 || end > data.length) fail();
    if (marker === 0xe2 && data.subarray(start,Math.min(end,start+12)).equals(signature)) {
      if (end - start <= 14) fail();
      const sequence = data[start+12], total = data[start+13];
      if (!total || !sequence || sequence > total || (count && count !== total) || groups.has(sequence)) fail();
      count = total; groups.set(sequence,data.subarray(start+14,end)); remove.push([markerStart,end]);
    }
    at = end; entropy = marker === 0xda;
  }
  if (!ended || groups.size !== count) fail();
  if (!count) return { data, removed: false };
  profileComplete(Array.from({length:count},(_,i)=>groups.get(i+1) ?? fail()));
  const kept = []; let previous = 0;
  for (const [start,end] of remove) { kept.push(data.subarray(previous,start)); previous=end; }
  kept.push(data.subarray(previous));
  return { data: Buffer.concat(kept), removed: true };
}
function webp(data) {
  if (data.length < 12 || data.toString('latin1',0,4) !== 'RIFF' || data.toString('latin1',8,12) !== 'WEBP' || data.readUInt32LE(4)+8 !== data.length) fail();
  let at = 12, extended, icc, imageSeen = false;
  const chunks = [];
  while (at < data.length) {
    if (at + 8 > data.length) fail();
    const type = data.toString('latin1',at,at+4), size = data.readUInt32LE(at+4), end = at+8+size+(size&1);
    if (end > data.length) fail();
    const chunk = data.subarray(at,end); chunks.push({type,chunk});
    if (type === 'VP8X') { if (extended || size !== 10 || at !== 12) fail(); extended=chunk; }
    if (['VP8 ', 'VP8L', 'ANMF'].includes(type)) imageSeen = true;
    if (type === 'ICCP') { if (icc || !size || imageSeen || ((size&1) && chunk[chunk.length-1] !== 0)) fail(); icc=chunk.subarray(8,8+size); }
    at=end;
  }
  if (!!icc !== !!(extended && (extended[8]&32))) fail();
  if (!icc) return { data, removed: false };
  profileComplete([icc]);
  const kept = [Buffer.from(data.subarray(0,12))];
  for (const {type,chunk} of chunks) {
    if (type === 'ICCP') continue;
    if (type === 'VP8X') { const copy=Buffer.from(chunk); copy[8]&=~32; kept.push(copy); }
    else kept.push(chunk);
  }
  const output=Buffer.concat(kept); output.writeUInt32LE(output.length-8,4);
  return { data: output, removed: true };
}
export function cleanSystemEncodedIcc(data, mediaType) {
  if (!Buffer.isBuffer(data) || !data.length || data.length > 33554432) fail();
  if (mediaType === 'image/jpeg') return jpeg(data);
  if (mediaType === 'image/webp') return webp(data);
  fail();
}
