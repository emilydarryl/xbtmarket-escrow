// Read-only production integration boundary. Does not authorize funding/signing.
import {accessOrder} from './market-trades.mjs';
import {isAccountActor,accountPrincipal,assertActorActive,assertCapabilityActive} from './market-identity.mjs';
import {escrowDraftHash} from './market-escrow-economics.mjs';
const need=(v,m)=>{if(!v)throw Error(m);};
export function escrowOrderPreflightDetails(store,{id,actor,sellerId}){
 need(isAccountActor(store,actor),'An authenticated marketplace account is required.');assertActorActive(store,actor);
 const order=accessOrder(store,id,actor,sellerId);
 need(order.status==='requested'&&order.delivery==='shipping'&&!order.payment&&!order.paymentTxid&&!order.issue?.open,'An unpaid open shipping order is required.');
 need(!order.escrowRehearsalOnly,'Synthetic rehearsal orders cannot become production intents.');
 const row=store.db.prepare('SELECT buyer_hash,seller_id FROM market_orders WHERE id=?').get(id);
 const seller=store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(row.seller_id);
 const buyerAccess=store.db.prepare("SELECT account_id,proof_hash FROM market_account_access WHERE kind='order' AND resource_id=?").get(id);
 const sellerAccess=store.db.prepare("SELECT account_id,proof_hash FROM market_account_access WHERE kind='seller' AND resource_id=?").get(row.seller_id);
 need(buyerAccess?.proof_hash===row.buyer_hash&&sellerAccess?.proof_hash===seller?.key_hash&&buyerAccess.account_id!==sellerAccess.account_id,'Distinct current buyer and seller account bindings required.');
 for(const binding of [buyerAccess,sellerAccess])assertActorActive(store,accountPrincipal(store,binding.account_id));
 assertCapabilityActive(store,actor,'seller',row.seller_id,seller.key_hash);
 need(/^(0|[1-9][0-9]{0,9})(\.[0-9]{1,8})?$/.test(order.total),'Canonical order total required.');
 const [whole,part='']=order.total.split('.'),price=BigInt(whole)*100000000n+BigInt(part.padEnd(8,'0'));need(price>0n,'Positive agreed price required.');
 const snapshot={orderId:id,listingId:order.listingId,sellerProfileId:row.seller_id,title:order.title,description:order.description,terms:order.terms,totalXbt:order.total,delivery:order.delivery,destinationCountry:order.destinationCountry??null,shipping:order.shipping??null,platformFeePolicy:order.platformFeePolicy??null};
 const mode=store.db.prepare('SELECT mode FROM market_order_payment_modes WHERE order_id=?').get(id)?.mode??'direct';
 need(['direct','escrow_setup'].includes(mode),'Order already belongs to another payment workflow.');
 const data={schema:'xbt-escrow-order-preflight-v1',orderId:id,snapshotHash:escrowDraftHash(snapshot),accountBindingHash:escrowDraftHash({buyer:buyerAccess,seller:sellerAccess}),paymentMode:mode,sellerPriceSats:price.toString(),fundingEnabled:false,signingEnabled:false};
 return {preflight:{...data,preflightHash:escrowDraftHash(data)},snapshot};
}
export const escrowOrderPreflight=(store,context)=>escrowOrderPreflightDetails(store,context).preflight;
export function assertEscrowPreflightCurrent(store,context,expectedHash){
 const current=escrowOrderPreflight(store,context);need(current.preflightHash===expectedHash,'Order, participant authorization or payment mode changed.');return current;
}
