// Review service and reversible preparation reservation. No address or broadcast.
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {escrowOrderPreflight,assertEscrowPreflightCurrent} from './market-escrow-preflight.mjs';
import {XBT_CHAIN_PROFILE} from './market-escrow-chain.mjs';
import {accessOrder} from './market-trades.mjs';
import {isAccountActor,assertActorActive} from './market-identity.mjs';
import {createProductionContract,reviseProductionContract,createProductionContractChallenge,verifyProductionContractProof,productionOrigin,productionPublicKey} from './market-escrow-contract.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
const roles=['buyer','seller','market'];
export function createProductionContractStore(store,{enabled=false,origin,mediatorPublicKey}={}){
 if(enabled){productionOrigin(origin);productionPublicKey(mediatorPublicKey);}
 store.db.exec('CREATE TABLE IF NOT EXISTS market_escrow_contract_reviews(order_id TEXT PRIMARY KEY,body TEXT NOT NULL)');
 store.db.exec('CREATE TABLE IF NOT EXISTS market_escrow_signer_selections(order_id TEXT NOT NULL,role TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(order_id,role))');
 const read=id=>{const row=store.db.prepare('SELECT body FROM market_escrow_contract_reviews WHERE order_id=?').get(id);return row?JSON.parse(row.body):null;};
 const save=(id,s)=>store.db.prepare('INSERT INTO market_escrow_contract_reviews VALUES(?,?) ON CONFLICT(order_id) DO UPDATE SET body=excluded.body').run(id,JSON.stringify(s));
 function transaction(fn){store.db.exec('BEGIN IMMEDIATE');try{const value=fn();store.db.exec('COMMIT');return value;}catch(e){store.db.exec('ROLLBACK');throw e;}}
 function actorRole(context){need(enabled,'Production contract review is disabled.');escrowOrderPreflight(store,context);return accessOrder(store,context.id,context.actor,context.sellerId).role;}
 function current(context){actorRole(context);const s=read(context.id);need(s,'No contract proposed.');assertEscrowPreflightCurrent(store,context,s.contract.preflight.preflightHash);for(const [role,key] of Object.entries(selections(context)))need(s.contract.keys[role]===key,'Prepare a new contract with the selected signers.');need(s.contract.origin===origin&&s.contract.keys.market===mediatorPublicKey,'Configured origin or mediator changed.');return s;}
 const preparation=id=>store.db.prepare('SELECT contract_hash,receipt_hash,created FROM market_escrow_preparations WHERE order_id=?').get(id);
 const present=s=>({contract:structuredClone(s.contract),approvedRoles:roles.filter(r=>s.proofs[r]),allKeysVerified:roles.every(r=>s.proofs[r]),preparationReserved:!!preparation(s.contract.preflight.orderId),fundingEnabled:false,productionEnabled:false});
 // Selections are account-authenticated public keys, not proof of key ownership.
 function selections(context){
  const preflight=escrowOrderPreflight(store,context),result={};
  for(const row of store.db.prepare('SELECT role,body FROM market_escrow_signer_selections WHERE order_id=?').all(context.id)){
   const value=JSON.parse(row.body);
   if(value.preflightHash===preflight.preflightHash&&value.enrollment.origin===origin)result[row.role]=value.enrollment.publicKey;
  }
  return result;
 }
 function signerConnection(context){
  const role=actorRole(context),preflight=escrowOrderPreflight(store,context);
  return {selectedKeys:selections(context),ownershipVerified:false,request:{schema:'xbt-signer-connect-request-v1',origin,role,orderId:context.id,expectedPreflightHash:preflight.preflightHash,sellerId:role==='seller'?context.sellerId:null}};
 }
 function selectSigner(context,{expectedPreflightHash,enrollment}){return transaction(()=>{
  const role=actorRole(context);assertEscrowPreflightCurrent(store,context,expectedPreflightHash);
  need(enrollment&&Object.keys(enrollment).sort().join()==='chainProfile,origin,publicKey,recoveryVerifiedLocally,role,schema','Public enrollment fields required.');
  need(enrollment.schema==='xbt-production-enrollment-v1'&&enrollment.role===role&&enrollment.origin===origin&&enrollment.recoveryVerifiedLocally===true&&hash(enrollment.chainProfile)===hash(XBT_CHAIN_PROFILE),'Enrollment role, origin, chain or recovery claim invalid.');
  productionPublicKey(enrollment.publicKey);
  const selected=selections(context),old=read(context.id);
  need(enrollment.publicKey!==mediatorPublicKey&&enrollment.publicKey!==selected[role==='buyer'?'seller':'buyer'],'Distinct participant keys required.');
  if(selected[role]===enrollment.publicKey)return signerConnection(context);
  need(!preparation(context.id)&&(!old||Object.keys(old.proofs).length===0),'Withdraw the existing review before changing the signer.');
  store.db.prepare('INSERT INTO market_escrow_signer_selections VALUES(?,?,?) ON CONFLICT(order_id,role) DO UPDATE SET body=excluded.body').run(context.id,role,JSON.stringify({preflightHash:expectedPreflightHash,enrollment}));
  // Invalidate any unsigned proposal so its old challenges cannot approve stale keys.
  if(old){old.contract=reviseProductionContract(old.contract,old.contract.revision+1);old.challenges={};save(context.id,old);}
  return signerConnection(context);
 });}
 function proposeConnected(context,options){
  actorRole(context);const selected=selections(context);
  need(selected.buyer&&selected.seller,'Both participants must connect their signer.');
  return propose(context,{...options,keys:{...selected,market:mediatorPublicKey}});
 }
 function propose(context,{expectedPreflightHash,keys,buyerFeeReserveSats}){return transaction(()=>{
  actorRole(context);need(keys?.market===mediatorPublicKey,'Configured mediator key required.');
  for(const [role,key] of Object.entries(selections(context)))need(keys[role]===key,'Use the signer selected by each participant.');
  const old=read(context.id),revision=old?.contract.revision??1;
  let contract=createProductionContract(store,context,{expectedPreflightHash,keys,buyerFeeReserveSats,origin,revision});
  if(old?.contract.contractHash===contract.contractHash)return present(current(context));
  need(!old||Object.keys(old.proofs).length===0,'Withdraw the existing review before changing the contract.');
  if(old)contract=createProductionContract(store,context,{expectedPreflightHash,keys,buyerFeeReserveSats,origin,revision:revision+1});
  const s={contract,challenges:{},proofs:{},acceptedAt:{}};save(context.id,s);return present(s);
 });}
 function challenge(context,{expectedContractHash,role,now=Date.now()}){return transaction(()=>{
  const own=actorRole(context),s=current(context);need(role===own||role==='market','Cannot request another participant approval.');
  need(s.contract.contractHash===expectedContractHash&&!s.proofs[role],'Contract changed or role already approved.');
  const old=s.challenges[role];if(old&&now>=old.issuedAt&&now<old.expiresAt)return structuredClone(old);
  const q=createProductionContractChallenge(s.contract,{role,now});s.challenges[role]=q;save(context.id,s);return structuredClone(q);
 });}
 function submit(context,proof,now=Date.now()){return transaction(()=>{
  const own=actorRole(context),s=current(context),role=proof?.challenge?.role;
  need(role===own||role==='market','Cannot submit another participant approval.');
  if(s.proofs[role]){need(hash(s.proofs[role])===hash(proof),'Conflicting approval.');return present(s);}
  need(s.challenges[role]&&hash(s.challenges[role])===hash(proof.challenge),'Unknown or withdrawn challenge.');
  verifyProductionContractProof(s.contract,proof,{expectedContractHash:s.contract.contractHash,origin,role,ownPublicKey:s.contract.keys[role],expectedMediatorPublicKey:mediatorPublicKey,now});
  s.proofs[role]=structuredClone(proof);s.acceptedAt[role]=now;save(context.id,s);return present(s);
 });}
 function withdraw(context,{expectedContractHash}){return transaction(()=>{
  // Unfunded exit must remain possible when the peer is restricted or source
  // bindings change. Require this caller's current account/order authorization.
  need(enabled&&isAccountActor(store,context.actor),'Authenticated account required.');assertActorActive(store,context.actor);
  accessOrder(store,context.id,context.actor,context.sellerId);
  const s=read(context.id);need(s&&s.contract.contractHash===expectedContractHash,'Review changed.');
  const held=preparation(context.id);need(!held||held.contract_hash===expectedContractHash,'Reservation changed.');
  // Deleting an activated authorization is rejected at the database boundary.
  store.db.prepare('DELETE FROM market_escrow_funding_authorizations WHERE order_id=?').run(context.id);
  store.db.prepare('DELETE FROM market_escrow_preparations WHERE order_id=?').run(context.id);
  // Either participant invalidates the whole unfunded review, including mediator.
  need(s.contract.revision<Number.MAX_SAFE_INTEGER,'Review revision exhausted.');
  s.contract=reviseProductionContract(s.contract,s.contract.revision+1);
  s.challenges={};s.proofs={};s.acceptedAt={};save(context.id,s);return present(s);
 });}
 function receipt(context){
  const s=current(context);for(const role of roles){need(s.proofs[role]&&hash(s.challenges[role])===hash(s.proofs[role].challenge),'Three current approvals required.');verifyProductionContractProof(s.contract,s.proofs[role],{expectedContractHash:s.contract.contractHash,origin,role,ownPublicKey:s.contract.keys[role],expectedMediatorPublicKey:mediatorPublicKey,now:s.acceptedAt[role]});}
  const r={schema:'xbt-production-contract-review-receipt-v1',contractHash:s.contract.contractHash,proofHashes:Object.fromEntries(roles.map(role=>[role,hash(s.proofs[role])])),acceptedAt:{...s.acceptedAt},fundingEnabled:false};return {...r,receiptHash:hash(r)};
 }
 function reviewBundle(context){const s=current(context);return structuredClone({contract:s.contract,proofs:s.proofs,acceptedAt:s.acceptedAt,receipt:receipt(context)});}
 function inspect(context){actorRole(context);const old=read(context.id),selected=selections(context),matches=old&&Object.entries(selected).every(([role,key])=>old.contract.keys[role]===key);return {signerConnection:signerConnection(context),...(matches?present(current(context)):{contract:null,approvedRoles:[],allKeysVerified:false,fundingEnabled:false,productionEnabled:false}),mediatorPublicKey};}
 function reserve(context,{expectedContractHash,now=Date.now()}){return transaction(()=>{
  const s=current(context);need(s.contract.contractHash===expectedContractHash,'Contract changed.');
  need(Number.isSafeInteger(now)&&now>=0,'Invalid reservation time.');
  const approved=receipt(context),old=preparation(context.id);
  if(old)need(old.contract_hash===expectedContractHash&&old.receipt_hash===approved.receiptHash,'Reservation changed.');
  else store.db.prepare('INSERT INTO market_escrow_preparations VALUES(?,?,?,?)').run(context.id,expectedContractHash,approved.receiptHash,now);
  return {...present(s),preparationReceiptHash:approved.receiptHash};
 });}
 const prune=()=>store.db.exec('DELETE FROM market_escrow_contract_reviews WHERE order_id NOT IN (SELECT id FROM market_orders); DELETE FROM market_escrow_signer_selections WHERE order_id NOT IN (SELECT id FROM market_orders)');
 return {selectSigner,proposeConnected,propose,challenge,submit,withdraw,reserve,receipt,reviewBundle,inspect,prune,view:context=>present(current(context))};
}
