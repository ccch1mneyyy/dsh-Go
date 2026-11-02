// 仅Windows隔离宿主替身：真实Sharp固定图编码；不进入设备或生产包。
import { createRequire } from 'node:module';
import { linkSync, unlinkSync } from 'node:fs';
import { cleanSystemEncodedIcc } from '../../plugins/dsh_runtime_ohos/assets/imagekit/encoded-icc.mjs';
const sharp=createRequire(import.meta.url)(process.env.DSH_TEST_SHARP_MODULE);
export const state={imageCalls:0,publishes:0,publishEexist:0,qualities:[],cleanLengths:[],barrier:undefined,failNext:false};
export function holdNextEncode(){const started=Promise.withResolvers(),release=Promise.withResolvers();const barrier={started,release};state.barrier=barrier;return barrier;}
async function run(data,options){
 state.imageCalls++;
 if(state.failNext){state.failNext=false;throw new Error('PRIVATE_SENTINEL',{cause:{token:'PRIVATE_SENTINEL'}});}
 const meta=await sharp(data,{animated:true}).metadata();
 if(meta.width!==options.width||(meta.pageHeight??meta.height)!==options.height)throw Object.assign(new Error(),{code:'IMAGE_BACKEND_MISMATCH'});
 const raw=await sharp(data).toColourspace('srgb').ensureAlpha().raw().toBuffer();let transparent=false;for(let i=3;i<raw.length;i+=4)transparent ||= raw[i]<255;
 if(!options.encode)return{width:options.width,height:options.height,transparent};
 state.qualities.push(options.quality);
 let image=sharp(data).rotate().toColourspace('srgb').resize({width:options.outWidth,height:options.outHeight,fit:'inside',withoutEnlargement:true}).withIccProfile('srgb');
 image=options.mediaType==='image/webp'?image.webp({quality:options.quality,effort:0}):image.jpeg({quality:options.quality});
 const work=image.toBuffer({resolveWithObject:true}),barrier=state.barrier;
 if(barrier){state.barrier=undefined;barrier.started.resolve();await barrier.release.promise;}
 const out=await work;state.cleanLengths.push(cleanSystemEncodedIcc(out.data,options.mediaType).data.length);return{data:out.data,width:out.info.width,height:out.info.height,transparent};
}
export function hostNativeFor(name){if(name==='libdsh_imagekit_candidate.so')return{run};if(name==='libdsh_publish.so')return{publishNoReplaceSync(source,target){try{linkSync(source,target);}catch(error){if(error?.code==='EEXIST')state.publishEexist++;throw error;}unlinkSync(source);state.publishes++;}};throw new Error('HOST_NATIVE_UNKNOWN');}
