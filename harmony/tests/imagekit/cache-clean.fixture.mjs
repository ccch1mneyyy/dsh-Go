// 真实原Store缓存污染回归；只有固定合成图和三份CC0 profile，不调用模型。
import assert from 'node:assert/strict';
import { mkdtemp,readFile,writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fixtures } from './fixtures.mjs';
import { profiles } from './profile-fixtures.mjs';
export async function checkKnownIccCache({Context,Store,helper,parentDirectory,nativeState}){
 const root=await mkdtemp(path.join(parentDirectory,'known-icc-cache-')),previous=process.env.DSH_HARMONY_DURABLE_ROOT,ctx=new Context();
 process.env.DSH_HARMONY_DURABLE_ROOT=root;
 try{
  await ctx.plugin(Store,{dshHome:path.join(root,'home')});const fixture=fixtures.find(f=>f.id==='opaque-png');
  const ref=await ctx.attachments.saveImage({data:Buffer.from(fixture.base64,'base64'),mediaType:'image/png'}),target={width:16,height:8,maxBytes:4096};
  const first=await ctx.attachments.readImageRequest(ref,target),clean=Buffer.from(first.data),digest=String(first.variantId).slice(7),cache=path.join(ctx.attachments.cacheRoot,'request-images',digest.slice(0,2),digest);
  assert.equal((await helper.probe(clean)).carriesMetadata,false);assert.equal(clean[0],255);assert.equal(clean[1],216);
  const profile=Buffer.from(profiles.find(p=>p.name==='sRGB-v4.icc').base64,'base64'),payload=Buffer.concat([Buffer.from('ICC_PROFILE\0','latin1'),Buffer.from([1,1]),profile]),app2=Buffer.alloc(4);app2[0]=255;app2[1]=226;app2.writeUInt16BE(payload.length+2,2);
  const polluted=Buffer.concat([clean.subarray(0,2),app2,payload,clean.subarray(2)]),facts=await helper.detect(polluted);
  assert.equal(facts.mediaType,'image/jpeg');assert.equal(facts.width,16);assert.equal(facts.height,8);assert.equal(facts.depth,'uchar');assert.equal(facts.space,'srgb');assert.equal(facts.hasAlpha,false);assert.equal(facts.carriesMetadata,true);
  await writeFile(cache,polluted);const before=nativeState.imageCalls,second=await ctx.attachments.readImageRequest(ref,target),returned=Buffer.from(second.data),disk=await readFile(cache),after=nativeState.imageCalls;
  const report={sourceParserAccepted:true,initialCacheClean:true,pollutionKnownIcc:true,pollutionSameSize:true,pollutionValid:true,pollutedBytesReturned:returned.equals(polluted),returnedClean:(await helper.probe(returned)).carriesMetadata===false,diskCacheClean:(await helper.probe(disk)).carriesMetadata===false,regenerated:after>before,restoredOriginalBytes:returned.equals(clean)&&disk.equals(clean),nextReadCacheHit:false};
  const nextBefore=nativeState.imageCalls,next=await ctx.attachments.readImageRequest(ref,target);report.nextReadCacheHit=nativeState.imageCalls===nextBefore&&Buffer.from(next.data).equals(returned);return report;
 }finally{await ctx.fiber.dispose();await helper.closeImagekitRuntime();if(previous===undefined)delete process.env.DSH_HARMONY_DURABLE_ROOT;else process.env.DSH_HARMONY_DURABLE_ROOT=previous;}
}
