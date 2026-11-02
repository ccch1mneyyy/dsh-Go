import { parentPort } from 'node:worker_threads';
import { inspectContainer, ImageFailure } from './container.mjs';
import { cleanSystemEncodedIcc } from './encoded-icc.mjs';
parentPort.on('message', ({ id, operation, mediaType, bytes }) => {
  try {
    const data = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (operation === 'inspect') parentPort.postMessage({ id, info: inspectContainer(data) });
    else if (operation === 'clean-encoded') parentPort.postMessage({ id, info: cleanSystemEncodedIcc(data, mediaType) });
    else throw new ImageFailure('INVALID_IMAGE');
  }
  catch (error) { parentPort.postMessage({ id, errorCode: error instanceof ImageFailure ? error.code : 'INVALID_IMAGE' }); }
});
