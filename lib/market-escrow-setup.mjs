// Order/account binding and consent ONLY. No funding addresses, private keys,
// signing, RPC, payment or broadcast. Real escrow is deliberately unavailable.
import {createHash,ECDH} from 'node:crypto';
import {assertActorActive,assertCapabilityActive} from './market-identity.mjs';
import {accessOrder} from './market-trades.mjs';
import {createFundingDraft} from './market-escrow-economics.mjs';
const need=(ok,message)=>{if(!ok)throw Error(message);};
const hash=value=>createHash('sha256').update(value).digest('hex');
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
const digest=value=>hash(JSON.stringify(canonical(value)));
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
function publicKey(value){
 need(typeof value==='string'&&/^0[23][a-f0-9]{64}$/.test(value),'Use a compressed public key, not a recovery kit or private key.');
 try{ECDH.convertKey(Buffer.from(value,'hex'),'secp256k1',undefined,undefined,'compressed');}catch{throw Error('Invalid compressed public key.');}
 return value;
}
function snapshot(order){return {orderId:order.id,listingId:order.listingId,sellerProfileId:order.profileId,title:order.title,
 description:order.description,terms:order.terms,totalXbt:order.total,delivery:order.delivery,destinationCountry:order.destinationCountry||null,
 shipping:order.shipping||null,feePolicy:order.platformFeePolicy||null};}
