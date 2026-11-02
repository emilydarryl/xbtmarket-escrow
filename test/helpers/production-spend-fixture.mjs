import {productionOrderTweak,ORDER_KEY_N} from '../../lib/market-escrow-order-keys.mjs';
import {syntheticProductionProof} from './production-signature.mjs';
import {reviewProductionSpend} from '../../lib/market-escrow-spend.mjs';
import {psbtMap} from '../../lib/market-escrow-psbt.mjs';
export function syntheticSpendSignature(request,role){
 const c=request.authorization.bundle.contract,key=c.keys[role],review=reviewProductionSpend(request,{expectedRequestHash:request.requestHash,expectedContractHash:c.contractHash,expectedFundingTermsHash:request.authorization.terms.fundingTermsHash,origin:c.origin,role,ownPublicKey:key,expectedMediatorPublicKey:c.keys.market});
 const proof=syntheticProductionProof({},(BigInt(({buyer:11,seller:22,market:33})[role])+productionOrderTweak(c,role))%ORDER_KEY_N,{message:()=>review.preimage});const p=review.psbt;p.input.set('02'+c.orderKeys[role],Buffer.concat([Buffer.from(proof.signature,'base64'),Buffer.from([0x21])]));
 const psbt=Buffer.concat([Buffer.from('70736274ff','hex'),psbtMap(p.global),psbtMap(p.input),...p.outputMaps.map(psbtMap)]).toString('base64');
 return {schema:'xbt-production-spend-signed-v2',orderId:c.preflight.orderId,contractHash:c.contractHash,fundingTermsHash:request.authorization.terms.fundingTermsHash,requestHash:request.requestHash,transactionHash:request.transaction.transactionHash,signerRole:role,signerPublicKey:key,orderPublicKey:c.orderKeys[role],psbt};
}
