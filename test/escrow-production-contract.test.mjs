import test from 'node:test';
import assert from 'node:assert/strict';
import {escrowBindingFixture,keys,tokens} from './helpers/escrow-binding-fixture.mjs';
import {escrowOrderPreflight} from '../lib/market-escrow-preflight.mjs';
import {escrowDraftHash as hash} from '../lib/market-escrow-economics.mjs';
import {createProductionContract,validateProductionContract,createProductionContractChallenge,verifyProductionContractProof} from '../lib/market-escrow-contract.mjs';
import {createProductionContractStore} from '../lib/market-escrow-contract-store.mjs';
import {changeOrder,pruneTrades} from '../lib/market-trades.mjs';
import {createEscrowSetup} from '../lib/market-escrow-setup.mjs';
import {randomUUID} from 'node:crypto';
const origin='https://market.example.test',now=1800000000000;
import {syntheticProductionProof as proof} from './helpers/production-signature.mjs';
function fixture(t){const f=escrowBindingFixture();t.after(()=>f.store.close());const context={id:f.id,actor:f.actors.buyer},seller={id:f.id,actor:f.actors.seller,sellerId:f.sellerId};const options={expectedPreflightHash:escrowOrderPreflight(f.store,context).preflightHash,keys,buyerFeeReserveSats:'10000',origin};return {...f,context,seller,options,contract:createProductionContract(f.store,context,options)};}
const verifyOptions=c=>({expectedContractHash:c.contractHash,origin,role:'buyer',ownPublicKey:keys.buyer,expectedMediatorPublicKey:keys.market,now:now+1});

