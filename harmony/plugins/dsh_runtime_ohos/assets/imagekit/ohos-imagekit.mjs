// 固定SHA原模块的OHOS边界；Linux不加载本模块。仅使用同进程已授权的签名系统库。
import path from 'node:path';
import { AttachmentError } from '@deepseek-ai/dsh-attachment';
let runtime;
const machineCodes=new Set(['INVALID_IMAGE','IMAGE_TOO_LARGE','IMAGE_TOO_MANY_PIXELS','IMAGE_DIMENSION_TOO_LARGE','IMAGE_TYPE_MISMATCH','INVALID_ATTACHMENT_REF','ATTACHMENT_CORRUPT','ATTACHMENT_WRITE_FAILED','IMAGE_COLOR_PROFILE_UNSUPPORTED','IMAGE_METADATA_UNSUPPORTED','IMAGE_ANIMATION_UNSUPPORTED','IMAGE_BACKEND_BUSY']);
function platform() { if (/* OHOS_IMAGEKIT_HELPER_GATE */ process.platform !== 'openharmony') throw new Error('UNSUPPORTED_PLATFORM'); }
function library(name) { platform();const root=process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;if(!root||!path.isAbsolute(root)||root.includes('..'))throw new Error('SIGNED_LIBRARY_DIRECTORY_MISSING');const module={exports:{}};process.dlopen(module,path.join(root,name));return module.exports; }
async function backend() {
  return runtime ??= (async()=>{platform();const {createImageKitBackend,IMAGEKIT_TRANSFORM_VERSION}=await import('../../../../../../transport/imagekit-v3/backend.mjs');if(IMAGEKIT_TRANSFORM_VERSION!=='request-image-imagekit-candidate-v3')throw new Error('IMAGE_TRANSFORM_VERSION_MISMATCH');const native=library('libdsh_imagekit_candidate.so');if(typeof native.run!=='function')throw new Error('IMAGE_BINDING_MISSING');return createImageKitBackend(native);})();
}
// 原存储并发上界不变；同一系统后端的实际工作排队，避免正常多图被native忙拒绝。
let operationTail=Promise.resolve();
function operation(fallback,body) {
 const task=operationTail.then(body);
 operationTail=task.catch(()=>{});
 return task.catch(error=>{if(error instanceof AttachmentError||error?.name==='AbortError')throw error;throw new AttachmentError('鸿蒙图像处理失败。',machineCodes.has(error?.code)?error.code:fallback);});
}
function metadata(info) { return {mediaType:info.mediaType,width:info.width,height:info.height,animated:info.animated,carriesMetadata:info.carriesMetadata,depth:info.depth,space:info.space,hasAlpha:info.hasAlpha}; }
export async function probe(data) { return operation('INVALID_IMAGE',async()=> metadata(await (await backend()).inspect(data,{fullDecode:false}))); }
export async function detect(data,limits) { return operation('INVALID_IMAGE',async()=> metadata(await (await backend()).inspect(data,{limits:{maxImagePixels:Math.min(limits?.maxPixels??64000000,64000000),maxImageDimension:Math.min(limits?.maxDimension??8192,8192)}}))); }
export async function normalize(data,detected,policy) { return operation('ATTACHMENT_WRITE_FAILED',async()=> (await backend()).normalize({data,mediaType:detected.mediaType},policy)); }
export async function request(attachment,target) { return operation('ATTACHMENT_WRITE_FAILED',async()=> (await backend()).resizeNormalized(attachment,target)); }
function within(value,boundary) { const relative=path.relative(boundary,path.resolve(value));return relative!==''&&!path.isAbsolute(relative)&&relative!=='..'&&!relative.startsWith('..'+path.sep); }
export function durableBoundary(home) { platform();const root=process.env.DSH_HARMONY_DURABLE_ROOT;if(!root||!path.isAbsolute(root)||!within(home,path.resolve(root)))throw new AttachmentError('附件目录不在独立持久化边界内。','ATTACHMENT_WRITE_FAILED');return path.resolve(root); }
let publisher;
export function publishStaged(source,target) { const root=process.env.DSH_HARMONY_DURABLE_ROOT;durableBoundary(source);durableBoundary(target);if(!root||!within(source,path.resolve(root))||!within(target,path.resolve(root)))throw new AttachmentError('附件发布越界。','ATTACHMENT_WRITE_FAILED');publisher??=library('libdsh_publish.so');if(typeof publisher.publishNoReplaceSync!=='function')throw new AttachmentError('附件发布接口不可用。','ATTACHMENT_WRITE_FAILED');return publisher.publishNoReplaceSync(source,target); }
export function closeImagekitRuntime() { return operation('ATTACHMENT_WRITE_FAILED',async()=>{if(runtime){const current=runtime;runtime=undefined;await(await current).close();}}); }
