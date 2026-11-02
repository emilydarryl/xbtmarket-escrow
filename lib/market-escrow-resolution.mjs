// A mediator decision approves one exact payout selection, never a spending signature.
import {randomBytes} from 'node:crypto';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {reviewProductionSpend} from './market-escrow-spend.mjs';
import {verifyProductionMessageSignature} from './market-escrow-contract.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const exact=(v,fields)=>need(v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join()===fields.split(',').sort().join(),'Unexpected resolution fields.');
const sorted=v=>Array.isArray(v)?v.map(sorted):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,sorted(v[k])])):v;
export const productionResolutionMessage=q=>Buffer.from('XBT Market: approve this exact mediated payout selection; NOT a spending signature. v1\n'+JSON.stringify(sorted(q)));
export function createProductionResolution(payoutRequest,workflow,now=Date.now()){
 const c=payoutRequest.authorization.bundle.contract;
 const challenge={schema:'xbt-production-resolution-challenge-v1',purpose:'approve-mediated-payout-selection',origin:c.origin,orderId:c.preflight.orderId,revision:workflow.revision,workflowHash:hash(workflow),requestHash:payoutRequest.requestHash,publicKey:c.keys.market,nonce:randomBytes(32).toString('hex'),issuedAt:now,expiresAt:now+900000};
 const body={schema:'xbt-production-resolution-request-v1',payoutRequest,workflow,challenge},request={...body,decisionHash:hash(body)};
 reviewProductionResolution(request,{expectedDecisionHash:request.decisionHash,expectedContractHash:c.contractHash,expectedFundingTermsHash:payoutRequest.authorization.terms.fundingTermsHash,origin:c.origin,ownPublicKey:c.keys.market,now});return structuredClone(request);
}
export function reviewProductionResolution(r,o){
 need(r&&JSON.stringify(r).length<=100000,'Bounded resolution request required.');exact(r,'schema,payoutRequest,workflow,challenge,decisionHash');
 const {decisionHash,...body}=r;need(r.schema==='xbt-production-resolution-request-v1'&&typeof o.expectedDecisionHash==='string'&&/^[a-f0-9]{64}$/.test(o.expectedDecisionHash)&&decisionHash===o.expectedDecisionHash&&hash(body)===decisionHash,'Independent resolution hash required.');
 const p=r.payoutRequest,c=p.authorization.bundle.contract;
 reviewProductionSpend(p,{expectedRequestHash:p.requestHash,expectedContractHash:o.expectedContractHash,expectedFundingTermsHash:o.expectedFundingTermsHash,origin:o.origin,role:'market',ownPublicKey:o.ownPublicKey,expectedMediatorPublicKey:o.ownPublicKey});
 need(p.decision.disputed===true&&p.decision.by==='market','Mediated outcome required.');
 const w=r.workflow;exact(w,'orderId,revision,authorizationHash,status,dispute');exact(w.dispute,'by,reason,openedAt');
 need(w.orderId===c.preflight.orderId&&w.authorizationHash===p.authorization.authorizationHash&&w.status==='disputed'&&Number.isSafeInteger(w.revision)&&w.revision>0&&['buyer','seller'].includes(w.dispute.by)&&typeof w.dispute.reason==='string'&&w.dispute.reason.length>=10&&w.dispute.reason.length<=1000&&!/[\x00-\x1f\x7f]/.test(w.dispute.reason)&&Number.isSafeInteger(w.dispute.openedAt)&&w.dispute.openedAt>=0,'Disputed workflow required.');
 const q=r.challenge;exact(q,'schema,purpose,origin,orderId,revision,workflowHash,requestHash,publicKey,nonce,issuedAt,expiresAt');
 need(q.schema==='xbt-production-resolution-challenge-v1'&&q.purpose==='approve-mediated-payout-selection'&&q.origin===c.origin&&q.orderId===w.orderId&&q.revision===w.revision&&q.workflowHash===hash(w)&&q.requestHash===p.requestHash&&q.publicKey===c.keys.market&&typeof q.nonce==='string'&&/^[a-f0-9]{64}$/.test(q.nonce),'Resolution challenge mismatch.');
 need(Number.isSafeInteger(q.issuedAt)&&q.issuedAt>=w.dispute.openedAt&&Number.isSafeInteger(q.expiresAt)&&q.expiresAt-q.issuedAt===900000&&Number.isSafeInteger(o.now)&&o.now>=q.issuedAt&&o.now<q.expiresAt,'Resolution expired or invalid time.');
 return {decisionHash,requestHash:p.requestHash,spendingAuthorized:false};
}
export function verifyProductionResolution(r,proof,o){
 reviewProductionResolution(r,o);exact(proof,'schema,decisionHash,challenge,signature');need(proof.schema==='xbt-production-resolution-proof-v1'&&proof.decisionHash===r.decisionHash&&hash(proof.challenge)===hash(r.challenge),'Resolution proof binding mismatch.');
 verifyProductionMessageSignature(r.challenge.publicKey,productionResolutionMessage(r.challenge),proof.signature);return {decisionHash:r.decisionHash,requestHash:r.payoutRequest.requestHash,spendingAuthorized:false};
}
