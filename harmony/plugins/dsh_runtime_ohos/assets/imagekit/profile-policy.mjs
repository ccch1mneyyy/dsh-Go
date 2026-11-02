// 严格有限的ICC身份匹配，不拟合曲线、不做颜色转换、不接受任意matrix/TRC。
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const templates = JSON.parse(readFileSync(new URL('./profile-templates.json', import.meta.url)));
export const MAX_ICC_BYTES = 65536;
export class IccFailure extends Error { constructor() { super('ICC不在已验证有限集合'); this.code = 'IMAGE_COLOR_PROFILE_UNSUPPORTED'; } }
const fail = () => { throw new IccFailure(); };
const allowedTags = ['desc','cprt','wtpt','chad','rXYZ','gXYZ','bXYZ','rTRC','gTRC','bTRC'];
function validDate(b) {
  const values = Array.from({length:6}, (_,i) => b.readUInt16BE(24+i*2));
  const [year,month,day,hour,minute,second] = values;
  const leap = year%4===0 && (year%100!==0 || year%400===0);
  return year>=1 && month>=1 && month<=12 && day>=1 && day<=[31,leap?29:28,31,30,31,30,31,31,30,31,30,31][month-1] && hour<24 && minute<60 && second<60;
}
function profileId(b) {
  if (b.subarray(84,100).every(x=>x===0)) return;
  const copied = Buffer.from(b); copied.fill(0,44,48); copied.fill(0,64,68); copied.fill(0,84,100);
  if (!createHash('md5').update(copied).digest().equals(b.subarray(84,100))) fail();
}
function copyright(data) {
  if (data.length<28 || data.length>4096 || data.toString('latin1',0,4)!=='mluc' || data.readUInt32BE(4)!==0 || data.readUInt32BE(12)!==12) fail();
  const count=data.readUInt32BE(8),start=16+count*12,locales=new Set(),ranges=[];
  if(count<1||count>8||start>data.length)fail();
  for(let i=0;i<count;i++){
    const at=16+i*12,locale=data.readUInt32BE(at),length=data.readUInt32BE(at+4),offset=data.readUInt32BE(at+8);
    if(locales.has(locale)||!data.subarray(at,at+4).every(v=>v>=65&&v<=90||v>=97&&v<=122)||length<2||length>1024||length%2||offset%2||offset<start||offset>data.length-length)fail();
    locales.add(locale);ranges.push({start:offset,end:offset+length});
    for(let p=offset;p<offset+length;p+=2){const v=data.readUInt16BE(p);if(v<32||v>126)fail();}
  }
  ranges.sort((a,b)=>a.start-b.start||a.end-b.end);let cursor=start,last;
  for(const range of ranges){if(last&&range.start===last.start&&range.end===last.end)continue;if(range.start<cursor||!data.subarray(cursor,range.start).every(v=>v===0))fail();cursor=range.end;last=range;}
  if(!data.subarray(cursor).every(v=>v===0))fail();
}
export function classifyProfile(value) {
  try {
    const b=Buffer.from(value.buffer,value.byteOffset,value.byteLength);
    if(b.length<132||b.length>MAX_ICC_BYTES||b.readUInt32BE(0)!==b.length||b.toString('latin1',36,40)!=='acsp'||!validDate(b))fail();
    if(!b.subarray(80,84).every(v=>v===0||v>=32&&v<=126))fail();
    profileId(b);
    const count=b.readUInt32BE(128),start=132+12*count,tags=new Map(),ranges=[];
    if(count!==allowedTags.length||start>b.length)fail();
    for(let i=0;i<count;i++){
      const at=132+i*12,name=b.toString('latin1',at,at+4),offset=b.readUInt32BE(at+4),size=b.readUInt32BE(at+8);
      if(!allowedTags.includes(name)||tags.has(name)||offset%4||offset<start||size<8||offset>b.length-size)fail();
      tags.set(name,b.subarray(offset,offset+size));ranges.push({start:offset,end:offset+size});
    }
    ranges.sort((a,b)=>a.start-b.start||a.end-b.end);let cursor=start,last;
    for(const range of ranges){
      if(last&&range.start===last.start&&range.end===last.end)continue;
      if(range.start!==cursor)fail();
      const padded=(range.end+3)&~3;if(padded>b.length||!b.subarray(range.end,padded).every(v=>v===0))fail();
      cursor=padded;last=range;
    }
    if(cursor!==b.length)fail();
    copyright(tags.get('cprt'));
    const header=Buffer.from(b.subarray(0,128));header.fill(0,0,4);header.fill(0,24,36);header.fill(0,80,100);
    for(const template of templates){
      if(header.toString('hex')!==template.header)continue;
      if(Object.entries(template.tags).every(([name,hex])=>tags.get(name).toString('hex')===hex))return template.kind;
    }
    fail();
  }catch(error){if(error instanceof IccFailure)throw error;fail();}
}
