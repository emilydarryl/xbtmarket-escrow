import test from 'node:test';
import assert from 'node:assert/strict';
import {productionFundingFixture,authorizeFundingFixture} from './helpers/production-funding-fixture.mjs';
import {syntheticSpendSignature} from './helpers/production-spend-fixture.mjs';
import {createProductionSpend,reviewProductionSpend,finalizeProductionSpend,verifyProductionSpendSignature} from '../lib/market-escrow-spend.mjs';
import {escrowDraftHash as hash} from '../lib/market-escrow-economics.mjs';
test('production spend construction conserves value and requires exact non-replacement transactions and eligible signers',t=>{
 const f=productionFundingFixture();t.after(()=>f.store.close());const {authorization}=authorizeFundingFixture(f),c=f.bundle.contract,deposit={txid:'d'.repeat(64),vout:1,fundingBlockHash:'b'.repeat(64),valueSats:c.totalDepositSats,scriptPubKey:c.scriptPubKey};
 for(const [scenario,disputed,pair] of [['release',false,['buyer','seller']],['release',true,['seller','market']],['refund',true,['buyer','market']],['split-refund',true,['buyer','market']]]){
  const decision={scenario,by:disputed?'market':'buyer',disputed,reason:'Synthetic agreed payout decision',networkFeeSats:'2000',sellerAwardSats:scenario==='split-refund'?'200000000':null},r=createProductionSpend(authorization,deposit,decision);
  const reviewer=pair[0],opts={expectedRequestHash:r.requestHash,expectedContractHash:c.contractHash,expectedFundingTermsHash:f.terms.fundingTermsHash,origin:f.origin,role:reviewer,ownPublicKey:c.keys[reviewer],expectedMediatorPublicKey:c.keys.market};
  const reviewed=reviewProductionSpend(r,opts);assert.equal(reviewed.psbt.sequence.toString('hex'),'feffffff');
  const signed=pair.map(role=>syntheticSpendSignature(r,role));signed.forEach(s=>assert.equal(verifyProductionSpendSignature(r,s,s.signerRole).role,s.signerRole));
  const final=finalizeProductionSpend(r,signed);assert.equal(final.txid,r.transaction.txid);assert.equal(final.replacementAuthorized,false);assert.ok(final.virtualBytes>100&&final.virtualBytes<300);
  assert.throws(()=>finalizeProductionSpend(r,[signed[0],signed[0]]));
  const bad=structuredClone(r);bad.transaction.outputs[0].sats='1';delete bad.requestHash;bad.requestHash=hash(bad);assert.throws(()=>reviewProductionSpend(bad,{...opts,expectedRequestHash:bad.requestHash}));
  assert.throws(()=>verifyProductionSpendSignature(r,{...signed[0],requestHash:'0'.repeat(64)},signed[0].signerRole));
  const changed=createProductionSpend(authorization,deposit,{...decision,networkFeeSats:'3000'});assert.throws(()=>verifyProductionSpendSignature(changed,signed[0],signed[0].signerRole));
 }
 const decision={scenario:'release',by:'buyer',disputed:false,reason:'Synthetic selected release',networkFeeSats:'2000',sellerAwardSats:null};
 for(const fee of ['0','10001','9999'])assert.throws(()=>createProductionSpend(authorization,deposit,{...decision,networkFeeSats:fee}));
 const r=createProductionSpend(authorization,deposit,decision);assert.throws(()=>finalizeProductionSpend(r,['seller','market'].map(role=>syntheticSpendSignature(r,role))),/eligible/);
});
