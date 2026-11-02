import {escrowBindingFixture,keys} from './escrow-binding-fixture.mjs';
import {escrowOrderPreflight} from '../../lib/market-escrow-preflight.mjs';
import {createProductionContractStore} from '../../lib/market-escrow-contract-store.mjs';
import {syntheticProductionProof} from './production-signature.mjs';
import {createProductionFundingTerms,productionFundingMessage} from '../../lib/market-escrow-funding.mjs';
import {createProductionFundingStore} from '../../lib/market-escrow-funding-store.mjs';
import {feePolicy} from '../../lib/market-fee-policy.mjs';
export const fundingProof=(challenge,scalar,options={})=>syntheticProductionProof(challenge,scalar,{message:productionFundingMessage,schema:'xbt-production-funding-proof-v1',...options});
export function productionFundingFixture(path=':memory:',{price='5.00000000',now=1800000000000,origin='https://market.example.test'}={}){
 const f=escrowBindingFixture(path),context={id:f.id,actor:f.actors.buyer},seller={id:f.id,actor:f.actors.seller,sellerId:f.sellerId};
 const body=JSON.parse(f.store.db.prepare('SELECT body FROM market_orders WHERE id=?').get(f.id).body);body.total=price;body.platformFeePolicy=feePolicy(price);f.store.db.prepare('UPDATE market_orders SET body=? WHERE id=?').run(JSON.stringify(body),f.id);
 const config={enabled:true,origin,mediatorPublicKey:keys.market},reviews=createProductionContractStore(f.store,config);
 const c=reviews.propose(context,{expectedPreflightHash:escrowOrderPreflight(f.store,context).preflightHash,keys,buyerFeeReserveSats:'10000'}).contract;
 for(const [role,scalar] of [['buyer',11],['seller',22],['market',33]]){const ctx=role==='seller'?seller:context,q=reviews.challenge(ctx,{role,expectedContractHash:c.contractHash,now});reviews.submit(ctx,syntheticProductionProof(q,scalar),now+1);}
 reviews.reserve(context,{expectedContractHash:c.contractHash,now});const bundle=reviews.reviewBundle(context),terms=createProductionFundingTerms(bundle);
 return {...f,now:now+2,origin,context,seller,config,reviews,bundle,terms};
}
export function authorizeFundingFixture(f){
 const funding=createProductionFundingStore(f.store,f.reviews,{enabled:true});
 for(const [role,scalar] of [['buyer',11],['seller',22],['market',33]]){const ctx=role==='seller'?f.seller:f.context,req=funding.challenge(ctx,{expectedFundingTermsHash:f.terms.fundingTermsHash,role,now:f.now});funding.submit(ctx,fundingProof(req.challenge,scalar),f.now+1);}
 return {funding,authorization:funding.authorization(f.context)};
}
