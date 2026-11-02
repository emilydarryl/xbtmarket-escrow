// Bounded production-only PSBT shape: one input, one/two P2WPKH outputs, no RBF.
const need=(v,m)=>{if(!v)throw Error(m);};
export const sized=b=>{need(b.length<253,'Unsupported field size.');return Buffer.concat([Buffer.from([b.length]),b]);};
export const u32=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
export const u64=n=>{const b=Buffer.alloc(8);b.writeBigUInt64LE(BigInt(n));return b;};
export const psbtMap=m=>Buffer.concat([...m].flatMap(([k,v])=>[sized(Buffer.from(k,'hex')),sized(v)]).concat([Buffer.from([0])]));
class Reader{
 constructor(bytes){this.bytes=bytes;this.offset=0;}
 take(n){need(Number.isSafeInteger(n)&&n>=0&&this.offset+n<=this.bytes.length,'Truncated PSBT.');const b=this.bytes.subarray(this.offset,this.offset+n);this.offset+=n;return b;}
 count(){const n=this.take(1)[0];need(n<253,'Oversized/noncanonical PSBT field.');return n;}
 map(){const m=new Map();for(;;){const n=this.count();if(!n)return m;need(m.size<8,'Too many PSBT fields.');const k=this.take(n).toString('hex');need(!m.has(k),'Duplicate PSBT key.');m.set(k,this.take(this.count()));}}
 done(){need(this.offset===this.bytes.length,'Trailing PSBT data.');}
}
export function parseProductionPsbt(encoded,signed=false){
 need(typeof encoded==='string'&&encoded.length<=12000,'Bounded PSBT required.');const bytes=Buffer.from(encoded,'base64');need(bytes.toString('base64')===encoded,'Canonical base64 required.');const r=new Reader(bytes);need(r.take(5).toString('hex')==='70736274ff','PSBT v0 required.');
 const global=r.map();need(global.size===1&&global.has('00'),'Only an unsigned transaction is allowed.');const raw=global.get('00'),t=new Reader(raw),version=t.take(4);need(version.equals(u32(2))&&t.count()===1,'Single version-2 input required.');const prevout=t.take(36);need(t.count()===0,'Empty input script required.');const sequence=t.take(4);need(sequence.equals(u32(0xfffffffe)),'Replacement is not authorized.');
 const count=t.count();need(count===1||count===2,'One or two outputs required.');const outputs=[];for(let i=0;i<count;i++){const amount=t.take(8),script=t.take(t.count());need(script.length===22&&script[0]===0&&script[1]===20,'P2WPKH outputs required.');outputs.push({value:amount.readBigUInt64LE(),script,serialized:Buffer.concat([amount,sized(script)])});}
 const locktime=t.take(4);need(locktime.equals(u32(0)),'Zero locktime required.');t.done();const input=r.map(),outputMaps=outputs.map(()=>r.map());r.done();need(outputMaps.every(m=>m.size===0),'No output metadata allowed.');
 need(['01','03','05'].every(k=>input.has(k))&&input.get('03').equals(u32(0x21)),'Exact ALL|UNIFIED witness data required.');for(const k of input.keys())need(['01','03','05'].includes(k)||(signed&&/^020[23][a-f0-9]{64}$/.test(k)),'Unsupported PSBT input field.');
 return {global,input,outputMaps,raw,version,prevout,sequence,outputs,locktime};
}
