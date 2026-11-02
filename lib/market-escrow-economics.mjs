// Unfunded REGTEST drafts only. No address, PSBT, private keys, RPC or signing.
import {createHash,ECDH} from 'node:crypto';
const need=(ok,message)=>{if(!ok)throw Error(message);};
const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
export const escrowDraftHash=x=>createHash('sha256').update(JSON.stringify(canonical(x))).digest('hex');
const exact=(x,fields)=>need(x&&typeof x==='object'&&!Array.isArray(x)&&Object.keys(x).sort().join()===fields.slice().sort().join(),'Unexpected draft fields.');
const sats=x=>{need(typeof x==='string'&&/^(0|[1-9][0-9]{0,9})$/.test(x),'Use canonical integer satoshi strings.');return BigInt(x);};
const hex=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(x);
function itemSats(x){
 need(typeof x==='string'&&/^(0|[1-9][0-9]{0,7})(?:\.[0-9]{1,8})?$/.test(x),'Exact XBT order price required.');
 const [whole,part='']=x.split('.');return BigInt(whole)*100000000n+BigInt(part.padEnd(8,'0'));
}
const fields=['schema','chain','testOnly','fundingEnabled','keyOwnershipVerified','orderId','setupRevision','setupAgreementHash','snapshot','snapshotHash','keys','sellerPriceSats','buyerFeeReserveSats','totalDepositSats','feePolicy','draftHash'];
const feePolicy={payer:'buyer',unusedReserve:'buyer',minimumFeeSats:'1000',maximumReserveSats:'100000',minimumOutputSats:'546',platformFeeIncluded:false};
function validate(draft){
 exact(draft,fields);
 need(draft.schema==='xbt-order-funding-draft-v1'&&draft.chain==='regtest'&&draft.testOnly===true&&draft.fundingEnabled===false&&draft.keyOwnershipVerified===false,'Only unfunded artificial-regtest drafts are supported.');
 need(uuid(draft.orderId)&&Number.isSafeInteger(draft.setupRevision)&&draft.setupRevision>0&&hex(draft.setupAgreementHash)&&hex(draft.snapshotHash),'Invalid setup binding.');
 need(draft.snapshot?.orderId===draft.orderId&&draft.snapshot.delivery==='shipping'&&escrowDraftHash(draft.snapshot)===draft.snapshotHash,'Source snapshot changed.');
 exact(draft.keys,['buyer','seller','market']);
 for(const key of Object.values(draft.keys)){
  need(typeof key==='string'&&/^0[23][a-f0-9]{64}$/.test(key),'Invalid participant key.');
  ECDH.convertKey(Buffer.from(key,'hex'),'secp256k1',undefined,undefined,'compressed');
 }
 need(new Set(Object.values(draft.keys)).size===3,'Distinct signing keys required.');
 need(escrowDraftHash({snapshotHash:draft.snapshotHash,policy:'2-of-3',keys:draft.keys,network:'not-enabled',fundingEnabled:false})===draft.setupAgreementHash,'Setup agreement changed.');
 need(JSON.stringify(canonical(draft.feePolicy))===JSON.stringify(canonical(feePolicy)),'Unsupported reserve policy.');
 const price=sats(draft.sellerPriceSats),reserve=sats(draft.buyerFeeReserveSats),deposit=sats(draft.totalDepositSats);
 // Deliberately bounded lab policy, not a fee estimate or a production limit.
 need(price>=546n&&price<=1000000000n&&price===itemSats(draft.snapshot.totalXbt),'Seller price differs from order or exceeds lab limits.');
 need(reserve>=1000n&&reserve<=100000n&&deposit===price+reserve,'Deposit must equal seller price plus the bounded buyer reserve.');
 const data={...draft};delete data.draftHash;
 need(hex(draft.draftHash)&&escrowDraftHash(data)===draft.draftHash,'Draft hash changed.');
 return {price,reserve,deposit};
}
export function createFundingDraft(setup,buyerFeeReserveSats){
 need(setup?.enabled===true&&setup.hold===true&&setup.status==='approved'&&setup.fundingEnabled===false&&setup.keyOwnershipVerified===false&&setup.approvals?.length===2&&['buyer','seller'].every(r=>setup.approvals.includes(r)),'Both participants must approve the current held setup.');
 const price=itemSats(setup.snapshot.totalXbt),reserve=sats(buyerFeeReserveSats);
 const draft={schema:'xbt-order-funding-draft-v1',chain:'regtest',testOnly:true,fundingEnabled:false,keyOwnershipVerified:false,
  orderId:setup.id,setupRevision:setup.revision,setupAgreementHash:setup.agreementHash,snapshot:structuredClone(setup.snapshot),snapshotHash:setup.snapshotHash,
  keys:structuredClone(setup.keys),sellerPriceSats:price.toString(),buyerFeeReserveSats,totalDepositSats:(price+reserve).toString(),feePolicy:{...feePolicy}};
 draft.draftHash=escrowDraftHash(draft);validate(draft);return draft;
}
export function reviewFundingDraft(draft,{expectedDraftHash,ownPublicKey,role}={}){
 validate(draft);
 need(hex(expectedDraftHash)&&draft.draftHash===expectedDraftHash,'Independently pinned draft hash required.');
 need(['buyer','seller','market'].includes(role)&&draft.keys[role]===ownPublicKey,'Draft belongs to another signer or role.');
 return {orderId:draft.orderId,draftHash:draft.draftHash,sellerPriceSats:draft.sellerPriceSats,buyerFeeReserveSats:draft.buyerFeeReserveSats,totalDepositSats:draft.totalDepositSats,fundingEnabled:false};
}
export function planDraftPayout(draft,{expectedDraftHash,scenario,networkFeeSats,sellerAwardSats}={}){
 const {price,reserve,deposit}=validate(draft);
 need(hex(expectedDraftHash)&&draft.draftHash===expectedDraftHash,'Independently pinned draft hash required.');
 const fee=sats(networkFeeSats);need(fee>=1000n&&fee<=reserve,'Fee exceeds buyer reserve or is below lab minimum.');
 need(['release','refund','split-refund'].includes(scenario),'Unsupported resolution.');
 let award=scenario==='release'?price:scenario==='refund'?0n:sats(sellerAwardSats);
 need(scenario==='split-refund'?award>0n&&award<price:sellerAwardSats===undefined,'Invalid seller award.');
 const buyer=price-award+reserve-fee;
 const payouts=[{role:'buyer',publicKey:draft.keys.buyer,sats:buyer.toString()},{role:'seller',publicKey:draft.keys.seller,sats:award.toString()}].filter(o=>o.sats!=='0');
 need(payouts.every(o=>BigInt(o.sats)>=546n),'Payout would create dust. Revise the fee or reserve; never silently donate buyer change.');
 need(payouts.reduce((sum,o)=>sum+BigInt(o.sats),fee)===deposit,'Value conservation failed.');
 const plan={schema:'xbt-order-payout-plan-v1',chain:'regtest',testOnly:true,fundingEnabled:false,draftHash:draft.draftHash,scenario,networkFeeSats,payouts};
 return {...plan,planHash:escrowDraftHash(plan)};
}