function approvedFixture(t){
 const f=fixture(t),service=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});
 const c=service.propose(f.context,f.options).contract;
 for(const [role,scalar] of [['buyer',11],['seller',22],['market',33]]){const ctx=role==='seller'?f.seller:f.context,q=service.challenge(ctx,{role,expectedContractHash:c.contractHash,now});service.submit(ctx,proof(q,scalar),now+1);}
 return {...f,service,c};
}
test('three approved keys are required before reserving; reservation blocks direct and legacy setup writes',t=>{
 const f=fixture(t),service=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});
 const c=service.propose(f.context,f.options).contract;
 assert.throws(()=>service.reserve(f.context,{expectedContractHash:c.contractHash,now}),/Three/);
 assert.equal(f.store.db.prepare('SELECT count(*) n FROM market_escrow_preparations').get().n,0);
 for(const [role,scalar] of [['buyer',11],['seller',22],['market',33]]){const ctx=role==='seller'?f.seller:f.context,q=service.challenge(ctx,{role,expectedContractHash:c.contractHash,now});service.submit(ctx,proof(q,scalar),now+1);}
 assert.throws(()=>service.reserve({...f.context,actor:f.actors.other},{expectedContractHash:c.contractHash,now}));
 const held=service.reserve(f.context,{expectedContractHash:c.contractHash,now});assert.equal(held.preparationReserved,true);assert.equal(held.fundingEnabled,false);
 assert.deepEqual(service.reserve(f.seller,{expectedContractHash:c.contractHash,now:now+100}),held);
 assert.throws(()=>changeOrder(f.store,{id:f.id,sellerId:f.sellerId,action:'accept',confirm:true},f.actors.seller,now),/reserved escrow/);
 assert.throws(()=>changeOrder(f.store,{id:f.id,action:'cancel',confirm:true},f.actors.buyer,now),/reserved escrow/);
 const setup=createEscrowSetup(f.store,{enabled:true,origin:'http://127.0.0.1:4368',mediatorPublicKey:keys.market});
 assert.throws(()=>setup.mutate({id:f.id,commandId:randomUUID(),action:'create',revision:0,confirm:true},f.actors.buyer,now),/reserved escrow/);
 assert.equal(f.store.db.prepare('SELECT status FROM market_orders WHERE id=?').get(f.id).status,'requested');
 assert.equal(f.store.db.prepare('SELECT count(*) n FROM market_escrow_setups').get().n,0);
 assert.equal(service.receipt(f.context).receiptHash,held.preparationReceiptHash);
});
test('reservation survives service reopen and retention; withdrawal releases it and invalidates old approvals',t=>{
 const f=approvedFixture(t),pin={expectedContractHash:f.c.contractHash,now};f.service.reserve(f.context,pin);
 const reopened=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});assert.equal(reopened.view(f.context).preparationReserved,true);
 assert.throws(()=>f.store.db.prepare('DELETE FROM market_orders WHERE id=?').run(f.id),/cannot be deleted/);
 pruneTrades(f.store,now+400*86400000);assert.ok(f.store.db.prepare('SELECT id FROM market_orders WHERE id=?').get(f.id));
 assert.throws(()=>reopened.withdraw(f.context,{expectedContractHash:'0'.repeat(64)}),/changed/);assert.equal(reopened.view(f.context).preparationReserved,true);
 const withdrawn=reopened.withdraw(f.seller,pin);assert.equal(withdrawn.preparationReserved,false);assert.equal(withdrawn.allKeysVerified,false);
 assert.notEqual(withdrawn.contract.scriptPubKey,f.c.scriptPubKey);validateProductionContract(withdrawn.contract);
 assert.throws(()=>reopened.reserve(f.context,pin),/changed/);
 changeOrder(f.store,{id:f.id,action:'cancel',confirm:true},f.actors.buyer,now);
 assert.equal(f.store.db.prepare('SELECT status FROM market_orders WHERE id=?').get(f.id).status,'cancelled');
});
test('production scripts uniquely bind the order, origin and revision with the same participant identity keys',t=>{
 const a=fixture(t),b=fixture(t);assert.notEqual(a.contract.scriptPubKey,b.contract.scriptPubKey);
 const revision=createProductionContract(a.store,a.context,{...a.options,revision:2});assert.notEqual(revision.scriptPubKey,a.contract.scriptPubKey);
 const otherOrigin=createProductionContract(a.store,a.context,{...a.options,origin:'https://other.example.test'});assert.notEqual(otherOrigin.scriptPubKey,a.contract.scriptPubKey);
 assert.match(a.contract.witnessScript,/^5221/);
});
test('stale source or approvals cannot reserve an order and protected payment modes cannot be rewritten',t=>{
 const f=approvedFixture(t);f.store.db.prepare("INSERT INTO market_order_payment_modes VALUES(?,'direct',?)").run(f.id,now);
 f.service.reserve(f.context,{expectedContractHash:f.c.contractHash,now});
 for(const sql of ["UPDATE market_order_payment_modes SET mode='escrow_setup' WHERE order_id=?",'DELETE FROM market_order_payment_modes WHERE order_id=?'])assert.throws(()=>f.store.db.prepare(sql).run(f.id),/reserved escrow/);
 const other=approvedFixture(t);changeOrder(other.store,{id:other.id,action:'cancel',confirm:true},other.actors.buyer,now);
 assert.throws(()=>other.service.reserve(other.context,{expectedContractHash:other.c.contractHash,now}),/unpaid open/);
 assert.equal(other.store.db.prepare('SELECT count(*) n FROM market_escrow_preparations').get().n,0);
});
test('an active participant can withdraw after peer restriction, but strangers and legacy capabilities cannot',t=>{
 const f=approvedFixture(t),pin={expectedContractHash:f.c.contractHash,now};f.service.reserve(f.context,pin);
 f.store.db.prepare("INSERT INTO market_restrictions VALUES('account',?,'banned','Synthetic test restriction',?)").run(f.accounts.seller,now);
 assert.throws(()=>f.service.reserve(f.context,pin),/restricted/);
 for(const actor of [f.actors.other,tokens.buyer,{accountId:f.accounts.buyer}])assert.throws(()=>f.service.withdraw({...f.context,actor},pin));
 assert.throws(()=>f.service.withdraw(f.seller,pin),/restricted/);
 assert.equal(f.service.withdraw(f.context,pin).preparationReserved,false);
 assert.equal(f.store.db.prepare('SELECT count(*) n FROM market_escrow_preparations').get().n,0);
});

