// Exact production spending candidate. Construction/verifying only, never wallet access.
import {createHash} from 'node:crypto';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {validateProductionFundingAuthorization} from './market-escrow-funding.mjs';
import {reviewProductionContract,verifyProductionMessageSignature} from './market-escrow-contract.mjs';
import {parseProductionPsbt,psbtMap,sized,u32,u64} from './market-escrow-psbt.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const exact=(v,names)=>need(v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join()===names.split(',').sort().join(),'Unexpected spending fields.');
const hex=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v),bytes=h=>Buffer.from(h,'hex'),sha=b=>createHash('sha256').update(b).digest();
const sats=v=>{need(typeof v==='string'&&/^(0|[1-9][0-9]{0,15})$/.test(v),'Canonical amount required.');const n=BigInt(v);need(n<=2100000000000000n,'Amount exceeds supply.');return n;};
export const productionSignerEligible=(d,role)=>!!(d.disputed?{release:['seller','market'],refund:['buyer','market'],'split-refund':['buyer','seller','market']}[d.scenario]:d.scenario==='release'?['buyer','seller']:[])?.includes(role);
export function productionPayoutPlan(c,decision){
 exact(decision,'scenario,by,disputed,reason,networkFeeSats,sellerAwardSats');need(typeof decision.disputed==='boolean'&&decision.by===(decision.disputed?'market':'buyer')&&(decision.disputed||decision.scenario==='release'),'Authorized outcome role required.');
 need(typeof decision.reason==='string'&&decision.reason.length>=10&&decision.reason.length<=1000&&!/[\x00-\x1f\x7f]/.test(decision.reason),'Displayable decision reason required.');
 const price=sats(c.sellerPriceSats),reserve=sats(c.buyerFeeReserveSats),fee=sats(decision.networkFeeSats);need(fee>=1000n&&fee<=reserve,'Explicit network fee must fit the buyer reserve.');
 let award;if(decision.scenario==='release')award=price;else if(decision.scenario==='refund')award=0n;else if(decision.scenario==='split-refund')award=sats(decision.sellerAwardSats);else throw Error('Unsupported outcome.');
 need(award<=price&&(decision.scenario==='split-refund'||decision.sellerAwardSats===null),'Invalid seller award.');
 const amounts={buyer:price-award+reserve-fee,seller:award},outputs=[];for(const role of ['buyer','seller'])if(amounts[role]>0n){need(amounts[role]>=546n,'No dust or silent fee deduction allowed.');outputs.push({role,sats:amounts[role].toString(),scriptPubKey:c.payoutScripts[role]});}
 need(outputs.length>0&&outputs.reduce((n,o)=>n+BigInt(o.sats),fee)===sats(c.totalDepositSats),'Payout conservation failed.');return outputs;
}
export function createProductionSpend(authorization,deposit,decision){
 const c=validateProductionFundingAuthorization(authorization);exact(deposit,'txid,vout,fundingBlockHash,valueSats,scriptPubKey');need(hex(deposit.txid)&&hex(deposit.fundingBlockHash)&&Number.isSafeInteger(deposit.vout)&&deposit.vout>=0&&deposit.vout<=0xffffffff&&deposit.valueSats===c.totalDepositSats&&deposit.scriptPubKey===c.scriptPubKey,'Exact independently verified deposit required.');
 const outputs=productionPayoutPlan(c,decision),prevout=Buffer.concat([Buffer.from(bytes(deposit.txid)).reverse(),u32(deposit.vout)]),raw=Buffer.concat([u32(2),Buffer.from([1]),prevout,Buffer.from([0]),u32(0xfffffffe),Buffer.from([outputs.length]),...outputs.map(o=>Buffer.concat([u64(o.sats),sized(bytes(o.scriptPubKey))])),u32(0)]);
 const psbt=Buffer.concat([bytes('70736274ff'),psbtMap([['00',raw]]),psbtMap([['01',Buffer.concat([u64(deposit.valueSats),sized(bytes(c.scriptPubKey))])],['03',u32(0x21)],['05',bytes(c.witnessScript)]]),...outputs.map(()=>Buffer.from([0]))]).toString('base64');
 const transaction={unsignedHex:raw.toString('hex'),transactionHash:sha(raw).toString('hex'),txid:Buffer.from(sha(sha(raw))).reverse().toString('hex'),outputs,psbt};
 const r={schema:'xbt-production-spend-request-v1',authorization,deposit,decision,transaction};return structuredClone({...r,requestHash:hash(r)});
}
export function reviewProductionSpend(r,options){
 need(r&&JSON.stringify(r).length<=80000,'Bounded spending request required.');exact(r,'schema,authorization,deposit,decision,transaction,requestHash');need(r.schema==='xbt-production-spend-request-v1'&&hex(options.expectedRequestHash)&&r.requestHash===options.expectedRequestHash,'Independently pinned payout required.');
 const c=validateProductionFundingAuthorization(r.authorization);reviewProductionContract(c,options);need(r.authorization.terms.fundingTermsHash===options.expectedFundingTermsHash,'Funding terms pin changed.');
 need(hash(createProductionSpend(r.authorization,r.deposit,r.decision))===hash(r),'Exact payout transaction mismatch.');
 need(productionSignerEligible(r.decision,options.role),'Signer role is not eligible for this outcome.');
 const p=parseProductionPsbt(r.transaction.psbt),tag=sha(Buffer.from('UnifiedSighash')),preimage=Buffer.concat([tag,tag,Buffer.from([0,0x21]),p.version,p.locktime,Buffer.from([0]),sha(p.prevout),sha(u64(r.deposit.valueSats)),sha(sized(bytes(c.scriptPubKey))),sha(p.sequence),sha(Buffer.concat(p.outputs.map(o=>o.serialized))),Buffer.from([1,0,0,0,0]),sized(bytes(c.witnessScript))]);return {contract:c,psbt:p,preimage};
}
export function verifyProductionSpendSignature(r,result,role){
 const c=r.authorization.bundle.contract,key=c.keys[role],review=reviewProductionSpend(r,{expectedRequestHash:r.requestHash,expectedContractHash:c.contractHash,expectedFundingTermsHash:r.authorization.terms.fundingTermsHash,origin:c.origin,role,ownPublicKey:key,expectedMediatorPublicKey:c.keys.market});
 exact(result,'schema,orderId,contractHash,fundingTermsHash,requestHash,transactionHash,signerRole,signerPublicKey,orderPublicKey,psbt');need(result.schema==='xbt-production-spend-signed-v2'&&result.orderId===c.preflight.orderId&&result.contractHash===c.contractHash&&result.fundingTermsHash===r.authorization.terms.fundingTermsHash&&result.requestHash===r.requestHash&&result.transactionHash===r.transaction.transactionHash&&result.signerRole===role&&result.signerPublicKey===key&&result.orderPublicKey===c.orderKeys[role],'Wrong production signature binding.');
 const p=parseProductionPsbt(result.psbt,true);need(p.raw.equals(review.psbt.raw)&&p.input.size===4,'One exact public signature required.');for(const [k,v] of review.psbt.input)need(p.input.get(k)?.equals(v),'Changed witness metadata.');const sig=p.input.get('02'+c.orderKeys[role]);need(sig&&sig.at(-1)===0x21,'ALL|UNIFIED signature required.');verifyProductionMessageSignature(c.orderKeys[role],review.preimage,sig.subarray(0,-1).toString('base64'));return {role,signature:sig};
}
export function finalizeProductionSpend(r,results){
 need(Array.isArray(results)&&results.length===2&&new Set(results.map(s=>s.signerRole)).size===2,'Two distinct signatures required.');const c=r.authorization.bundle.contract,byRole=new Map(results.map(s=>[s.signerRole,verifyProductionSpendSignature(r,s,s.signerRole).signature]));
 const pairs=r.decision.disputed?{release:[['seller','market']],refund:[['buyer','market']],'split-refund':[['buyer','market'],['seller','market']]}[r.decision.scenario]:[['buyer','seller']];need(pairs.some(pair=>pair.every(role=>byRole.has(role))),'Signer pair not eligible for selected outcome.');
 const p=parseProductionPsbt(r.transaction.psbt),keys=Object.entries(c.orderKeys).sort((a,b)=>a[1].localeCompare(b[1])),signatures=keys.filter(([role])=>byRole.has(role)).map(([role])=>byRole.get(role));
 const raw=Buffer.concat([p.version,bytes('000101'),p.prevout,Buffer.from([0]),p.sequence,Buffer.from([p.outputs.length]),...p.outputs.map(o=>o.serialized),Buffer.from([4,0]),...signatures.map(sized),sized(bytes(c.witnessScript)),p.locktime]);
 return {rawTx:raw.toString('hex'),txid:r.transaction.txid,requestHash:r.requestHash,virtualBytes:Math.ceil((p.raw.length*3+raw.length)/4),replacementAuthorized:false};
}
