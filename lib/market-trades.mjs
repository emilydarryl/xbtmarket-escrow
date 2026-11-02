import {satsXbt} from './market-usd-pricing.mjs';
import {shippingEscrowPolicy,requiredShippingEscrow} from './market-escrow-policy.mjs';
import {initializeLedger,captureOrderLedger,captureMarketLedger} from './market-ledger.mjs';
import {destinationCountry} from '../public/market-shipping.js';
import {createHash} from 'node:crypto';
import {feePolicy} from './market-fee-policy.mjs';
import {initializeEscrowPreparation} from './market-escrow-preparation.mjs';
import {initializeIdentity,assertActorActive,assertCapabilityActive,isAccountActor,accountPrincipal,authorizedCapability,grantAccountAccess} from './market-identity.mjs';
const digest=v=>createHash('sha256').update(v).digest('hex');
const uuid=v=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(v||'');
const key=v=>/^[a-f0-9]{64}$/.test(v||'');
const text=(v,min,max)=>{if(typeof v!=='string'||v.trim().length<min||v.trim().length>max||/[\x00-\x08\x0b-\x1f]/.test(v))throw Error('Please check the required fields.');return v.trim();};
function limit(s,name,now,max){const bucket=Math.floor(now/3600000),old=s.get(name),count=old?.bucket===bucket?old.count:0;if(count>=max)throw Error('Too many requests. Please try again later.');s.set(name,{bucket,count:count+1});}
export function initializeTrades(s){initializeIdentity(s);initializeLedger(s);s.db.exec(`CREATE TABLE IF NOT EXISTS market_sellers(id TEXT PRIMARY KEY,created INTEGER NOT NULL,key_hash TEXT NOT NULL,name TEXT NOT NULL,published INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS market_orders(id TEXT PRIMARY KEY,created INTEGER NOT NULL,updated INTEGER NOT NULL,seller_id TEXT NOT NULL,buyer_hash TEXT NOT NULL,status TEXT NOT NULL,body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS market_order_events(order_id TEXT NOT NULL,time INTEGER NOT NULL,actor TEXT NOT NULL,action TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS market_order_payment_modes(order_id TEXT PRIMARY KEY,mode TEXT NOT NULL,updated INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS market_event_order ON market_order_events(order_id,time);
CREATE INDEX IF NOT EXISTS market_order_seller ON market_orders(seller_id,created);`);if(!s.db.prepare("PRAGMA table_info(market_sellers)").all().some(c=>c.name==='published'))s.db.exec("ALTER TABLE market_sellers ADD COLUMN published INTEGER NOT NULL DEFAULT 0");initializeEscrowPreparation(s);}
export function sellerAccess(s,id,token){if(!uuid(id))throw Error('Private seller link unavailable.');const r=s.db.prepare('SELECT id,created,name,key_hash FROM market_sellers WHERE id=?').get(id);if(!r||!authorizedCapability(s,token,'seller',id,r.key_hash))throw Error('Private seller link unavailable.');const {key_hash,...profile}=r;return profile;}
export function createSeller(s,b,token,now=Date.now(),account=null){assertActorActive(s,account);assertActorActive(s,token);if(!uuid(b.id)||!key(token)||b.consent!==true||b.fax)throw Error('Check the profile details and consent.');const name=text(b.name,2,80),old=s.db.prepare('SELECT * FROM market_sellers WHERE id=?').get(b.id);if(old){if(old.key_hash!==digest(token)||old.name!==name)throw Error('Profile identifier already used.');return {id:old.id,name:old.name,created:old.created};}limit(s,'market-profile-limit',now,30);s.db.prepare('INSERT INTO market_sellers(id,created,key_hash,name) VALUES(?,?,?,?)').run(b.id,now,digest(token),name);return {id:b.id,name,created:now};}
const listing=r=>({...JSON.parse(r.body),id:r.id,status:r.status,created:r.created,updated:r.updated,expires:r.expires});
const order=r=>({...JSON.parse(r.body),id:r.id,status:r.status,created:r.created,updated:r.updated});
export function sellerDashboard(s,id,token){const profile=sellerAccess(s,id,token);return {profile,listings:s.db.prepare("SELECT * FROM market_listings WHERE json_extract(body,'$.profileId')=? ORDER BY created DESC LIMIT 100").all(id).map(listing),orders:s.db.prepare('SELECT * FROM market_orders WHERE seller_id=? ORDER BY created DESC LIMIT 100').all(id).map(order)};}
export function publicSeller(s,id,now=Date.now()){if(!uuid(id))throw Error('Seller profile unavailable.');const profile=s.db.prepare('SELECT id,created,name FROM market_sellers WHERE id=? AND published=1').get(id);const listings=s.db.prepare("SELECT * FROM market_listings WHERE json_extract(body,'$.profileId')=? AND status='published' AND expires>? ORDER BY created DESC LIMIT 100").all(id,now).map(listing);if(!profile)throw Error('Seller profile is not public yet. It appears after the first offer is approved.');return {profile,listings};}
export function attachListing(s,b,token){assertActorActive(s,token);const profile=sellerAccess(s,b.sellerId,token);if(!uuid(b.listingId)||!key(b.listingToken))throw Error('Private listing link unavailable.');const r=s.db.prepare('SELECT * FROM market_listings WHERE id=? AND token_hash=?').get(b.listingId,digest(b.listingToken));if(!r)throw Error('Private listing link unavailable.');const body=JSON.parse(r.body);if(body.profileId&&body.profileId!==profile.id)throw Error('Listing already belongs to a different profile.');if(!['pending','published'].includes(r.status))throw Error('Only open listings can be linked.');body.profileId=profile.id;body.seller=profile.name;
// Changing the public seller identity requires a fresh moderation decision.
s.db.prepare("UPDATE market_listings SET body=?,status='pending',updated=? WHERE id=?").run(JSON.stringify(body),Date.now(),r.id);return {id:r.id,status:'pending'};}
export function createOrder(s,b,token,now=Date.now(),feesEnabled=false,account=null,usdQuotes=null){assertActorActive(s,account);assertActorActive(s,token);if(!uuid(b.id)||!uuid(b.listingId)||!key(token)||b.consent!==true||b.fax)throw Error('Check your request and consent.');const old=s.db.prepare('SELECT * FROM market_orders WHERE id=?').get(b.id);
const proposed={listingId:b.listingId,buyer:text(b.buyer,2,80),contact:text(b.contact===undefined?'':b.contact,0,250),terms:text(b.terms,20,1500),total:text(b.total,1,24).replace(/^\./,'0.')};
if(!/^(0|[1-9]\d{0,9})(\.\d{1,8})?$/.test(proposed.total)||BigInt(proposed.total.replace('.',''))===0n)throw Error('Enter a positive total in XBT with up to eight decimals.');
if(proposed.contact&&!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$/.test(proposed.contact)){let u;try{u=new URL(proposed.contact);}catch{throw Error('Use a contact email or HTTPS link.');}if(u.protocol!=='https:'||u.username||u.password||!u.hostname.includes('.'))throw Error('Use a contact email or HTTPS link.');}
if(b.destinationCountry!==undefined&&b.destinationCountry!=='')proposed.destinationCountry=destinationCountry(b.destinationCountry);
if(old){const saved=JSON.parse(old.body);if(saved.usdPricing&&saved.usdPricing.quoteHash!==b.quoteHash)throw Error('Request identifier already used.');if((saved.destinationCountry||'')!==(proposed.destinationCountry||''))throw Error('Request identifier already used.');if(old.buyer_hash!==digest(token)||Object.keys(proposed).some(k=>saved[k]!==proposed[k]))throw Error('Request identifier already used.');if(isAccountActor(s,account))grantAccountAccess(s,account,'order',b.id,digest(token));return order(old);}
if(s.db.prepare('SELECT id FROM market_ledger_orders WHERE id=?').get(b.id))throw Error('Order identifier is archived. Use a new request.');
const r=s.db.prepare("SELECT * FROM market_listings WHERE id=? AND status='published' AND expires>?").get(b.listingId,now);if(!r)throw Error('This offer is no longer available.');assertCapabilityActive(s,token,'listing',r.id,r.token_hash);const item=listing(r);if(!item.profileId||!s.db.prepare('SELECT id FROM market_sellers WHERE id=?').get(item.profileId))throw Error('This seller has not enabled order requests. Contact them directly.');limit(s,'market-order-limit',now,60);
if(item.priceCurrency!=='USD'&&b.quoteHash)throw Error('Listing pricing changed. Refresh the listing before requesting.');
if(item.delivery==='shipping')proposed.destinationCountry=destinationCountry(b.destinationCountry);else if(proposed.destinationCountry)throw Error('A destination country is only needed for shipped orders.');
const body={...proposed,...(item.shipping?{shipping:item.shipping}:{}),title:item.title,description:item.description,listedPrice:item.price,delivery:item.delivery,region:item.region,...(item.deliveryArea?{deliveryArea:item.deliveryArea}:{}),seller:item.seller,sellerContact:item.contact,profileId:item.profileId};
if(requiredShippingEscrow(s,{...body,created:now})){
 if(!isAccountActor(s,account))throw Error('Sign in to request a shipped order. Shipping requires escrow.');
 const seller=s.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(item.profileId);
 const bound=s.db.prepare("SELECT account_id,proof_hash FROM market_account_access WHERE kind='seller' AND resource_id=?").get(item.profileId);
 if(!bound||bound.proof_hash!==seller.key_hash||bound.account_id===account.accountId)throw Error('Shipping escrow requires distinct buyer and seller accounts. Ask the seller to connect their profile to an account.');
 assertActorActive(s,accountPrincipal(s,bound.account_id));assertCapabilityActive(s,account,'seller',item.profileId,seller.key_hash);
 body.escrowRequired=true;body.escrowPolicyRevision=shippingEscrowPolicy(s).revision;
}
if(feesEnabled)body.platformFeePolicy=feePolicy(proposed.total);
s.db.exec('BEGIN IMMEDIATE');try{if(item.priceCurrency==='USD'){if(!isAccountActor(s,account)||!usdQuotes)throw Error('Sign in and request a current USD price quote.');body.usdPricing=usdQuotes.claim({quoteHash:b.quoteHash,listing:item,buyerId:account.accountId,totalXbt:proposed.total,orderId:b.id,destinationCountry:proposed.destinationCountry});body.listedPrice=satsXbt(body.usdPricing.itemSats);body.listedPriceUsd=item.priceUsd;}s.db.prepare('INSERT INTO market_orders VALUES(?,?,?,?,?,?,?)').run(b.id,now,now,item.profileId,digest(token),'requested',JSON.stringify(body));s.db.prepare('INSERT INTO market_order_events VALUES(?,?,?,?)').run(b.id,now,'buyer','request');if(isAccountActor(s,account))grantAccountAccess(s,account,'order',b.id,digest(token));captureOrderLedger(s,b.id,now);s.db.exec('COMMIT');}catch(e){s.db.exec('ROLLBACK');throw e;}return {id:b.id,status:'requested',...body,created:now,updated:now};}
export function accessOrder(s,id,token,sellerId){if(!uuid(id))throw Error('Private order unavailable.');if(sellerId)sellerAccess(s,sellerId,token);const r=s.db.prepare('SELECT * FROM market_orders WHERE id=?').get(id);if(!r||(sellerId?r.seller_id!==sellerId:!authorizedCapability(s,token,'order',id,r.buyer_hash)))throw Error('Private order unavailable.');return {...order(r),role:sellerId?'seller':'buyer',history:s.db.prepare('SELECT time,actor,action FROM market_order_events WHERE order_id=? ORDER BY rowid').all(id)};}
const txid=v=>{if(!/^[a-fA-F0-9]{64}$/.test(v||''))throw Error('Enter the 64-character transaction ID from your wallet.');return v.toLowerCase();};
function directOrderAllowed(s,id,action){const row=s.db.prepare('SELECT created,body FROM market_orders WHERE id=?').get(id);if(row&&requiredShippingEscrow(s,{...JSON.parse(row.body),created:row.created})&&!['cancel','reject'].includes(action))throw Error('This shipped order requires escrow. Direct payment is not available. Use the escrow steps or cancel the unpaid request.');if(s.db.prepare('SELECT order_id FROM market_escrow_preparations WHERE order_id=?').get(id))throw Error('Withdraw the reserved escrow review before changing this order.');const mode=s.db.prepare('SELECT mode FROM market_order_payment_modes WHERE order_id=?').get(id)?.mode;if(mode==='lightning'&&['fulfill','complete','open_issue','issue_note','resolve_issue','support_note','report_refund','confirm_refund'].includes(action))return;if(mode&&mode!=='direct'&&!(['escrow_setup','cancelled'].includes(mode)&&['cancel','reject'].includes(action)))throw Error('This order is not available for direct payment. Both parties must close escrow setup first, or cancel this unpaid request.');}
function saveOrder(s,current,body,next,action,now){s.db.exec('BEGIN IMMEDIATE');try{directOrderAllowed(s,current.id,action);if(next==='cancelled'&&body.paymentMode==='escrow_setup')body.paymentMode='cancelled';const changed=s.db.prepare('UPDATE market_orders SET status=?,body=?,updated=? WHERE id=? AND status=?').run(next,JSON.stringify(body),now,current.id,current.status);if(changed.changes!==1)throw Error('Order status changed. Refresh before continuing.');s.db.prepare('INSERT INTO market_order_events VALUES(?,?,?,?)').run(current.id,now,current.role,action);if(next==='cancelled')s.db.prepare("UPDATE market_order_payment_modes SET mode='cancelled',updated=? WHERE order_id=?").run(now,current.id);captureOrderLedger(s,current.id,now);s.db.exec('COMMIT');}catch(e){s.db.exec('ROLLBACK');throw e;}}
function issueMessage(body,actor,b,now){if(!uuid(b.messageId))throw Error('Missing message identifier.');const message=text(b.message,5,1200),old=body.issue?.messages.find(m=>m.id===b.messageId);if(old){if(old.actor!==actor||old.text!==message)throw Error('Message identifier already used.');return false;}if((body.issue?.messages.length||0)>=40&&b.action!=='resolve_issue')throw Error('This issue thread is full. Use the contact form with your order ID.');body.issue.messages.push({id:b.messageId,actor,text:message,time:now});return true;}
export function changeOrder(s,b,token,now=Date.now()){
 const current=accessOrder(s,b.id,token,b.sellerId),body=JSON.parse(s.db.prepare('SELECT body FROM market_orders WHERE id=?').get(b.id).body);let next=current.status;
 if(b.action==='accept'){assertActorActive(s,token);const seller=s.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(current.profileId);assertCapabilityActive(s,token,'seller',current.profileId,seller.key_hash);}
 directOrderAllowed(s,current.id,b.action);
 if(b.confirm!==true)throw Error('Confirm the order action.');
 if(['open_issue','issue_note','resolve_issue'].includes(b.action)){
  if(['requested','cancelled','refunded'].includes(current.status))throw Error('This request cannot open an issue; cancel a pending request or use the contact form.');
  if(b.action==='open_issue'){body.issue??={open:false,messages:[]};if(!body.issue.open){body.issue.open=true;body.issue.openedBy=current.role;}}
  if(!body.issue)throw Error('Open an issue first.');
  if(b.action==='resolve_issue'){if(body.issue.openedBy!==current.role)throw Error('Only the participant who opened the issue can mark it resolved.');if(!body.issue.open)return current;body.issue.open=false;body.issue.resolvedAt=now;}
  if(b.action==='issue_note'&&!body.issue.open)throw Error('This issue is already resolved.');
  if(!issueMessage(body,current.role,b,now))return current;
 }else if(b.action==='ship'){
  if(current.role!=='seller'||body.delivery!=='shipping')throw Error('Only the seller can mark a shipped order.');
  if(body.issue?.open||body.refundTxid)throw Error('Resolve the issue before shipping.');
  const shipment={carrier:text(b.carrier,2,80),tracking:text(b.tracking??'',3,120),note:text(b.shippingNote??'',0,300)};
  if(/[\x00-\x1f\x7f]/.test(shipment.carrier+shipment.tracking+shipment.note))throw Error('Check shipment details.');
  if(shipment.tracking&&!/^[a-zA-Z0-9 ._\/-]+$/.test(shipment.tracking))throw Error('Enter a tracking number, not a link or address.');
  if(body.shipment){if(current.status==='fulfilled'&&['carrier','tracking','note'].every(key=>body.shipment[key]===shipment[key]))return current;throw Error('Shipment details have already been recorded.');}
  if(current.status!=='paid')throw Error('Confirm payment received before marking this order shipped.');
  body.shipment={...shipment,shippedAt:now};next='fulfilled';
 }else if(b.action==='cancel_unpaid'){
  if(b.noPayment!==true)throw Error('Confirm with the other party that no payment has been sent before cancelling.');
  if(current.status==='cancelled'&&body.cancellation?.by===current.role)return current;
  if(current.status!=='agreed'||body.paymentTxid||body.refundTxid)throw Error('Only an accepted order with no reported payment can be cancelled. Use Raise an issue if payment was sent.');
  if(body.issue?.open)throw Error('Resolve the open issue before cancelling this order.');
  body.cancellation={by:current.role,at:now};
  next='cancelled';
 }else if(b.action==='report_refund'){
  if(current.role!=='seller'||!body.issue?.open||(!body.paymentTxid&&body.paymentVerification?.method!=='lightning')||!['payment_sent','paid','fulfilled','complete'].includes(current.status))throw Error('A full-refund report requires a paid order with an open issue.');const value=txid(b.txid);if(body.refundTxid){if(body.refundTxid!==value)throw Error('A refund reference has already been recorded.');return current;}body.refundTxid=value;
 }else if(b.action==='confirm_refund'){
  if(current.role!=='buyer'||!body.refundTxid)throw Error('No seller refund report is available.');if(current.status==='refunded')return current;next='refunded';if(body.issue){body.issue.open=false;body.issue.resolvedAt=now;}
 }else{
  const rules={accept:['seller','requested','agreed'],reject:['seller','requested','cancelled'],cancel:['buyer','requested','cancelled'],report_payment:['buyer','agreed','payment_sent'],confirm_payment:['seller','payment_sent','paid'],fulfill:['seller','paid','fulfilled'],complete:['buyer','fulfilled','complete']};const rule=rules[b.action];
  if(!rule||rule[0]!==current.role)throw Error('Action is not available for this participant.');
  if(current.status===rule[2]){if(b.action==='report_payment'&&body.paymentTxid!==txid(b.txid))throw Error('A different payment reference is already recorded.');return current;}
  if(body.issue?.open)throw Error('Resolve the open issue before continuing this order.');
  if(current.status!==rule[1])throw Error('Order status changed. Refresh before continuing.');
  if(b.action==='accept'){
   if(body.platformFeePolicy&&b.acceptFee!==true)throw Error('Agree to the disclosed seller success fee before accepting this order.');
   const live=s.db.prepare("SELECT body FROM market_listings WHERE id=? AND status='published' AND expires>?").get(current.listingId,now);if(!live||JSON.parse(live.body).profileId!==current.profileId)throw Error('The offer is no longer available for acceptance.');
   const address=text(b.address,20,120);if(!/^[a-zA-Z0-9]+$/.test(address))throw Error('Enter a receiving address, not a wallet key or payment URL.');
   const confirmations=Number(b.confirmations);if(!Number.isInteger(confirmations)||confirmations<1||confirmations>100)throw Error('Choose 1â€“100 confirmations to wait for.');
   body.payment={network:'Bitcoin BLAKE2b (XBT)',address,confirmations,instructions:text(b.instructions,10,600)};
   if(body.platformFeePolicy)body.feeAcceptedAt=now;
  }
  if(b.action==='fulfill'&&body.delivery==='shipping')throw Error('Use Mark shipped and enter the carrier and tracking number.');
  if(b.action==='report_payment')body.paymentTxid=txid(b.txid);
  next=rule[2];
 }
 saveOrder(s,current,body,next,b.action,now);return accessOrder(s,b.id,token,b.sellerId);
}
export function marketIssues(s){return s.db.prepare("SELECT * FROM market_orders WHERE json_extract(body,'$.issue.open')=1 ORDER BY updated DESC LIMIT 100").all().map(order);}
export function supportOrderNote(s,b,now=Date.now()){const r=s.db.prepare('SELECT * FROM market_orders WHERE id=?').get(b.id);if(!r)throw Error('Order unavailable.');const body=JSON.parse(r.body);if(!body.issue?.open)throw Error('Issue is not open.');if(!issueMessage(body,'support',b,now))return {id:b.id};saveOrder(s,{id:b.id,status:r.status,role:'support'},body,r.status,'support_note',now);return {id:b.id};}
export function pruneTrades(s,now=Date.now()){captureMarketLedger(s,now);s.db.prepare('DELETE FROM market_order_events WHERE order_id IN (SELECT id FROM market_orders WHERE created<? AND id NOT IN (SELECT order_id FROM market_escrow_preparations) AND id NOT IN (SELECT order_id FROM market_order_payment_modes WHERE mode=\'lightning\'))').run(now-180*86400000);s.db.prepare('DELETE FROM market_orders WHERE created<? AND id NOT IN (SELECT order_id FROM market_escrow_preparations) AND id NOT IN (SELECT order_id FROM market_order_payment_modes WHERE mode=\'lightning\')').run(now-180*86400000);s.db.prepare("DELETE FROM market_sellers WHERE created<? AND id NOT IN (SELECT resource_id FROM market_account_access WHERE kind='seller') AND id NOT IN (SELECT seller_id FROM market_orders) AND id NOT IN (SELECT seller_id FROM market_conversations WHERE seller_id IS NOT NULL) AND id NOT IN (SELECT json_extract(body,'$.profileId') FROM market_listings WHERE json_extract(body,'$.profileId') IS NOT NULL)").run(now-365*86400000);}