export function createEscrowSetup(store,{enabled=false,origin='https://market.xbtpulse.tech',host='127.0.0.1',mediatorPublicKey}={}){
 const url=new URL(origin);
 if(enabled){
  need(url.origin===origin&&url.protocol==='http:'&&url.hostname==='127.0.0.1'&&host==='127.0.0.1','Escrow setup preview is restricted to an exact IPv4 loopback origin and bind address.');
  publicKey(mediatorPublicKey);
 }
 store.db.exec(`CREATE TABLE IF NOT EXISTS market_escrow_setups(order_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,body TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS market_escrow_setup_events(order_id TEXT NOT NULL,command_id TEXT NOT NULL,actor TEXT NOT NULL,
 payload_hash TEXT NOT NULL,revision INTEGER NOT NULL,action TEXT NOT NULL,time INTEGER NOT NULL,PRIMARY KEY(order_id,command_id));`);
 const read=id=>{const row=store.db.prepare('SELECT body FROM market_escrow_setups WHERE order_id=?').get(id);return row?JSON.parse(row.body):null;};
 function authorizationHash(id){
  const row=store.db.prepare('SELECT buyer_hash,seller_id FROM market_orders WHERE id=?').get(id);
  const seller=store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(row.seller_id);
  return digest({buyer:row.buyer_hash,seller:seller.key_hash});
 }
 function source(id,actor,sellerId){
  const order=accessOrder(store,id,actor,sellerId);
  return {order,snapshot:snapshot(order),authorizationHash:authorizationHash(id)};
 }
 function agreement(s){return s.keys.buyer&&s.keys.seller?digest({snapshotHash:s.snapshotHash,policy:'2-of-3',keys:s.keys,network:'not-enabled',fundingEnabled:false}):null;}
 function present(s,order){
  if(!s)return {enabled,available:enabled&&order.status==='requested'&&order.delivery==='shipping'&&!order.payment&&!order.paymentTxid&&!order.issue?.open,
   hold:false,fundingEnabled:false,productionEnabled:false};
  const mode=store.db.prepare('SELECT mode FROM market_order_payment_modes WHERE order_id=?').get(order.id)?.mode;
  let status=order.status==='requested'?s.status:'order_closed';
  if(order.status==='requested'&&(digest(snapshot(order))!==s.snapshotHash||authorizationHash(order.id)!==s.authorizationHash))status='order_changed';
  return {enabled,available:false,hold:mode==='escrow_setup',id:order.id,revision:s.revision,status,
   snapshot:s.snapshot,snapshotHash:s.snapshotHash,policy:'2-of-3',keys:s.keys,approvals:s.approvals,exitApprovals:s.exitApprovals,
   agreementHash:agreement(s),fundingEnabled:false,productionEnabled:false,keyOwnershipVerified:false,
   history:store.db.prepare('SELECT actor,revision,action,time FROM market_escrow_setup_events WHERE order_id=? ORDER BY revision DESC LIMIT 100').all(order.id).reverse()};
 }
 function view(id,actor,sellerId){const {order}=source(id,actor,sellerId);return present(read(id),order);}
 function orderView(order){const saved=read(order.id);return enabled||saved?present(saved,order):null;}
 function mutate(command,actor,now=Date.now()){
  need(enabled,'Escrow setup preview is disabled.');
  need(command&&uuid(command.id)&&uuid(command.commandId)&&command.confirm===true&&Number.isSafeInteger(command.revision)&&command.revision>=0,'Confirm the current escrow setup action.');
  const extras={create:[],set_key:['publicKey'],approve:['agreementHash','confirmNoPayment'],withdraw_approval:[],request_exit:[]}[command.action];
  need(extras&&Object.keys(command).every(k=>['id','sellerId','commandId','revision','confirm','action',...extras].includes(k))&&JSON.stringify(command).length<2000,'Unsupported escrow setup action or fields.');
  store.db.exec('BEGIN IMMEDIATE');
  try{
   const current=source(command.id,actor,command.sellerId),{order}=current,role=order.role;
   if(['create','set_key','approve'].includes(command.action))ensureActive(order,actor);
   const old=store.db.prepare('SELECT * FROM market_escrow_setup_events WHERE order_id=? AND command_id=?').get(order.id,command.commandId);
   if(old){need(old.actor===role&&old.payload_hash===digest(command),'Command identifier already used.');store.db.exec('COMMIT');return view(command.id,actor,command.sellerId);}
   need(order.status==='requested'&&order.delivery==='shipping'&&!order.payment&&!order.paymentTxid&&!order.refundTxid&&!order.issue?.open,'Escrow setup requires a new unpaid shipping request. Accepted and paid orders cannot be converted.');
   let s=read(command.id);
   if(command.action==='create'){
    need(!s&&command.revision===0,'This order already has an escrow setup.');
    const existingMode=store.db.prepare('SELECT mode FROM market_order_payment_modes WHERE order_id=?').get(order.id)?.mode;
    need(!existingMode||existingMode==='direct','The existing payment mode needs support review.');
    s={revision:0,status:'setup',snapshot:current.snapshot,snapshotHash:digest(current.snapshot),authorizationHash:current.authorizationHash,
     keys:{buyer:null,seller:null,market:mediatorPublicKey},approvals:[],exitApprovals:[]};
    store.db.prepare("INSERT INTO market_order_payment_modes VALUES(?,'escrow_setup',?) ON CONFLICT(order_id) DO UPDATE SET mode='escrow_setup',updated=excluded.updated").run(order.id,now);
    const original=JSON.parse(store.db.prepare('SELECT body FROM market_orders WHERE id=?').get(order.id).body);
    store.db.prepare('UPDATE market_orders SET body=?,updated=? WHERE id=?').run(JSON.stringify({...original,paymentMode:'escrow_setup'}),now,order.id);
   }else{
    need(s&&s.status!=='closed'&&command.revision===s.revision,'Setup changed. Refresh before continuing.');
    need(s.snapshotHash===digest(current.snapshot)&&s.authorizationHash===current.authorizationHash,'Order details or access changed. Cancel this unpaid order and start a new request.');
    need(s.revision<200||['request_exit','withdraw_approval'].includes(command.action),'Too many setup changes. Close this setup or cancel the request.');
    if(command.action==='set_key'){
     need(s.approvals.length===0&&s.exitApprovals.length===0,'Both approvals must be withdrawn before changing a key.');
     const value=publicKey(command.publicKey);need(Object.entries(s.keys).every(([k,v])=>k===role||v!==value),'All three signing keys must be distinct.');
     s.keys[role]=value;s.status=s.keys.buyer&&s.keys.seller?'review':'setup';
    }else if(command.action==='approve'){
     need(s.exitApprovals.length===0&&agreement(s)&&command.agreementHash===agreement(s)&&command.confirmNoPayment===true,'Review the exact setup and confirm that no payment is requested.');
     need(!s.approvals.includes(role),'This participant already approved this setup.');
     s.approvals.push(role);s.status=s.approvals.length===2?'approved':'review';
    }else if(command.action==='withdraw_approval'){
     need(s.approvals.includes(role),'This participant has no approval to withdraw.');s.approvals=s.approvals.filter(x=>x!==role);s.status=s.exitApprovals.length?'closing':'review';
    }else if(command.action==='request_exit'){
     need(!s.exitApprovals.includes(role),'This participant already requested closure.');s.exitApprovals.push(role);s.status=s.exitApprovals.length===2?'closed':'closing';
     if(s.status==='closed'){
      store.db.prepare("UPDATE market_order_payment_modes SET mode='direct',updated=? WHERE order_id=?").run(now,order.id);
      const original=JSON.parse(store.db.prepare('SELECT body FROM market_orders WHERE id=?').get(order.id).body);
      store.db.prepare('UPDATE market_orders SET body=?,updated=? WHERE id=?').run(JSON.stringify({...original,paymentMode:'direct'}),now,order.id);
     }
    }
   }
   s.revision++;
   store.db.prepare('INSERT INTO market_escrow_setups VALUES(?,?,?) ON CONFLICT(order_id) DO UPDATE SET revision=excluded.revision,body=excluded.body').run(order.id,s.revision,JSON.stringify(s));
   store.db.prepare('INSERT INTO market_escrow_setup_events VALUES(?,?,?,?,?,?,?)').run(order.id,command.commandId,role,digest(command),s.revision,command.action,now);
   store.db.exec('COMMIT');return view(command.id,actor,command.sellerId);
  }catch(error){store.db.exec('ROLLBACK');throw error;}
 }
 function prune(){store.db.exec('DELETE FROM market_escrow_setup_events WHERE order_id NOT IN (SELECT id FROM market_orders); DELETE FROM market_escrow_setups WHERE order_id NOT IN (SELECT id FROM market_orders); DELETE FROM market_order_payment_modes WHERE order_id NOT IN (SELECT id FROM market_orders);');}
 // Internal operator/test draft only; no HTTP route or automatic funding handoff.
 function ensureActive(order,actor){assertActorActive(store,actor);const profile=store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(order.profileId);assertCapabilityActive(store,actor,'seller',order.profileId,profile.key_hash);}
 function fundingDraft(id,actor,sellerId,buyerFeeReserveSats){ensureActive(accessOrder(store,id,actor,sellerId),actor);return createFundingDraft(view(id,actor,sellerId),buyerFeeReserveSats);}
 const accessRole=(id,actor,sellerId)=>source(id,actor,sellerId).order.role;
 return {enabled,view,orderView,mutate,prune,fundingDraft,accessRole};
}
