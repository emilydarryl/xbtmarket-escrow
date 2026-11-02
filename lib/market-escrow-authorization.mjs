// Internal worker loader: preserve signed funding history even after account restriction.
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
import {validateProductionFundingAuthorization} from './market-escrow-funding.mjs';
export function storedProductionAuthorization(store,id){
 const row=store.db.prepare('SELECT activated,body FROM market_escrow_funding_authorizations WHERE order_id=?').get(id);
 if(row?.activated!==1)throw Error('Complete permanent funding consent required.');
 const s=JSON.parse(row.body),a={schema:'xbt-production-funding-authorization-v1',bundle:s.bundle,terms:s.terms,proofs:s.proofs,acceptedAt:s.acceptedAt,spendingAuthorized:false};
 a.authorizationHash=hash(a);validateProductionFundingAuthorization(a);
 const reservation=store.db.prepare('SELECT contract_hash,receipt_hash FROM market_escrow_preparations WHERE order_id=?').get(id);
 if(a.terms.orderId!==id||reservation?.contract_hash!==a.terms.contractHash||reservation.receipt_hash!==a.terms.reviewReceiptHash)throw Error('Reserved authorization changed.');
 return a;
}

export function assertProductionAccountBinding(store,id,authorization){
 const row=store.db.prepare('SELECT buyer_hash,seller_id FROM market_orders WHERE id=?').get(id);
 const seller=row&&store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(row.seller_id);
 const buyer=store.db.prepare("SELECT account_id,proof_hash FROM market_account_access WHERE kind='order' AND resource_id=?").get(id);
 const sellerBinding=row&&store.db.prepare("SELECT account_id,proof_hash FROM market_account_access WHERE kind='seller' AND resource_id=?").get(row.seller_id);
 if(!buyer||!sellerBinding||buyer.proof_hash!==row?.buyer_hash||sellerBinding.proof_hash!==seller?.key_hash||hash({buyer,seller:sellerBinding})!==authorization.bundle.contract.preflight.accountBindingHash)throw Error('Approved participant account bindings changed.');
}
