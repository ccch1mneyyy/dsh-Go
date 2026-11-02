// 小型固定CC0 profile与合成PNG，只验有限源策略，不调用native或读取用户图。
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import test from 'node:test';
import { inspectContainer } from '../../plugins/dsh_runtime_ohos/assets/imagekit/container.mjs';
import { classifyProfile,MAX_ICC_BYTES } from '../../plugins/dsh_runtime_ohos/assets/imagekit/profile-policy.mjs';
import { profiles } from './profile-fixtures.mjs';
const imagekit=new URL('../../plugins/dsh_runtime_ohos/assets/imagekit/',import.meta.url),hash=b=>createHash('sha256').update(b).digest('hex');
function chunk(type,data){const name=Buffer.from(type),b=Buffer.alloc(data.length+12);b.writeUInt32BE(data.length);name.copy(b,4);data.copy(b,8);let crc=0xffffffff;for(const byte of Buffer.concat([name,data])){crc^=byte;for(let i=0;i<8;i++)crc=crc>>>1^(crc&1?0xedb88320:0);}b.writeUInt32BE((crc^0xffffffff)>>>0,data.length+8);return b;}
function png({profile,colour=2,transparent=false,compressed}={}){
 const header=Buffer.alloc(13);header.writeUInt32BE(2);header.writeUInt32BE(1,4);header[8]=8;header[9]=colour;
 const parts=[Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header)];
 if(profile||compressed)parts.push(chunk('iCCP',Buffer.concat([Buffer.from('fixed\0\0','latin1'),compressed??deflateSync(profile)])));
 if(transparent)parts.push(chunk('tRNS',Buffer.alloc(6)));
 const pixels=Buffer.alloc(1+2*(colour===6?4:3),255);pixels[0]=0;parts.push(chunk('IDAT',deflateSync(pixels)),chunk('IEND',Buffer.alloc(0)));return Buffer.concat(parts);
}
const rejects=b=>assert.throws(()=>inspectContainer(b),e=>e.code==='IMAGE_COLOR_PROFILE_UNSUPPORTED');
test('三族固定源与模板、许可摘要逐字节一致',()=>{
 const source=JSON.parse(readFileSync(new URL('profile-templates.SOURCES.json',imagekit))),templates=readFileSync(new URL('profile-templates.json',imagekit)),license=readFileSync(new URL(source.licenseFile,imagekit));
 assert.equal(source.commit,'bdd84663061bc4ae95ca70decff54f581e27f702');assert.equal(source.license,'CC0-1.0');assert.equal(hash(templates),source.templateSha256);assert.equal(hash(license),source.licenseSha256);assert.equal(profiles.length,3);
 for(const p of profiles){const bytes=Buffer.from(p.base64,'base64'),s=source.profiles.find(s=>s.path.endsWith('/'+p.name));assert.equal(bytes.length,480);assert.equal(hash(bytes),s.sha256);assert.equal(p.sha256,s.sha256);assert.equal(classifyProfile(bytes),JSON.parse(templates).find(t=>t.source===p.name).kind);const info=inspectContainer(png({profile:bytes}));assert.equal(info.hasProfile,true);assert.equal(info.carriesMetadata,true);assert.equal(info.hasAlpha,false);assert.equal(info.metadataKnown,true);}
});
test('RGBA与RGB加透明ICC均拒绝；无ICC alpha保留',()=>{
 const profile=Buffer.from(profiles[0].base64,'base64');rejects(png({profile,colour:6}));rejects(png({profile,transparent:true}));assert.equal(inspectContainer(png({colour:6})).hasAlpha,true);assert.equal(inspectContainer(png({transparent:true})).hasAlpha,true);
});
test('未知关键字段、坏profile及有界inflate严格拒绝',()=>{
 const profile=Buffer.from(profiles[0].base64,'base64'),unknown=Buffer.from(profile);unknown.fill(0,84,100);unknown[12]^=1;rejects(png({profile:unknown}));rejects(png({profile:profile.subarray(0,-1)}));rejects(png({compressed:deflateSync(Buffer.alloc(MAX_ICC_BYTES+1))}));rejects(png({compressed:Buffer.concat([deflateSync(profile),Buffer.from([1])])}));
});
test('有限非颜色身份变体可接受，颜色字段改变仍拒绝',()=>{
 const profile=Buffer.from(profiles[0].base64,'base64');profile.fill(0,84,100);profile.writeUInt16BE(2026,24);Buffer.from('test').copy(profile,80);assert.equal(classifyProfile(profile),'srgb');const changed=Buffer.from(profile);changed[64]^=1;assert.throws(()=>classifyProfile(changed),e=>e.code==='IMAGE_COLOR_PROFILE_UNSUPPORTED');
});
