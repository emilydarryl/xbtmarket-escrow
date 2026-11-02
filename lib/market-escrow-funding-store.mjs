import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {storedProductionAuthorization,assertProductionAccountBinding} from './market-escrow-authorization.mjs';
import {accessOrder} from './market-trades.mjs';
import {isAccountActor,assertActorActive} from './market-identity.mjs';
import {createProductionFundingTerms,createProductionFundingChallenge,verifyProductionFundingProof} from './market-escrow-funding.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const roles=['buyer','seller','market'];
export function createProductionFundingStore(store,reviews,{enabled=false}={}){
 const read=id=>{const row=store.db.prepare('SELECT activated,body FROM market_escrow_funding_authorizations WHERE order_id=?').get(id);return row?{...JSON.parse(row.body),activated:row.activated===1}:null;};
 function transaction(fn){store.db.exec('BEGIN IMMEDIATE');try{const value=fn();store.db.exec('COMMIT');return value;}catch(e){store.db.exec('ROLLBACK');throw e;}}
 function role(context){need(enabled&&isAccountActor(store,context.actor),'Funding protocol unavailable.');assertActorActive(store,context.actor);return accessOrder(store,context.id,context.actor,context.sellerId).role;}
 function current(context){role(context);const bundle=reviews.reviewBundle(context),terms=createProductionFundingTerms(bundle),reservation=store.db.prepare('SELECT * FROM market_escrow_preparations WHERE order_id=?').get(context.id);need(reservation?.contract_hash===terms.contractHash&&reservation.receipt_hash===terms.reviewReceiptHash,'Reserve the approved contract before funding consent.');return {bundle,terms};}
 const present=s=>({terms:structuredClone(s.terms),approvedRoles:roles.filter(r=>s.proofs[r]),depositConsentComplete:s.activated===true,permanentReconciliationRequired:s.activated===true,fundingEnabled:false,spendingAuthorized:false});
 function save(id,s){const {activated,...body}=s;store.db.prepare('INSERT INTO market_escrow_funding_authorizations VALUES(?,?,?) ON CONFLICT(order_id) DO UPDATE SET activated=excluded.activated,body=excluded.body').run(id,activated?1:0,JSON.stringify(body));}
 function inspect(context){role(context);const s=read(context.id);if(s?.activated){const authorization=storedProductionAuthorization(store,context.id);assertProductionAccountBinding(store,context.id,authorization);return present(s);}const {terms}=current(context);if(!s)return {terms,approvedRoles:[],depositConsentComplete:false,fundingEnabled:false,spendingAuthorized:false};need(hash(terms)===hash(s.terms),'Funding terms changed.');return present(s);}
 function challenge(context,{expectedFundingTermsHash,role:requestedRole,now=Date.now()}){return transaction(()=>{
  const own=role(context),{bundle,terms}=current(context);need(requestedRole===own||requestedRole==='market','Cannot request another participant funding approval.');need(terms.fundingTermsHash===expectedFundingTermsHash,'Funding terms changed.');
  const s=read(context.id)??{bundle,terms,challenges:{},proofs:{},acceptedAt:{},activated:false};need(hash(s.terms)===hash(terms)&&!s.activated&&!s.proofs[requestedRole],'Funding role already approved or terms changed.');
  let q=s.challenges[requestedRole];if(!q||now<q.issuedAt||now>=q.expiresAt)q=createProductionFundingChallenge(bundle,terms,{role:requestedRole,now});
  s.challenges[requestedRole]=q;save(context.id,s);return structuredClone({schema:'xbt-production-funding-request-v1',bundle,terms,challenge:q});
 });}
 function submit(context,proof,now=Date.now()){return transaction(()=>{
  const own=role(context),{bundle,terms}=current(context),s=read(context.id),r=proof?.challenge?.role;need(s&&(r===own||r==='market'),'Funding approval role unavailable.');need(hash(s.terms)===hash(terms),'Funding terms changed.');
  if(s.proofs[r]){need(hash(s.proofs[r])===hash(proof),'Conflicting funding approval.');return present(s);}
  need(!s.activated&&s.challenges[r]&&hash(s.challenges[r])===hash(proof.challenge),'Unknown or invalidated funding challenge.');
  const c=bundle.contract;verifyProductionFundingProof(bundle,terms,proof,{expectedContractHash:c.contractHash,expectedFundingTermsHash:terms.fundingTermsHash,origin:c.origin,role:r,ownPublicKey:c.keys[r],expectedMediatorPublicKey:c.keys.market,now});
  s.proofs[r]=structuredClone(proof);s.acceptedAt[r]=now;s.activated=roles.every(r=>s.proofs[r]);save(context.id,s);return present(s);
 });}
 function authorization(context){const {bundle,terms}=current(context),s=read(context.id);need(s?.activated&&hash(s.terms)===hash(terms),'Complete funding consent required.');
  const c=bundle.contract;for(const r of roles)verifyProductionFundingProof(bundle,terms,s.proofs[r],{expectedContractHash:c.contractHash,expectedFundingTermsHash:terms.fundingTermsHash,origin:c.origin,role:r,ownPublicKey:c.keys[r],expectedMediatorPublicKey:c.keys.market,now:s.acceptedAt[r]});
  const a={schema:'xbt-production-funding-authorization-v1',bundle,terms,proofs:s.proofs,acceptedAt:s.acceptedAt,spendingAuthorized:false};return structuredClone({...a,authorizationHash:hash(a)});
 }
 return {inspect,challenge,submit,authorization};
}
