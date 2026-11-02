// Distinct funding consent protocol. No wallet, transaction signing or broadcast.
import {randomBytes} from 'node:crypto';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {validateProductionContract,reviewProductionContract,verifyProductionContractProof,verifyProductionMessageSignature} from './market-escrow-contract.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const exact=(v,names)=>need(v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join()===names.split(',').sort().join(),'Unexpected funding protocol fields.');
const roles=['buyer','seller','market'];
const hex=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const sorted=v=>Array.isArray(v)?v.map(sorted):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,sorted(v[k])])):v;
export const productionFundingMessage=q=>Buffer.from('XBT Market: authorize this exact production escrow deposit; no spending permission. v1\n'+JSON.stringify(sorted(q)));
export function verifyProductionReviewBundle(bundle){
 exact(bundle,'contract,proofs,acceptedAt,receipt');const {contract:c,proofs,acceptedAt,receipt}=bundle;validateProductionContract(c);
 exact(proofs,'buyer,seller,market');exact(acceptedAt,'buyer,seller,market');
 for(const role of roles)verifyProductionContractProof(c,proofs[role],{expectedContractHash:c.contractHash,origin:c.origin,role,ownPublicKey:c.keys[role],expectedMediatorPublicKey:c.keys.market,now:acceptedAt[role]});
 const body={schema:'xbt-production-contract-review-receipt-v1',contractHash:c.contractHash,proofHashes:Object.fromEntries(roles.map(r=>[r,hash(proofs[r])])),acceptedAt:{...acceptedAt},fundingEnabled:false};
 need(hash(receipt)===hash({...body,receiptHash:hash(body)}),'Review receipt mismatch.');return c;
}
export function createProductionFundingTerms(bundle){
 const c=verifyProductionReviewBundle(bundle);
 const t={schema:'xbt-production-funding-terms-v1',chainProfile:c.chainProfile,origin:c.origin,orderId:c.preflight.orderId,contractHash:c.contractHash,reviewReceiptHash:bundle.receipt.receiptHash,scriptPubKey:c.scriptPubKey,valueSats:c.totalDepositSats,minimumConfirmations:3,depositPolicy:'one-exact-output-other-outputs-require-review',lateDepositPolicy:'permanent-monitoring-no-automatic-unlock',replacementPolicy:'not-authorized',spendingAuthorized:false};
 return structuredClone({...t,fundingTermsHash:hash(t)});
}
export function reviewProductionFunding(bundle,terms,options){
 const c=verifyProductionReviewBundle(bundle);reviewProductionContract(c,options);
 need(hex(options.expectedFundingTermsHash)&&terms?.fundingTermsHash===options.expectedFundingTermsHash&&hash(terms)===hash(createProductionFundingTerms(bundle)),'Independently pinned funding terms required.');return c;
}
export function createProductionFundingChallenge(bundle,terms,{role,now=Date.now()}){
 const c=verifyProductionReviewBundle(bundle);need(roles.includes(role)&&Number.isSafeInteger(now)&&now>=0&&now<=Number.MAX_SAFE_INTEGER-900000,'Invalid funding role/time.');
 need(now>=Math.max(...Object.values(bundle.acceptedAt)),'Funding challenge predates review acceptance.');
 need(hash(terms)===hash(createProductionFundingTerms(bundle)),'Funding terms changed.');
 return {schema:'xbt-production-funding-challenge-v1',purpose:'authorize-exact-escrow-deposit',origin:c.origin,orderId:c.preflight.orderId,contractHash:c.contractHash,fundingTermsHash:terms.fundingTermsHash,role,publicKey:c.keys[role],nonce:randomBytes(32).toString('hex'),issuedAt:now,expiresAt:now+900000};
}
export function verifyProductionFundingProof(bundle,terms,proof,options){
 const c=reviewProductionFunding(bundle,terms,options);exact(proof,'schema,challenge,signature');need(proof.schema==='xbt-production-funding-proof-v1','Separate funding approval required.');
 const q=proof.challenge;exact(q,'schema,purpose,origin,orderId,contractHash,fundingTermsHash,role,publicKey,nonce,issuedAt,expiresAt');
 need(q.schema==='xbt-production-funding-challenge-v1'&&q.purpose==='authorize-exact-escrow-deposit'&&q.origin===c.origin&&q.orderId===c.preflight.orderId&&q.contractHash===c.contractHash&&q.fundingTermsHash===terms.fundingTermsHash&&q.role===options.role&&q.publicKey===c.keys[options.role]&&hex(q.nonce),'Funding challenge binding mismatch.');
 need(Number.isSafeInteger(q.issuedAt)&&q.issuedAt>=0&&Number.isSafeInteger(q.expiresAt)&&q.expiresAt-q.issuedAt===900000&&Number.isSafeInteger(options.now)&&options.now>=q.issuedAt&&options.now<q.expiresAt,'Funding approval expired or timing invalid.');
 need(q.issuedAt>=Math.max(...Object.values(bundle.acceptedAt)),'Funding challenge predates review acceptance.');
 verifyProductionMessageSignature(q.publicKey,productionFundingMessage(q),proof.signature);
 return {role:q.role,fundingTermsHash:terms.fundingTermsHash,depositConsent:true,spendingAuthorized:false};
}
export function validateProductionFundingAuthorization(a){
 exact(a,'schema,bundle,terms,proofs,acceptedAt,spendingAuthorized,authorizationHash');need(a.schema==='xbt-production-funding-authorization-v1'&&a.spendingAuthorized===false,'Complete funding authorization required.');exact(a.proofs,'buyer,seller,market');exact(a.acceptedAt,'buyer,seller,market');
 const c=verifyProductionReviewBundle(a.bundle);for(const role of roles)verifyProductionFundingProof(a.bundle,a.terms,a.proofs[role],{expectedContractHash:c.contractHash,expectedFundingTermsHash:a.terms.fundingTermsHash,origin:c.origin,role,ownPublicKey:c.keys[role],expectedMediatorPublicKey:c.keys.market,now:a.acceptedAt[role]});
 const {authorizationHash,...body}=a;need(hex(authorizationHash)&&hash(body)===authorizationHash,'Funding authorization hash mismatch.');return c;
}
