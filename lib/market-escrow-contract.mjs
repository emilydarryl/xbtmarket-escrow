// Production contract review protocol. No funding authorization or spend signing.
import {createHash,ECDH,createPublicKey,randomBytes,verify} from 'node:crypto';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {productionOrderKeys} from './market-escrow-order-keys.mjs';
import {XBT_CHAIN_PROFILE} from './market-escrow-chain.mjs';
import {escrowOrderPreflightDetails} from './market-escrow-preflight.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const exact=(v,keys)=>need(v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join()===keys.split(',').sort().join(),'Unexpected production protocol fields.');
const hex=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const roles=['buyer','seller','market'];
const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
const domain='XBT Market: production contract review only, NOT a payment or funding authorization. v1\n';
export const productionContractMessage=c=>Buffer.from(domain+JSON.stringify(canonical(c)),'utf8');
export function productionOrigin(origin){
 let url;try{url=new URL(origin);}catch{throw Error('Exact HTTPS marketplace origin required.');}
 need(url.origin===origin&&url.protocol==='https:'&&!url.username&&!url.password&&url.pathname==='/'&&!url.search&&!url.hash,'Exact HTTPS marketplace origin required.');return origin;
}
export function productionPublicKey(value){
 need(typeof value==='string'&&/^0[23][a-f0-9]{64}$/.test(value),'Compressed secp256k1 public key required.');
 ECDH.convertKey(Buffer.from(value,'hex'),'secp256k1',undefined,undefined,'compressed');return value;
}
const key=productionPublicKey;
function sats(value){need(typeof value==='string'&&/^(0|[1-9][0-9]{0,15})$/.test(value),'Canonical satoshi string required.');const n=BigInt(value);need(n<=2100000000000000n,'Amount exceeds supply bound.');return n;}
function scripts(keys,context){
 exact(keys,'buyer,seller,market');Object.values(keys).forEach(key);need(new Set(Object.values(keys)).size===3,'Distinct participant keys required.');
 const orderKeys=productionOrderKeys({...context,keys});
 const witnessScript='52'+Object.values(orderKeys).sort().map(k=>'21'+k).join('')+'53ae';
 const scriptPubKey='0020'+createHash('sha256').update(Buffer.from(witnessScript,'hex')).digest('hex');
 const payoutScripts=Object.fromEntries(['buyer','seller'].map(role=>[role,'0014'+createHash('ripemd160').update(createHash('sha256').update(Buffer.from(keys[role],'hex')).digest()).digest('hex')]));
 return {orderKeys,witnessScript,scriptPubKey,payoutScripts};
}
const policy=Object.freeze({version:'buyer-reserve-review-v1',payer:'buyer',unusedReserve:'buyer',minimumOutputSats:'546',platformFeeIncluded:false,replacement:'not-authorized'});
const fields='schema,chainProfile,origin,revision,preflight,snapshot,keys,sellerPriceSats,buyerFeeReserveSats,totalDepositSats,feePolicy,orderKeys,witnessScript,scriptPubKey,payoutScripts,fundingEnabled,contractHash';
export function validateProductionContract(c){
 exact(c,fields);need(c.schema==='xbt-production-contract-review-v3'&&c.fundingEnabled===false,'Production contract review schema required.');
 productionOrigin(c.origin);need(Number.isSafeInteger(c.revision)&&c.revision>0,'Positive contract revision required.');
 need(hash(c.chainProfile)===hash(XBT_CHAIN_PROFILE),'Pinned XBT chain profile required.');
 const p=c.preflight;exact(p,'schema,orderId,snapshotHash,accountBindingHash,paymentMode,sellerPriceSats,fundingEnabled,signingEnabled,preflightHash');
 const {preflightHash,...data}=p;
 need(p.schema==='xbt-escrow-order-preflight-v1'&&p.fundingEnabled===false&&p.signingEnabled===false&&['direct','escrow_setup'].includes(p.paymentMode)&&hex(p.snapshotHash)&&hex(p.accountBindingHash)&&hex(preflightHash)&&hash(data)===preflightHash,'Invalid account/order preflight.');
 exact(c.snapshot,'orderId,listingId,sellerProfileId,title,description,terms,totalXbt,delivery,destinationCountry,shipping,platformFeePolicy');
 need(typeof p.orderId==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(p.orderId)&&c.snapshot.orderId===p.orderId&&c.snapshot.delivery==='shipping'&&hash(c.snapshot)===p.snapshotHash,'Order terms do not match the preflight.');
 for(const name of ['title','description','terms'])need(typeof c.snapshot[name]==='string'&&c.snapshot[name].length>0&&c.snapshot[name].length<=10000,'Displayable order terms required.');
 need(typeof c.snapshot.totalXbt==='string'&&/^(0|[1-9][0-9]{0,9})(\.[0-9]{1,8})?$/.test(c.snapshot.totalXbt),'Canonical order price required.');
 const [whole,part='']=c.snapshot.totalXbt.split('.');
 const price=sats(c.sellerPriceSats),reserve=sats(c.buyerFeeReserveSats),deposit=sats(c.totalDepositSats);
 need(price>=546n&&price.toString()===p.sellerPriceSats&&price===BigInt(whole)*100000000n+BigInt(part.padEnd(8,'0'))&&reserve>=1000n&&reserve<=100000n&&deposit===price+reserve,'Contract amounts disagree or reserve exceeds review bounds.');
 need(hash(c.feePolicy)===hash(policy),'Unsupported contract fee policy.');
 const derived=scripts(c.keys,c);for(const name of Object.keys(derived))need(hash(c[name])===hash(derived[name]),'Contract scripts do not match participant keys.');
 const {contractHash,...body}=c;need(hex(contractHash)&&hash(body)===contractHash,'Contract hash mismatch.');
 return c;
}
export function createProductionContract(store,context,{expectedPreflightHash,origin,keys,buyerFeeReserveSats,revision=1}){
 const {preflight,snapshot}=escrowOrderPreflightDetails(store,context);
 need(preflight.preflightHash===expectedPreflightHash,'Order or account binding changed.');
 const c={schema:'xbt-production-contract-review-v3',chainProfile:{...XBT_CHAIN_PROFILE},origin:productionOrigin(origin),revision,preflight,snapshot,keys:structuredClone(keys),sellerPriceSats:preflight.sellerPriceSats,buyerFeeReserveSats,totalDepositSats:(sats(preflight.sellerPriceSats)+sats(buyerFeeReserveSats)).toString(),feePolicy:{...policy},...scripts(keys,{origin,revision,preflight,chainProfile:XBT_CHAIN_PROFILE}),fundingEnabled:false};
 c.contractHash=hash(c);return validateProductionContract(c);
}
export function reviseProductionContract(c,revision){
 validateProductionContract(c);need(Number.isSafeInteger(revision)&&revision>c.revision,'New contract revision required.');
 const body={...structuredClone(c),revision,...scripts(c.keys,{...c,revision})};delete body.contractHash;body.contractHash=hash(body);return validateProductionContract(body);
}
export function reviewProductionContract(c,{expectedContractHash,origin,role,ownPublicKey,expectedMediatorPublicKey}){
 validateProductionContract(c);productionOrigin(origin);
 need(hex(expectedContractHash)&&c.contractHash===expectedContractHash&&c.origin===origin&&roles.includes(role)&&c.keys[role]===key(ownPublicKey)&&c.keys.market===key(expectedMediatorPublicKey),'Independent contract, origin, role and mediator pins required.');
 return {contractHash:c.contractHash,orderId:c.preflight.orderId,role,fundingEnabled:false};
}
export function createProductionContractChallenge(c,{role,now=Date.now()}){
 validateProductionContract(c);need(roles.includes(role)&&Number.isSafeInteger(now)&&now>=0&&now<=Number.MAX_SAFE_INTEGER-900000,'Invalid role or challenge time.');
 return {schema:'xbt-production-contract-challenge-v1',purpose:'review-production-contract-not-payment',origin:c.origin,contractHash:c.contractHash,orderId:c.preflight.orderId,revision:c.revision,role,publicKey:c.keys[role],nonce:randomBytes(32).toString('hex'),issuedAt:now,expiresAt:now+900000};
}
export function verifyProductionContractProof(c,proof,options){
 reviewProductionContract(c,options);exact(proof,'schema,challenge,signature');
 need(proof.schema==='xbt-production-contract-proof-v1','Production proof schema required.');
 const q=proof.challenge;exact(q,'schema,purpose,origin,contractHash,orderId,revision,role,publicKey,nonce,issuedAt,expiresAt');
 need(q.schema==='xbt-production-contract-challenge-v1'&&q.purpose==='review-production-contract-not-payment'&&q.origin===c.origin&&q.contractHash===c.contractHash&&q.orderId===c.preflight.orderId&&q.revision===c.revision&&q.role===options.role&&q.publicKey===options.ownPublicKey&&hex(q.nonce),'Production approval binding mismatch.');
 need(Number.isSafeInteger(q.issuedAt)&&q.issuedAt>=0&&Number.isSafeInteger(q.expiresAt)&&q.expiresAt-q.issuedAt===900000&&Number.isSafeInteger(options.now)&&options.now>=q.issuedAt&&options.now<q.expiresAt,'Approval expired or timing invalid.');
 verifyProductionMessageSignature(q.publicKey,productionContractMessage(q),proof.signature);
 return {role:q.role,contractHash:c.contractHash,keyControlVerified:true,fundingEnabled:false};
}
export function verifyProductionMessageSignature(publicKey,message,signature){
 key(publicKey);need(Buffer.isBuffer(message)&&message.length<=50000,'Bounded message required.');
 need(typeof signature==='string'&&signature.length<=100,'Bounded DER proof required.');const der=Buffer.from(signature,'base64');
 need(der.toString('base64')===signature&&der.length>=8&&der.length<=72&&der[0]===48&&der[1]===der.length-2,'Canonical signature encoding required.');
 let offset=2;const values=[];for(let i=0;i<2;i++){need(der[offset++]===2,'Invalid signature integer.');const size=der[offset++];need(size>=1&&size<=33&&offset+size<=der.length,'Invalid signature size.');const bytes=der.subarray(offset,offset+size);offset+=size;need(!(bytes[0]&128)&&!(size>1&&bytes[0]===0&&!(bytes[1]&128)),'Noncanonical signature integer.');values.push(BigInt('0x'+bytes.toString('hex')));}
 const n=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;need(offset===der.length&&values[0]>0n&&values[0]<n&&values[1]>0n&&values[1]<=n/2n,'Low-S signature required.');
 const point=ECDH.convertKey(Buffer.from(publicKey,'hex'),'secp256k1',undefined,undefined,'uncompressed'),pub=createPublicKey({format:'jwk',key:{kty:'EC',crv:'secp256k1',x:point.subarray(1,33).toString('base64url'),y:point.subarray(33).toString('base64url')}});
 need(verify('sha256',message,pub,der),'Production message signature mismatch.');
 return true;
}
