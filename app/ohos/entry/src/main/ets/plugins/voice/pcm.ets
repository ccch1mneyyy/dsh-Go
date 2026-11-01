// 与原识别协议保持一致：16kHz、单声道、PCM16，小端44字节WAV头。
export function pcm16Wave(chunks: Uint8Array[], bytes: number): Uint8Array {
  const output = new Uint8Array(44 + bytes);
  const header = new DataView(output.buffer);
  const text = (offset: number, value: string): void => {
    for (let i = 0; i < value.length; i++) output[offset + i] = value.charCodeAt(i);
  };
  text(0, 'RIFF'); header.setUint32(4, 36 + bytes, true); text(8, 'WAVE'); text(12, 'fmt ');
  header.setUint32(16, 16, true); header.setUint16(20, 1, true); header.setUint16(22, 1, true);
  header.setUint32(24, 16000, true); header.setUint32(28, 32000, true);
  header.setUint16(32, 2, true); header.setUint16(34, 16, true); text(36, 'data'); header.setUint32(40, bytes, true);
  let offset = 44;
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.length; }
  return output;
}

export function pcmLevel(chunk: Uint8Array): number {
  const view = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  let sum = 0;
  for (let i = 0; i + 1 < chunk.length; i += 2) { const sample = view.getInt16(i, true); sum += sample * sample; }
  const rms = chunk.length > 0 ? Math.sqrt(sum / (chunk.length / 2)) / 32768 : 0;
  return rms > 0 ? Math.max(0, Math.min(1, (20 * Math.log10(rms) + 50) / 40)) : 0;
}
