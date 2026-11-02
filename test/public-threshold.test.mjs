import test from 'node:test';
import assert from 'node:assert/strict';
import {productionFundingFixture,authorizeFundingFixture} from './helpers/production-funding-fixture.mjs';
import {syntheticSpendSignature} from './helpers/production-spend-fixture.mjs';
import {createProductionSpend,finalizeProductionSpend} from '../lib/market-escrow-spend.mjs';
import {verifyOutput} from '../tools/verify-contract.mjs';
test('public proof: exact 2-of-3 script, zero/one/duplicate signature rejected, eligible pairs accepted',t=>{
 const f=productionFundingFixture();t.after(()=>f.store.close());
 const {authorization}=authorizeFundingFixture(f),c=f.bundle.contract;
 const script='52'+Object.values(c.orderKeys).sort().map(k=>'21'+k).join('')+'53ae';
 assert.equal(c.witnessScript,script);assert.equal(Buffer.from(script,'hex').length,105);
 assert.equal(verifyOutput(c,c.scriptPubKey).threshold,2);
 assert.throws(()=>verifyOutput(c,'0020'+'00'.repeat(32)));
 for(const [scenario,disputed,pair] of [['release',false,['buyer','seller']],['release',true,['seller','market']],['refund',true,['buyer','market']]]){
  const r=createProductionSpend(authorization,{txid:'ab'.repeat(32),vout:0,fundingBlockHash:'cd'.repeat(32),valueSats:c.totalDepositSats,scriptPubKey:c.scriptPubKey},{scenario,by:disputed?'market':'buyer',disputed,reason:'Public synthetic threshold demonstration',networkFeeSats:'2000',sellerAwardSats:null});
  const signed=pair.map(role=>syntheticSpendSignature(r,role));
  assert.throws(()=>finalizeProductionSpend(r,[]),/Two distinct/);
  assert.throws(()=>finalizeProductionSpend(r,[signed[0]]),/Two distinct/);
  assert.throws(()=>finalizeProductionSpend(r,[signed[0],signed[0]]),/Two distinct/);
  assert.ok(finalizeProductionSpend(r,signed).rawTx);
 }
});
