// Offline payout withdrawal construction. No keys, RPC, persistence or broadcast.
import {createHash} from 'node:crypto';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {productionPublicKey,productionOrigin,verifyProductionMessageSignature} from './market-escrow-contract.mjs';
import {XBT_CHAIN_PROFILE,createEscrowChainObserver} from './market-escrow-chain.mjs';
import {u32,u64,sized} from './market-escrow-psbt.mjs';
const need=(v,m)=>{if(!v)throw Error(m);},sha=b=>createHash('sha256').update(b).digest(),bytes=h=>Buffer.from(h,'hex');
const exact=(v,n)=>need(v&&Object.keys(v).sort().join()===n.split(',').sort().join(),'Unexpected withdrawal fields.');
const chars='qpzry9x8gf2tvdw0s3jn54khce6mua7l';
export function stripWithdrawalParent(encoded){
 need(typeof encoded==='string'&&/^(?:[a-f0-9]{2}){10,100000}$/.test(encoded),'Bounded raw parent required.');
 const raw=bytes(encoded);if(raw[4]!==0)return encoded;need(raw[5]===1,'Unknown witness flags.');
 let at=6;const take=n=>{need(at+n<=raw.length,'Truncated witness parent.');const b=raw.subarray(at,at+n);at+=n;return b;};
 const count=()=>{const n=take(1)[0];need(n<253,'Bounded canonical parent required.');return n;};
 const n=count();need(n>0&&n<=100,'Bounded input count required.');for(let i=0;i<n;i++){take(36);take(count());take(4);}
 const outputs=count();need(outputs>0&&outputs<=100,'Bounded output count required.');for(let i=0;i<outputs;i++){take(8);take(count());}const end=at;
 for(let i=0;i<n;i++){const items=count();need(items<=100,'Bounded witness required.');for(let j=0;j<items;j++)take(count());}
 const lock=take(4);need(at===raw.length,'Trailing witness bytes.');return Buffer.concat([raw.subarray(0,4),raw.subarray(6,end),lock]).toString('hex');
}
function polymod(values){let c=1;for(const v of values){const top=c>>>25;c=((c&0x1ffffff)<<5)^v;for(let i=0;i<5;i++)if((top>>>i)&1)c^=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3][i];}return c>>>0;}
export function withdrawalDestination(address){
 need(typeof address==='string'&&address===address.toLowerCase()&&address.startsWith('bc1')&&address.length<=90,'Lowercase mainnet native SegWit address required.');
 const data=[...address.slice(3)].map(c=>chars.indexOf(c));need(data.every(v=>v>=0)&&polymod([3,3,0,2,3,...data])===1&&data[0]===0,'Invalid witness-v0 address checksum.');
 let acc=0,bits=0;const program=[];for(const v of data.slice(1,-6)){acc=(acc<<5)|v;bits+=5;if(bits>=8){bits-=8;program.push((acc>>>bits)&255);}}
 need(bits<5&&((acc<<(8-bits))&255)===0&&[20,32].includes(program.length),'Invalid witness program.');return Buffer.from([0,program.length,...program]).toString('hex');
}
// Parent is stripped serialization: txid commits to it, including exact amount/script.
export function withdrawalParent(encoded,vout){
 need(typeof encoded==='string'&&/^(?:[a-f0-9]{2}){10,100000}$/.test(encoded),'Bounded parent transaction required.');
 const raw=bytes(encoded);let at=0;const take=n=>{need(at+n<=raw.length,'Truncated parent.');const b=raw.subarray(at,at+n);at+=n;return b;};
 const count=()=>{const n=take(1)[0];need(n<253,'Bounded canonical parent required.');return n;};take(4);const inputs=count();need(inputs>0&&inputs<=100,'Stripped parent required.');for(let i=0;i<inputs;i++){take(36);take(count());take(4);}
 const outputs=count();need(outputs>0&&outputs<=100&&Number.isSafeInteger(vout)&&vout>=0&&vout<outputs,'Invalid parent output.');let selected;for(let i=0;i<outputs;i++){const amount=take(8).readBigUInt64LE(),script=take(count()).toString('hex');if(i===vout)selected={valueSats:amount.toString(),scriptPubKey:script};}take(4);need(at===raw.length,'Trailing parent data.');return {...selected,txid:Buffer.from(sha(sha(raw))).reverse().toString('hex')};
}
export function createProductionWithdrawal({origin,role,publicKey,parentHex,vout,destination,feeSats}){
 productionOrigin(origin);productionPublicKey(publicKey);need(['buyer','seller'].includes(role),'Participant withdrawal only.');
 const parent=withdrawalParent(parentHex,vout),own='0014'+createHash('ripemd160').update(sha(bytes(publicKey))).digest('hex');need(parent.scriptPubKey===own,'Parent output must belong to this signer.');
 need(typeof feeSats==='string'&&/^[1-9][0-9]{0,4}$/.test(feeSats),'Explicit bounded fee required.');const fee=BigInt(feeSats),value=BigInt(parent.valueSats);need(fee<=10000n&&value<=2100000000000000n&&value-fee>=546n,'Fee cap or dust violation.');
 const script=withdrawalDestination(destination);need(script!==own,'Choose your external wallet destination.');
 const prevout=Buffer.concat([Buffer.from(bytes(parent.txid)).reverse(),u32(vout)]),output=Buffer.concat([u64(value-fee),sized(bytes(script))]);
 const raw=Buffer.concat([u32(2),Buffer.from([1]),prevout,Buffer.from([0]),u32(0xfffffffe),Buffer.from([1]),output,u32(0)]);
 const r={schema:'xbt-production-withdrawal-request-v1',chainProfile:XBT_CHAIN_PROFILE,origin,role,publicKey,parentHex,vout,parent,destination,feeSats,outputSats:(value-fee).toString(),unsignedHex:raw.toString('hex')};return {...r,requestHash:hash(r)};
}
export function reviewProductionWithdrawal(r,{expectedRequestHash,expectedDestination,maximumFeeSats,origin,role,publicKey}){
 exact(r,'schema,chainProfile,origin,role,publicKey,parentHex,vout,parent,destination,feeSats,outputSats,unsignedHex,requestHash');
 need(r.origin===origin&&r.role===role&&r.publicKey===publicKey&&r.destination===expectedDestination&&r.requestHash===expectedRequestHash,'Independent withdrawal pins differ.');
 need(typeof maximumFeeSats==='string'&&/^[1-9][0-9]{0,4}$/.test(maximumFeeSats)&&BigInt(maximumFeeSats)<=10000n&&BigInt(r.feeSats)<=BigInt(maximumFeeSats),'Independent fee limit required.');
 const rebuilt=createProductionWithdrawal(r);need(hash(rebuilt)===hash(r),'Withdrawal changed.');
 const raw=bytes(r.unsignedHex),tag=sha(Buffer.from('UnifiedSighash')),script=bytes(r.parent.scriptPubKey),scriptCode=bytes('76a914'+r.parent.scriptPubKey.slice(4)+'88ac');
 const output=Buffer.concat([u64(r.outputSats),sized(bytes(withdrawalDestination(r.destination)))]);
 const preimage=Buffer.concat([tag,tag,Buffer.from([0,0x21]),u32(2),u32(0),Buffer.from([0]),sha(raw.subarray(5,41)),sha(u64(r.parent.valueSats)),sha(sized(script)),sha(u32(0xfffffffe)),sha(output),Buffer.from([1]),u32(0),sized(scriptCode)]);
 return {preimage,raw};
}
export function finalizeProductionWithdrawal(r,result,pins){
 const {preimage,raw}=reviewProductionWithdrawal(r,pins);exact(result,'schema,requestHash,publicKey,signature');need(result.schema==='xbt-production-withdrawal-signed-v1'&&result.requestHash===r.requestHash&&result.publicKey===r.publicKey,'Withdrawal signature binding mismatch.');
 verifyProductionMessageSignature(r.publicKey,preimage,result.signature);const signature=Buffer.concat([Buffer.from(result.signature,'base64'),Buffer.from([0x21])]);
 const signed=Buffer.concat([raw.subarray(0,4),Buffer.from([0,1]),raw.subarray(4,-4),Buffer.from([2]),sized(signature),sized(bytes(r.publicKey)),raw.subarray(-4)]);
 return {rawHex:signed.toString('hex'),txid:Buffer.from(sha(sha(raw))).reverse().toString('hex'),requestHash:r.requestHash,broadcastAttempted:false};
}
export async function verifyWithdrawalUnspent(r,rpc,pins,{now=()=>Date.now()}={}){
 reviewProductionWithdrawal(r,pins);const chain=createEscrowChainObserver(rpc,{now}),tip=await chain.verifyChain();
 const parent=await rpc('getrawtransaction',[r.parent.txid,true]);
 need(parent?.txid===r.parent.txid&&stripWithdrawalParent(parent.hex)===r.parentHex&&typeof parent.blockhash==='string','Exact confirmed parent required.');
 const out=await rpc('gettxout',[r.parent.txid,r.vout,true]);
 need(out&&out.bestblock===tip.bestblockhash&&Number.isSafeInteger(out.confirmations)&&out.confirmations>=3&&out.confirmations<=tip.blocks+1&&typeof out.coinbase==='boolean','Confirmed unspent payout required.');
 need(!out.coinbase||out.confirmations>=451,'Conservative coinbase maturity required.');
 need(typeof out.value==='number'&&Number.isFinite(out.value)&&out.value>0&&out.value<=21000000&&Number(out.value.toFixed(8))===out.value&&BigInt(out.value.toFixed(8).replace('.','')).toString()===r.parent.valueSats&&out.scriptPubKey?.hex===r.parent.scriptPubKey,'Payout value/script changed.');
 need(await rpc('getblockhash',[tip.blocks-out.confirmations+1])===parent.blockhash,'Payout block is not on active chain.');
 const after=await chain.verifyChain();need(after.bestblockhash===tip.bestblockhash&&after.blocks===tip.blocks,'Chain changed; retry withdrawal checks.');
 return {verifiedUnspent:true,confirmations:out.confirmations,bestBlockHash:tip.bestblockhash,checkedAt:new Date().toISOString(),broadcastAttempted:false};
}