test('unfunded production review records follow source-order retention',t=>{
 const f=fixture(t),service=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});service.propose(f.context,f.options);
 f.store.db.prepare('DELETE FROM market_orders WHERE id=?').run(f.id);service.prune();assert.equal(f.store.db.prepare('SELECT COUNT(*) AS n FROM market_escrow_contract_reviews').get().n,0);
});

test('production review binds actual account-owned order, keys, scripts and amounts without enabling funding',t=>{
 const f=fixture(t),c=f.contract;assert.equal(c.sellerPriceSats,'500000000');assert.equal(c.totalDepositSats,'500010000');assert.match(c.scriptPubKey,/^0020[a-f0-9]{64}$/);assert.equal(c.witnessScript.length,210);assert.equal(c.payoutScripts.buyer.length,44);assert.equal(c.fundingEnabled,false);
 for(const actor of [tokens.buyer,f.actors.other,{accountId:f.accounts.buyer}])assert.throws(()=>createProductionContract(f.store,{...f.context,actor},f.options));
 assert.equal(f.store.db.prepare('SELECT * FROM market_order_payment_modes WHERE order_id=?').get(f.id),undefined);
 for(const change of [{keys:{...keys,seller:keys.buyer}},{buyerFeeReserveSats:'100001'},{origin:'http://127.0.0.1:4368'},{expectedPreflightHash:'0'.repeat(64)}])assert.throws(()=>createProductionContract(f.store,f.context,{...f.options,...change}));
});

test('rehashed contract tampering fails semantic checks and independent pins reject otherwise valid alternatives',t=>{
 const {contract:c}=fixture(t);
 for(const change of [v=>v.chainProfile.network='regtest',v=>v.fundingEnabled=true,v=>v.sellerPriceSats='499999999',v=>v.totalDepositSats='500000001',v=>v.scriptPubKey='0020'+'a'.repeat(64),v=>v.payoutScripts.buyer=v.payoutScripts.seller,v=>v.feePolicy.replacement='automatic',v=>v.unexpected=true,v=>v.preflight.accountBindingHash='a'.repeat(64)]){
  const v=structuredClone(c);change(v);delete v.contractHash;v.contractHash=hash(v);assert.throws(()=>validateProductionContract(v));
 }
 const q=createProductionContractChallenge(c,{role:'buyer',now}),p=proof(q,11);assert.equal(verifyProductionContractProof(c,p,verifyOptions(c)).keyControlVerified,true);
 for(const change of [{expectedContractHash:'0'.repeat(64)},{origin:'https://other.example.test'},{role:'seller'},{expectedMediatorPublicKey:keys.seller},{now:now-1},{now:now+900000}])assert.throws(()=>verifyProductionContractProof(c,p,{...verifyOptions(c),...change}));
 for(const p2 of [proof(q,22),proof(q,11,{highS:true}),proof(q,11,{wrongDomain:true}),{...p,schema:'xbt-unfunded-consent-proof-v1'},{...p,signature:p.signature+'\n'}])assert.throws(()=>verifyProductionContractProof(c,p2,verifyOptions(c)));
});

test('durable contract review enforces role, challenge replay, withdrawal and source binding',t=>{
 const f=fixture(t),config={enabled:true,origin,mediatorPublicKey:keys.market};let service=createProductionContractStore(f.store,config);
 const c=service.propose(f.context,f.options).contract;
 assert.deepEqual(service.propose(f.context,f.options).contract,c);
 let buyerProof;
 for(const [role,scalar] of [['buyer',11],['seller',22],['market',33]]){const context=role==='seller'?f.seller:f.context,q=service.challenge(context,{role,expectedContractHash:c.contractHash,now}),p=proof(q,scalar);if(role==='buyer')buyerProof=p;service.submit(context,p,now+1);}
 assert.equal(service.receipt(f.context).fundingEnabled,false);assert.equal(service.view(f.context).allKeysVerified,true);
 service=createProductionContractStore(f.store,config);assert.equal(service.view(f.context).allKeysVerified,true);assert.equal(service.submit(f.context,buyerProof,now+900001).allKeysVerified,true);
 assert.throws(()=>service.submit(f.seller,buyerProof,now+1),/another participant/);
 assert.throws(()=>service.propose(f.context,{...f.options,buyerFeeReserveSats:'20000'}),/Withdraw/);
 service.withdraw(f.seller,{expectedContractHash:c.contractHash});assert.throws(()=>service.withdraw(f.seller,{expectedContractHash:c.contractHash}),/changed/);assert.throws(()=>service.submit(f.context,buyerProof,now+1),/withdrawn/);assert.throws(()=>service.receipt(f.context));
 const next=service.propose(f.context,{...f.options,buyerFeeReserveSats:'20000'}).contract;assert.equal(next.revision,3);
 const q=service.challenge(f.context,{role:'buyer',expectedContractHash:next.contractHash,now});assert.throws(()=>service.submit(f.context,proof({...q,nonce:'a'.repeat(64)},11),now+1),/Unknown/);
 const body=JSON.parse(f.store.db.prepare('SELECT body FROM market_orders WHERE id=?').get(f.id).body);body.terms+=' changed';f.store.db.prepare('UPDATE market_orders SET body=? WHERE id=?').run(JSON.stringify(body),f.id);assert.throws(()=>service.submit(f.context,proof(q,11),now+1),/changed/);
 assert.throws(()=>createProductionContractStore(f.store,{...config,mediatorPublicKey:keys.seller}).view(f.context));
});

