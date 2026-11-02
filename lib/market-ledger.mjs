// Private operational records. Seller trade value is not platform income.
import {createHash} from 'node:crypto';
import {feeBinding,feePolicy,xbtToSats} from './market-fee-policy.mjs';
const has=(s,t)=>!!s.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(t);
const digest=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const amount=x=>typeof x==='string'&&/^(0|[1-9][0-9]{0,19})$/.test(x)?BigInt(x):null;
const total=x=>{try{return xbtToSats(x).toString();}catch{return null;}};
export function ledgerXbt(sats){const n=BigInt(sats);return `${n/100000000n}.${String(n%100000000n).padStart(8,'0')}`;}
export function initializeLedger(s){s.db.exec(`
 CREATE TABLE IF NOT EXISTS market_ledger_orders(id TEXT PRIMARY KEY,created INTEGER NOT NULL,updated INTEGER NOT NULL,body TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS market_ledger_listings(id TEXT PRIMARY KEY,created INTEGER NOT NULL,updated INTEGER NOT NULL,body TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS market_ledger_events(id TEXT PRIMARY KEY,kind TEXT NOT NULL,resource_id TEXT NOT NULL,time INTEGER NOT NULL,body TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS market_ledger_event_time ON market_ledger_events(time);
 CREATE TABLE IF NOT EXISTS market_listing_closures(listing_id TEXT PRIMARY KEY,status TEXT NOT NULL,reason TEXT NOT NULL,time INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_ledger_notes(note_id TEXT PRIMARY KEY,kind TEXT NOT NULL,resource_id TEXT NOT NULL,text TEXT NOT NULL,time INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS market_ledger_note_resource ON market_ledger_notes(kind,resource_id,time);
`);}
function save(s,kind,row,data,now){
 const name=kind==='order'?'market_ledger_orders':'market_ledger_listings',old=s.db.prepare(`SELECT created FROM ${name} WHERE id=?`).get(row.id);
 if(old&&old.created!==row.created)throw Error('An archived identifier cannot be reused.');
 const event={...data};delete event.lastRecordedAt;
 if(event.fee){event.fee={...event.fee};delete event.fee.lastChecked;delete event.fee.serviceUnavailable;}
 const hash=digest(event);
 s.db.prepare('INSERT OR IGNORE INTO market_ledger_events VALUES(?,?,?,?,?)').run(kind+':'+row.id+':'+hash,kind,row.id,now,JSON.stringify(event));
 s.db.prepare(`INSERT INTO ${name} VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,body=excluded.body`).run(row.id,row.created,row.updated,JSON.stringify({...data,lastRecordedAt:now}));
}
function feeRecord(s,o){
 const f=has(s,'market_order_fees')?s.db.prepare('SELECT * FROM market_order_fees WHERE order_id=?').get(o.id):null;
 const c=has(s,'market_fee_credits')?s.db.prepare('SELECT * FROM market_fee_credits WHERE order_id=?').get(o.id):null;
 let quotedSats=null,binding=null;
 try{const policy=feePolicy(o.total);if(JSON.stringify(policy)===JSON.stringify(o.platformFeePolicy))quotedSats=policy.feeSats;binding=feeBinding(o);}catch{}
 const credited=amount(c?.amount_sats),refs=f?.invoice_id&&has(s,'market_fee_payment_refs')?s.db.prepare('SELECT * FROM market_fee_payment_refs WHERE invoice_id=?').all(f.invoice_id):[];
 const evidence=!!(binding&&f&&c&&c.invoice_id===f.invoice_id&&c.amount_sats===binding.feeSats&&f.fee_sats===binding.feeSats&&f.contract_hash===binding.contractHash&&refs.length&&refs.every(p=>amount(p.amount_sats)!==null&&amount(p.amount_sats)>0n)&&refs.reduce((sum,p)=>sum+amount(p.amount_sats),0n)===credited);
 let state='no_policy';
 if(c)state=evidence&&['settled','refund_due'].includes(c.state)&&['settled','refund_due'].includes(f.state)&&f.remote_status==='Settled'?(o.status==='refunded'||c.state==='refund_due'||f.state==='refund_due'?'refund_due':'received'):'review';
 else if(f&&(!binding||['settled','refund_due','review'].includes(f.state)))state='review';
 else if(quotedSats!==null){
  if(['cancelled','refunded'].includes(o.status))state='waived';
  else if(!binding)state='not_accepted';
  else if(o.issue?.open)state='on_hold';
  else if(o.status!=='complete')state='not_due';
  else state=f?.state==='below_minimum'?'below_minimum':'uncollected';
 }
 return {state,quotedSats,accepted:!!binding,invoiceId:f?.invoice_id||null,collectionState:f?.state||null,
  creditedSats:credited===null?null:credited.toString(),creditedAt:c?.created||null,lastChecked:f?.last_checked||null,
  serviceUnavailable:!!f?.error_code,receiptEvidenceValid:evidence};
}
export function captureOrderLedger(s,id,now=Date.now()){
 const row=s.db.prepare('SELECT * FROM market_orders WHERE id=?').get(id);if(!row)return;
 const o={...JSON.parse(row.body),id:row.id,status:row.status},prior=s.db.prepare('SELECT body FROM market_ledger_orders WHERE id=?').get(id);
 const old=prior?JSON.parse(prior.body):{};
 const eventTime=action=>s.db.prepare('SELECT MIN(time) t FROM market_order_events WHERE order_id=? AND action=?').get(id,action)?.t||null;
 const fee=feeRecord(s,o);
 if(old.fee?.creditedAt&&fee.creditedSats===null){fee.state='review';fee.creditedSats=old.fee.creditedSats;fee.creditedAt=old.fee.creditedAt;fee.invoiceId=old.fee.invoiceId;fee.receiptEvidenceValid=false;}
 const data={id,listingId:o.listingId,profileId:o.profileId,title:o.title,buyer:o.buyer,seller:o.seller,created:row.created,updated:row.updated,
  status:row.status,totalSats:total(o.total),completedAt:eventTime('complete')||old.completedAt||null,refundedAt:eventTime('confirm_refund')||old.refundedAt||null,
  issueOpen:!!o.issue?.open,fee};
 save(s,'order',row,data,now);
}
export function captureListingLedger(s,id,now=Date.now()){
 const row=s.db.prepare('SELECT * FROM market_listings WHERE id=?').get(id);if(!row)return;
 const o=JSON.parse(row.body),closure=s.db.prepare('SELECT status,reason,time FROM market_listing_closures WHERE listing_id=?').get(id)||null;
 save(s,'listing',row,{id,profileId:o.profileId||null,title:o.title,seller:o.seller,listedPriceSats:total(o.price),...(o.priceCurrency==='USD'?{priceCurrency:'USD',listedPriceUsd:o.priceUsd}:{}),status:row.status,created:row.created,updated:row.updated,closure},now);
}
export function captureMarketLedger(s,now=Date.now()){
 initializeLedger(s);
 if(has(s,'market_orders'))for(const {id} of s.db.prepare('SELECT id FROM market_orders').all())captureOrderLedger(s,id,now);
 if(has(s,'market_listings'))for(const {id} of s.db.prepare('SELECT id FROM market_listings').all())captureListingLedger(s,id,now);
}
function period({from='',to=''}={}){
 const date=x=>{if(typeof x!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(x))throw Error('Use YYYY-MM-DD dates.');const time=Date.parse(x+'T00:00:00Z');if(!Number.isFinite(time)||new Date(time).toISOString().slice(0,10)!==x)throw Error('Invalid date.');return time;};
 const start=from?date(from):null,end=to?date(to)+86400000:null;if(start!==null&&end!==null&&start>=end)throw Error('The end date must not precede the start date.');
 return {from,to,timezone:'UTC',contains:t=>Number.isSafeInteger(t)&&(start===null||t>=start)&&(end===null||t<end)};
}
function rows(s,filters){
 const p=period(filters),orders=s.db.prepare('SELECT body FROM market_ledger_orders').all().map(r=>JSON.parse(r.body));
 const listings=s.db.prepare('SELECT body FROM market_ledger_listings').all().map(r=>JSON.parse(r.body));
 const related=id=>orders.filter(o=>o.listingId===id);
 const available=o=>!!s.db.prepare('SELECT id FROM market_orders WHERE id=?').get(o.id);
 const activity=[...orders.map(o=>({kind:'order',...o,eventAt:o.status==='refunded'?o.refundedAt||o.updated:o.status==='complete'?o.completedAt||o.updated:o.updated,
   sourceAvailable:available(o)})),...orders.filter(o=>o.fee.creditedAt&&o.fee.creditedSats!==null).map(o=>({kind:'fee',...o,status:o.fee.state,eventAt:o.fee.creditedAt,sourceAvailable:available(o)})),...listings.map(l=>({kind:'listing',...l,eventAt:l.closure?.time||l.updated,
   completedOrders:related(l.id).filter(o=>o.status==='complete').length,trackedOrders:related(l.id).length,sourceAvailable:!!s.db.prepare('SELECT id FROM market_listings WHERE id=?').get(l.id)}))];
 const completed=orders.filter(o=>o.status==='complete'&&p.contains(o.completedAt||o.updated));
 const received=orders.filter(o=>['received','refund_due'].includes(o.fee.state)&&p.contains(o.fee.creditedAt));
 const sum=(a,f)=>a.reduce((n,v)=>n+BigInt(f(v)),0n).toString();
 const summary={completedDeals:completed.length,reportedCompletedValueSats:completed.some(o=>o.totalSats===null)?null:sum(completed,o=>o.totalSats),
  quotedFeesOnCompletedOrdersSats:sum(completed.filter(o=>o.fee.accepted&&o.fee.quotedSats!==null),o=>o.fee.quotedSats),
  verifiedFeeReceiptsSats:sum(received,o=>o.fee.creditedSats),feeReceiptCount:received.length,
  uncollectedQuotedFeesSats:sum(completed.filter(o=>o.fee.state==='uncollected'),o=>o.fee.quotedSats),
  outstandingFeeRefundsAllDatesSats:sum(orders.filter(o=>o.fee.state==='refund_due'),o=>o.fee.creditedSats),
  feeReviewsAllDates:orders.filter(o=>o.fee.state==='review').length,
  noSaleWithdrawals:listings.filter(l=>l.status==='withdrawn'&&l.closure?.reason==='no_sale'&&p.contains(l.closure.time)).length,
  walletBalanceSats:null,netProfitSats:null};
 const kind=filters.kind||'all',status=filters.status||'all';if(!['all','order','listing','fee'].includes(kind)||typeof status!=='string'||!/^[a-z_]{1,30}$/.test(status))throw Error('Choose a valid ledger filter.');
 const inProgress=r=>r.kind==='order'&&r.sourceAvailable&&(!['complete','cancelled','refunded'].includes(r.status)||r.issueOpen);
 const filtered=activity.filter(r=>p.contains(r.eventAt)&&(kind==='all'||r.kind===kind)&&(status==='in_progress'?inProgress(r):(status==='all'||r.status===status||r.fee?.state===status||r.closure?.reason===status))).sort((a,b)=>b.eventAt-a.eventAt||a.id.localeCompare(b.id));
 return {summary,activity:filtered,period:{from:p.from,to:p.to,timezone:'UTC'}};
}
export function marketLedger(s,filters={},now=Date.now()){
 captureMarketLedger(s,now);const result=rows(s,filters),page=Number(filters.page||0);
 if(!Number.isSafeInteger(page)||page<0||page>100000)throw Error('Choose a valid ledger page.');
 const activity=result.activity.slice(page*50,page*50+50).map(row=>({...row,notes:s.db.prepare('SELECT note_id AS id,text,time FROM market_ledger_notes WHERE kind=? AND resource_id=? ORDER BY time,note_id').all(row.kind==='fee'?'order':row.kind,row.id)}));
 return {...result,activity,pagination:{page,size:50,total:result.activity.length,pages:Math.max(1,Math.ceil(result.activity.length/50))},
  notice:'Order completion and owner sale labels are participant reports. Fee receipts require recorded payment evidence. This ledger is not a live wallet balance or net-profit statement.'};
}
export function ledgerCsv(s,filters={},now=Date.now()){
 captureMarketLedger(s,now);const data=rows(s,filters);
 if(data.activity.length>50000)throw Error('Narrow the date range before exporting more than 50,000 rows.');
 const cell=value=>{let text=String(value??'');if(/^[\s]*[=+@-]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';};
 const table=[['kind','id','event_time_utc','status','title','seller','buyer','order_total_sats','listing_price_sats','closure_reason','fee_state','quoted_fee_sats','recorded_credit_sats','receipt_evidence_valid','fee_invoice_id','credit_first_observed_utc','source_available']];
 for(const r of data.activity)table.push([r.kind,r.id,new Date(r.eventAt).toISOString(),r.status,r.title,r.seller,r.buyer,r.kind==='order'?r.totalSats:null,r.listedPriceSats,r.closure?.reason,r.fee?.state,r.kind==='order'?r.fee?.quotedSats:null,r.kind==='fee'?r.fee?.creditedSats:null,r.kind==='fee'?r.fee?.receiptEvidenceValid:null,r.fee?.invoiceId,r.fee?.creditedAt?new Date(r.fee.creditedAt).toISOString():'',r.sourceAvailable]);
 return table.map(row=>row.map(cell).join(',')).join('\r\n')+'\r\n';
}
export function addLedgerNote(s,{kind,id,noteId,text},now=Date.now()){
 if(!['order','listing'].includes(kind)||typeof id!=='string'||id.length>80||typeof noteId!=='string'||!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(noteId)||typeof text!=='string'||text.trim().length<5||text.length>1000||/[\x00-\x08\x0b-\x1f\x7f]/.test(text))throw Error('Enter a private note with 5–1,000 characters.');
 captureMarketLedger(s,now);
 const table=kind==='order'?'market_ledger_orders':'market_ledger_listings';if(!s.db.prepare(`SELECT id FROM ${table} WHERE id=?`).get(id))throw Error('Ledger record unavailable.');
 const old=s.db.prepare('SELECT * FROM market_ledger_notes WHERE note_id=?').get(noteId);
 if(old){if(old.kind!==kind||old.resource_id!==id||old.text!==text.trim())throw Error('Note identifier already used.');return {saved:true};}
 if(s.db.prepare('SELECT count(*) n FROM market_ledger_notes WHERE kind=? AND resource_id=?').get(kind,id).n>=40)throw Error('This record has reached its 40-note limit.');
 s.db.prepare('INSERT INTO market_ledger_notes VALUES(?,?,?,?,?)').run(noteId,kind,id,text.trim(),now);return {saved:true};
}
