import { unknownIccJpeg } from '../profile-fixtures.mjs';
// 原Tools/AttachmentStore隔离验收，仅新建固定图和私有临时树，不挂CLI/模型/凭据服务。
import { mkdtemp,mkdir,writeFile,readFile,readdir,stat,chmod,unlink } from 'node:fs/promises';
import { join,isAbsolute,relative,sep } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { fixtures } from '../fixtures.mjs';
const checkKeys=['originalTool','fixtureIntegrity','sixFixtures','digestVerified','alphaPreserved','normalization','admission','countLimit','totalBytesLimit','singleBytesLimit','pixelLimit','dimensionLimit','mimeMismatch','invalidBase64','truncatedRejected','sourceIccRejected','noPartialBatch','dedupVerified','requestResize','cacheHit','cacheVersionSeparated','cacheCorruptionRecovered','qualityBudget','cancelledRequest','cancelledTool','cancelNoCache','disposed','batchSix','parallelReadSix','compressionEight','queueRecovery'];
const stages=new Set(['setup','read-image','concurrency','admission','limits','source-icc','batch-atomic','dedup','request-cache','quality-budget','cancel','dispose','complete']);
const codes=new Set(['NONE','UNSUPPORTED_PLATFORM','EXTERNAL_ERROR','ORIGINAL_TOOL_FAILED','PROBE_ASSERTION_FAILED','FIXTURE_INTEGRITY','NETWORK_ATTEMPT','IMAGE_TOO_LARGE','IMAGE_TOO_MANY_PIXELS','IMAGE_DIMENSION_TOO_LARGE','IMAGE_TYPE_MISMATCH','INVALID_IMAGE','INVALID_IMAGE_BASE64','TOO_MANY_IMAGES','IMAGES_TOO_LARGE','IMAGE_COLOR_PROFILE_UNSUPPORTED','IMAGE_METADATA_UNSUPPORTED','IMAGE_ANIMATION_UNSUPPORTED','ATTACHMENT_WRITE_FAILED','ATTACHMENT_CORRUPT','INVALID_ATTACHMENT_REF','IMAGE_BACKEND_BUSY']);
const fail=()=>{throw Object.assign(new Error(),{code:'PROBE_ASSERTION_FAILED'});};const expect=v=>{if(!v)fail();};
const hash=data=>createHash('sha256').update(data).digest('hex');
async function rejects(task,code){try{await task();}catch(error){if(error?.code===code)return;throw error;}fail();}
export function projectOriginalReport(r){return{schema:2,kind:'imagekit-original-dsh-tool',transformVersion:'request-image-imagekit-candidate-v3',phase:['RUNNING','PASSED','FAILED'].includes(r.phase)?r.phase:'FAILED',stage:stages.has(r.stage)?r.stage:'setup',errorCode:codes.has(r.errorCode)?r.errorCode:'EXTERNAL_ERROR',sourceFixtures:Number.isInteger(r.sourceFixtures)&&r.sourceFixtures>=0&&r.sourceFixtures<=6?r.sourceFixtures:0,checks:Object.fromEntries(checkKeys.map(k=>[k,r.checks?.[k]===true])),profileTested:false,modelRequestSent:false,credentialsRead:false,userImageRead:false,productionIntegrated:false};}
export async function runOriginalToolProbe({modulesRoot,fixtureParent,onProgress=()=>{},observe=()=>{},controls}){
 const report={phase:'RUNNING',stage:'setup',errorCode:'NONE',sourceFixtures:0,checks:{}};
 let ctx,helper;const oldFetch=globalThis.fetch;let networkAttempts=0;globalThis.fetch=()=>{networkAttempts++;throw Object.assign(new Error(),{code:'NETWORK_ATTEMPT'});};
 const progress=stage=>{report.stage=stage;onProgress(projectOriginalReport(report));};
 try{
  expect(isAbsolute(modulesRoot)&&isAbsolute(fixtureParent));progress('setup');
  const root=await mkdtemp(join(fixtureParent,'original-images-'));process.env.DSH_HARMONY_DURABLE_ROOT=root;
  const workspace=join(root,'workspace');await mkdir(workspace);
  const require=createRequire(join(modulesRoot,'original-image-fixture.cjs')),load=name=>import(pathToFileURL(require.resolve('@deepseek-ai/'+name)).href);
  const {Context}=await load('cordis'),{default:SystemPrompt}=await load('dsh-system-prompt'),{default:Tools}=await load('dsh-tools'),{default:LocalFS}=await load('dsh-fs-local'),{default:Store,requestImageVariantId}=await load('dsh-attachment-local'),toolPlugin=await load('dsh-tool-fs'),{admitEncodedImages}=await load('dsh-attachment');
  helper=await import(new URL('./ohos-imagekit.mjs',pathToFileURL(require.resolve('@deepseek-ai/dsh-attachment-local'))).href);
  ctx=new Context();await ctx.plugin(SystemPrompt,{includeHarnessIdentity:false});await ctx.plugin(Tools);await ctx.plugin(LocalFS,{cwd:workspace});
  await ctx.plugin(Store,{dshHome:join(root,'home'),maxImageBytes:8192,maxImagesPerMessage:2,maxMessageImageBytes:16384,maxImagePixels:4096,maxImageDimension:64,normalizedImageMaxPixels:128,normalizedImageMaxDimension:16,normalizedImageMaxBytes:4096});
  expect(relative(root,ctx.attachments.cacheRoot)!=='..'&&!relative(root,ctx.attachments.cacheRoot).startsWith('..'+sep));
  ctx.provide('workingDirectory',{ensure:async()=>workspace});ctx.provide('llm',{resolveModelInfo:async()=>({inputModalities:['image']})});await ctx.plugin(toolPlugin,{read:false,readImage:true,write:false,edit:false});
  const agent={ctx,options:{provider:'fixed-image-metadata-only',model:'no-generation'},session:{requestHeader:()=>undefined}};let serial=0;
  const execute=(file,signal=new AbortController().signal)=>ctx.tools.execute({name:'read_image',callId:'original-fixed-'+ ++serial,agent,arguments:{file_path:file},signal});
  for(const fixture of fixtures)expect(hash(Buffer.from(fixture.base64,'base64'))===fixture.sha256);report.checks.fixtureIntegrity=true;
  progress('read-image');expect(ctx.tools.schemas().some(t=>t.name==='read_image'));report.checks.originalTool=true;
  let original;
  for(const fixture of fixtures.filter(f=>f.id!=='oriented-jpeg')){
   const data=Buffer.from(fixture.base64,'base64'),name=fixture.id+'.'+fixture.mediaType.slice(6);await writeFile(join(workspace,name),data,{flag:'wx',mode:0o600});
   const result=await execute(name);if(result.isError){const code=result.error?.code??result.error?.cause?.code;throw Object.assign(new Error(),{code:codes.has(code)&&code!=='NONE'?code:'ORIGINAL_TOOL_FAILED'});}expect(result.value?.image);const ref=result.value.image,stored=await ctx.attachments.readImage(ref);
   expect(ref.width===(fixture.id==='sixteen-png'?8:16)&&ref.height===(fixture.id==='sixteen-png'?4:8));expect('sha256:'+hash(stored.data)===ref.attachmentId);report.checks.digestVerified=true;
   const info=await helper.detect(stored.data);expect(Object.keys(info).sort().join(',')==='animated,carriesMetadata,depth,hasAlpha,height,mediaType,space,width');expect(info.depth==='uchar'&&info.space==='srgb'&&!info.animated&&!info.carriesMetadata);
   if(fixture.id.startsWith('alpha-')){expect(info.hasAlpha);report.checks.alphaPreserved=true;}
   if(!original)original={fixture,data,ref};report.sourceFixtures++;
  }
  report.checks.sixFixtures=report.sourceFixtures===6;report.checks.normalization=true;
  progress('concurrency');const multiple=new Context(),high=new Context();
  const six=fixtures.filter(f=>f.id!=='oriented-jpeg').map(f=>({data:Buffer.from(f.base64,'base64'),mediaType:f.mediaType}));
  try{await multiple.plugin(Store,{dshHome:join(root,'multiple'),maxImagesPerMessage:8,normalizedImageMaxPixels:128,normalizedImageMaxDimension:16,normalizedImageMaxBytes:4096});const refs=await multiple.attachments.saveImages(six);expect(refs.length===6);report.checks.batchSix=true;const data=await Promise.all(refs.map(ref=>multiple.attachments.readImage(ref)));expect(data.every((stored,i)=>'sha256:'+hash(stored.data)===refs[i].attachmentId));report.checks.parallelReadSix=true;
   await high.plugin(Store,{dshHome:join(root,'compression-eight'),maxImagesPerMessage:8,imageCompressionConcurrency:8,normalizedImageMaxPixels:128,normalizedImageMaxDimension:16,normalizedImageMaxBytes:4096});expect(high.attachments.imageCompressionConcurrency===8);expect((await high.attachments.saveImages(six)).length===6);report.checks.compressionEight=true;
  }finally{await multiple.fiber.dispose();await high.fiber.dispose();}
  progress('admission');const admitted=await admitEncodedImages(ctx.attachments,[{data:original.fixture.base64,mediaType:'image/png'}]);expect(admitted.length===1&&admitted[0].width===16);report.checks.admission=true;
  const input={data:original.data,mediaType:'image/png'};progress('limits');
  for(const [key,task,code] of [
   ['countLimit',()=>ctx.attachments.saveImages([input,input,input]),'TOO_MANY_IMAGES'],
   ['totalBytesLimit',()=>ctx.attachments.saveImages([{...input,data:new Uint8Array(9000)},{...input,data:new Uint8Array(9000)}]),'IMAGES_TOO_LARGE'],
   ['singleBytesLimit',()=>ctx.attachments.saveImages([{...input,data:new Uint8Array(8193)}]),'IMAGE_TOO_LARGE'],
   ['mimeMismatch',()=>ctx.attachments.saveImages([{...input,mediaType:'image/jpeg'}]),'IMAGE_TYPE_MISMATCH'],
   ['invalidBase64',()=>admitEncodedImages(ctx.attachments,[{data:'INVALID',mediaType:'image/png'}]),'INVALID_IMAGE_BASE64'],
   ['truncatedRejected',()=>ctx.attachments.saveImages([{...input,data:original.data.subarray(0,40)}]),'INVALID_IMAGE']]){await rejects(task,code);report.checks[key]=true;}
  for(const[key,config,code]of[['pixelLimit',{maxImagePixels:100},'IMAGE_TOO_MANY_PIXELS'],['dimensionLimit',{maxImageDimension:16},'IMAGE_DIMENSION_TOO_LARGE']]){const limited=new Context();try{await limited.plugin(Store,{dshHome:join(root,key),...config});await rejects(()=>limited.attachments.saveImages([input]),code);report.checks[key]=true;}finally{await limited.fiber.dispose();}}
  progress('source-icc');await observe('before-source-icc');await rejects(()=>ctx.attachments.saveImage({data:unknownIccJpeg(Buffer.from(fixtures.find(f=>f.id==='oriented-jpeg').base64,'base64')),mediaType:'image/jpeg'}),'IMAGE_COLOR_PROFILE_UNSUPPORTED');await observe('after-source-icc');report.checks.sourceIccRejected=true;
  const recovery=await Promise.allSettled([ctx.attachments.saveImage({data:unknownIccJpeg(Buffer.from(fixtures.find(f=>f.id==='oriented-jpeg').base64,'base64')),mediaType:'image/jpeg'}),ctx.attachments.saveImage(input)]);expect(recovery[0].status==='rejected'&&recovery[0].reason?.code==='IMAGE_COLOR_PROFILE_UNSUPPORTED'&&recovery[1].status==='fulfilled'&&recovery[1].value.attachmentId===original.ref.attachmentId);report.checks.queueRecovery=true;
  progress('batch-atomic');const batch=new Context();try{await batch.plugin(Store,{dshHome:join(root,'batch')});await rejects(()=>batch.attachments.saveImages([input,{...input,data:original.data.subarray(0,40)}]),'INVALID_IMAGE');const deadline=Date.now()+10000;while(batch.attachments.compression.active||batch.attachments.compression.waiting.length){expect(Date.now()<deadline);await new Promise(resolve=>setTimeout(resolve,1));}let files=[];try{files=await readdir(join(root,'batch/attachments/v1/objects'));}catch(error){if(error?.code!=='ENOENT')throw error;}expect(files.length===0);report.checks.noPartialBatch=true;}finally{await batch.fiber.dispose();}
  progress('dedup');const object=ctx.attachments.imageHostPath(original.ref);expect(relative(root,object)!=='..'&&!relative(root,object).startsWith('..'+sep));await chmod(object,0o600);await unlink(object);await observe('before-publish-concurrent');
  const duplicates=await Promise.all([ctx.attachments.saveImage(input),ctx.attachments.saveImage(input)]);expect(duplicates.every(ref=>ref.attachmentId===original.ref.attachmentId));await observe('after-publish-concurrent');
  const corrupt=Buffer.from('fixed-corrupt-winner');await chmod(object,0o600);await writeFile(object,corrupt);await rejects(()=>ctx.attachments.saveImage(input),'ATTACHMENT_CORRUPT');expect(Buffer.from(await readFile(object)).equals(corrupt));await unlink(object);const repeated=await ctx.attachments.saveImage(input);expect(repeated.attachmentId===original.ref.attachmentId);expect('sha256:'+hash((await ctx.attachments.readImage(repeated)).data)===repeated.attachmentId);report.checks.dedupVerified=true;
  progress('request-cache');const target={width:8,height:4,maxBytes:4096},version=await ctx.attachments.readImageRequest(admitted[0],target);await observe('before-cache-repeat');const again=await ctx.attachments.readImageRequest(admitted[0],target);await observe('after-cache-repeat');
  expect(version.width===8&&version.height===4&&version.depth==='uchar'&&version.space==='srgb');report.checks.requestResize=true;expect(version.variantId===again.variantId&&Buffer.from(version.data).equals(Buffer.from(again.data)));report.checks.cacheHit=true;
  const cacheFile=join(ctx.attachments.cacheRoot,'request-images',String(version.variantId).slice(7,9),String(version.variantId).slice(7));expect(Buffer.from(await readFile(cacheFile)).equals(Buffer.from(version.data)));
  const descriptor={transformVersion:'request-image-v6',attachmentId:admitted[0].attachmentId,targetWidth:8,targetHeight:4,encodedByteBudget:4096,encoding:{webpQualities:[85,75,60],webpEffort:0,jpegQualities:[85,75,60],order:['alpha:webp','opaque:jpeg'],colourspace:'srgb'}};
  expect('sha256:'+hash(JSON.stringify(descriptor))!==version.variantId&&requestImageVariantId(admitted[0],target)===version.variantId);descriptor.transformVersion='request-image-imagekit-candidate-v2';expect('sha256:'+hash(JSON.stringify(descriptor))!==version.variantId);descriptor.transformVersion='request-image-imagekit-candidate-v3';expect('sha256:'+hash(JSON.stringify(descriptor))===version.variantId);report.checks.cacheVersionSeparated=true;
  await observe('before-corrupt-cache');await writeFile(cacheFile,Buffer.from('fixed-corrupt-cache'),{mode:0o600});const recovered=await ctx.attachments.readImageRequest(admitted[0],target);expect(recovered.width===8&&recovered.height===4&&Buffer.from(await readFile(cacheFile)).equals(Buffer.from(recovered.data)));await observe('after-corrupt-cache');report.checks.cacheCorruptionRecovered=true;
  progress('quality-budget');await observe('before-budget');const low={width:8,height:4,maxBytes:1},budget=await ctx.attachments.readImageRequest(admitted[0],low);expect(budget.bytes>1&&budget.width===8&&budget.height===4);await observe('after-budget',budget);report.checks.qualityBudget=true;
  if(controls)await controls({ctx,ref:admitted[0],requestImageVariantId,root,helper});
  progress('cancel');const aborted=AbortSignal.abort();try{await ctx.attachments.readImageRequest(admitted[0],target,aborted);fail();}catch(error){expect(error?.name==='AbortError');report.checks.cancelledRequest=true;}
  expect((await execute('opaque-png.png',aborted)).isError===true);report.checks.cancelledTool=true;
  const unseen={width:5,height:3,maxBytes:4096},abort=new AbortController(),cancelled=ctx.attachments.readImageRequest(admitted[0],unseen,abort.signal),operation=ctx.attachments.requestInflight.get(String(requestImageVariantId(admitted[0],unseen)));abort.abort();try{await cancelled;fail();}catch(error){expect(error?.name==='AbortError');}await operation.promise.catch(()=>{});
  const unseenHash=String(requestImageVariantId(admitted[0],unseen)).slice(7);let exists=true;try{await stat(join(ctx.attachments.cacheRoot,'request-images',unseenHash.slice(0,2),unseenHash));}catch(error){if(error?.code!=='ENOENT')throw error;exists=false;}expect(!exists);report.checks.cancelNoCache=true;
  expect(networkAttempts===0);progress('dispose');await ctx.fiber.dispose();ctx=undefined;await helper.closeImagekitRuntime();report.checks.disposed=true;
  expect(checkKeys.every(k=>report.checks[k]===true));report.phase='PASSED';report.stage='complete';
 }catch(error){report.phase='FAILED';report.errorCode=codes.has(error?.code)&&error.code!=='NONE'?error.code:'EXTERNAL_ERROR';}
 finally{if(ctx)await ctx.fiber.dispose().catch(()=>{});if(helper)await helper.closeImagekitRuntime().catch(()=>{});globalThis.fetch=oldFetch;}
 return projectOriginalReport(report);
}