test('guided signer selections are own-role, order-bound and never ownership proof',t=>{
 const f=fixture(t),service=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});
 const enrollment=role=>({schema:'xbt-production-enrollment-v1',chainProfile:f.contract.chainProfile,origin,role,publicKey:keys[role],recoveryVerifiedLocally:true});
 const select=(ctx,role,extra={})=>service.selectSigner(ctx,{expectedPreflightHash:f.options.expectedPreflightHash,enrollment:{...enrollment(role),...extra}});
 for(const actor of [f.actors.other,tokens.buyer,{accountId:f.accounts.buyer}])assert.throws(()=>select({...f.context,actor},'buyer'));
 assert.throws(()=>select(f.context,'seller'));
 for(const extra of [{origin:'https://evil.test'},{chainProfile:{}},{recoveryVerifiedLocally:false},{privateKey:'never'},{publicKey:keys.market}])assert.throws(()=>select(f.context,'buyer',extra));
 assert.equal(select(f.context,'buyer').ownershipVerified,false);
 assert.throws(()=>service.proposeConnected(f.context,f.options),/Both/);
 select(f.seller,'seller');
 assert.throws(()=>service.propose(f.context,{...f.options,keys:{...keys,buyer:keys.seller,seller:keys.buyer}}),/selected/);
 const c=service.proposeConnected(f.context,f.options).contract;
 assert.deepEqual(c.keys,keys);assert.equal(service.inspect(f.context).allKeysVerified,false);
 const q=service.challenge(f.context,{role:'buyer',expectedContractHash:c.contractHash,now});service.submit(f.context,proof(q,11),now+1);
 assert.throws(()=>select(f.seller,'seller',{publicKey:'02'+ '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798'}),/Withdraw/);
 assert.equal(select(f.context,'buyer').selectedKeys.buyer,keys.buyer);
});
test('changing an unsigned selection invalidates old challenges and changed order invalidates selections',t=>{
 const f=fixture(t),service=createProductionContractStore(f.store,{enabled:true,origin,mediatorPublicKey:keys.market});
 const c=service.propose(f.context,f.options).contract,q=service.challenge(f.context,{role:'buyer',expectedContractHash:c.contractHash,now});
 service.selectSigner(f.context,{expectedPreflightHash:f.options.expectedPreflightHash,enrollment:{schema:'xbt-production-enrollment-v1',chainProfile:c.chainProfile,origin,role:'buyer',publicKey:keys.buyer,recoveryVerifiedLocally:true}});
 assert.throws(()=>service.submit(f.context,proof(q,11),now+1),/withdrawn/);
 const body=JSON.parse(f.store.db.prepare('SELECT body FROM market_orders WHERE id=?').get(f.id).body);body.terms+=' changed';f.store.db.prepare('UPDATE market_orders SET body=? WHERE id=?').run(JSON.stringify(body),f.id);
 assert.throws(()=>service.proposeConnected(f.context,f.options),/Both/);
});
