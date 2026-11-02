import test from 'node:test';
import assert from 'node:assert/strict';
import {createECDH} from 'node:crypto';
import {productionOrderKeys,productionOrderTweak,ORDER_KEY_N} from '../lib/market-escrow-order-keys.mjs';
import {productionFundingFixture} from './helpers/production-funding-fixture.mjs';
import {validateProductionContract} from '../lib/market-escrow-contract.mjs';
import {escrowDraftHash as hash} from '../lib/market-escrow-economics.mjs';
test('public order derivation matches OpenSSL synthetic private derivation and binds all participants and context',t=>{
 const f=productionFundingFixture();t.after(()=>f.store.close());const c=f.bundle.contract,base=productionOrderKeys(c);
 for(const [role,scalar] of [['buyer',11n],['seller',22n],['market',33n]]){
  const secret=Buffer.from(((scalar+productionOrderTweak(c,role))%ORDER_KEY_N).toString(16).padStart(64,'0'),'hex'),ec=createECDH('secp256k1');
  try{ec.setPrivateKey(secret);assert.equal(ec.getPublicKey('hex','compressed'),base[role]);assert.notEqual(base[role],c.keys[role]);}finally{secret.fill(0);}
 }
 for(const change of [x=>x.revision++,x=>x.origin='https://other.example.test',x=>x.preflight.orderId='11111111-1111-4111-8111-111111111111',x=>x.preflight.preflightHash='ab'.repeat(32),x=>x.chainProfile.checkpointHash='cd'.repeat(32),x=>{[x.keys.buyer,x.keys.seller]=[x.keys.seller,x.keys.buyer];}]){
  const altered=structuredClone(c);change(altered);const keys=productionOrderKeys(altered);for(const role of Object.keys(keys))assert.notEqual(keys[role],base[role]);
 }
 assert.throws(()=>productionOrderTweak(c,'unknown'));
});
test('rehashed wrong order keys and obsolete scripts are rejected rather than silently upgraded',t=>{
 const f=productionFundingFixture();t.after(()=>f.store.close());const c=f.bundle.contract;
 for(const change of [x=>x.orderKeys.buyer=x.keys.buyer,x=>x.schema='xbt-production-contract-review-v2',x=>x.witnessScript='20'+'00'.repeat(32)+'75'+x.witnessScript]){
  const altered=structuredClone(c);change(altered);delete altered.contractHash;altered.contractHash=hash(altered);assert.throws(()=>validateProductionContract(altered));
 }
});
