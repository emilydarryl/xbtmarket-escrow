import {captureListingLedger} from './market-ledger.mjs';
// Private operator decisions. Reads and existing trade recovery stay available.
export function initializeModeration(s){s.db.exec(`
 CREATE TABLE IF NOT EXISTS market_restrictions(kind TEXT NOT NULL,id TEXT NOT NULL,status TEXT NOT NULL,reason TEXT NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(kind,id));
 CREATE TABLE IF NOT EXISTS market_moderation_events(kind TEXT NOT NULL,id TEXT NOT NULL,action TEXT NOT NULL,reason TEXT NOT NULL,time INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_takedowns(listing_id TEXT PRIMARY KEY,reason TEXT NOT NULL,snapshot TEXT NOT NULL,retain_until INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_listing_reports(id TEXT PRIMARY KEY,listing_id TEXT NOT NULL,category TEXT NOT NULL,details TEXT NOT NULL,created INTEGER NOT NULL,closed INTEGER NOT NULL DEFAULT 0);
`);}
const table=(s,name)=>!!s.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
export const restriction=(s,kind,id)=>s.db.prepare("SELECT status,reason,updated FROM market_restrictions WHERE kind=? AND id=? AND status IN ('suspended','banned')").get(kind,id)||null;
const denied=()=>{throw Error('Marketplace activity is restricted. Existing records and order support remain available.');};
export function assertAccountActive(s,id){
 if(restriction(s,'account',id))denied();
 if(table(s,'market_sellers')&&s.db.prepare("SELECT r.id FROM market_restrictions r JOIN market_sellers p ON p.id=r.id JOIN market_account_access a ON a.kind='seller' AND a.resource_id=p.id AND a.proof_hash=p.key_hash WHERE a.account_id=? AND r.kind='seller' AND r.status IN ('suspended','banned') LIMIT 1").get(id))denied();
}
export function assertResourceActive(s,kind,id,proofHash){
 if(kind==='seller'&&restriction(s,'seller',id))denied();
 const owner=s.db.prepare('SELECT account_id FROM market_account_access WHERE kind=? AND resource_id=? AND proof_hash=?').get(kind,id,proofHash);
 if(owner)assertAccountActive(s,owner.account_id);
 if(kind==='listing'){
  const row=s.db.prepare('SELECT body,status FROM market_listings WHERE id=?').get(id);
  if(row){if(row.status==='removed')denied();const profile=JSON.parse(row.body).profileId;if(profile){const p=s.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(profile);if(p)assertResourceActive(s,'seller',profile,p.key_hash);}}
 }
}
export function assertListingIdentityActive(s,row){
 const owner=s.db.prepare("SELECT account_id FROM market_account_access WHERE kind='listing' AND resource_id=? AND proof_hash=?").get(row.id,row.token_hash);if(owner)assertAccountActive(s,owner.account_id);
 const profile=JSON.parse(row.body).profileId;if(profile){const p=s.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(profile);if(p)assertResourceActive(s,'seller',profile,p.key_hash);}
}
export function assertCredentialActive(s,digest){
 for(const owner of s.db.prepare('SELECT DISTINCT account_id FROM market_account_access WHERE proof_hash=?').all(digest))assertAccountActive(s,owner.account_id);
 if(table(s,'market_sellers'))for(const p of s.db.prepare('SELECT id FROM market_sellers WHERE key_hash=?').all(digest))assertResourceActive(s,'seller',p.id,digest);
 if(table(s,'market_listings'))for(const l of s.db.prepare('SELECT id FROM market_listings WHERE token_hash=?').all(digest))assertResourceActive(s,'listing',l.id,digest);
}
function reasonText(value){if(typeof value!=='string'||value.trim().length<5||value.trim().length>600||/[\x00-\x1f\x7f]/.test(value))throw Error('Enter a private moderation reason (5–600 characters).');return value.trim();}
export function recordTakedown(s,id,reason,now){
 const row=s.db.prepare('SELECT body,status FROM market_listings WHERE id=?').get(id);if(!row)throw Error('Listing unavailable.');
 s.db.prepare('INSERT INTO market_takedowns VALUES(?,?,?,?) ON CONFLICT(listing_id) DO UPDATE SET reason=excluded.reason,retain_until=excluded.retain_until').run(id,reason,JSON.stringify({status:row.status,body:JSON.parse(row.body)}),now+180*86400000);
 s.db.prepare("UPDATE market_listings SET status='removed',updated=? WHERE id=?").run(now,id);
 s.db.prepare('INSERT INTO market_moderation_events VALUES(?,?,?,?,?)').run('listing',id,'remove',reason,now);captureListingLedger(s,id,now);
}
export function moderateParticipant(s,{kind,id,action,reason,confirm},now=Date.now()){
 if(kind==='report'&&action==='close'&&confirm===true){reason=reasonText(reason);s.db.exec('BEGIN IMMEDIATE');try{if(s.db.prepare('UPDATE market_listing_reports SET closed=1 WHERE id=? AND closed=0').run(id).changes!==1)throw Error('Open report unavailable.');s.db.prepare('INSERT INTO market_moderation_events VALUES(?,?,?,?,?)').run('report',id,'close',reason,now);s.db.exec('COMMIT');return {kind,id,status:'closed',removed:0};}catch(e){s.db.exec('ROLLBACK');throw e;}}
 if(!['account','seller'].includes(kind)||!['suspend','ban','restore'].includes(action)||confirm!==true||typeof id!=='string')throw Error('Confirm a valid moderation action.');
 reason=reasonText(reason);const source=kind==='account'?'market_accounts':'market_sellers';
 if(!s.db.prepare(`SELECT id FROM ${source} WHERE id=?`).get(id))throw Error('Participant unavailable.');
 s.db.exec('BEGIN IMMEDIATE');try{
  const status={suspend:'suspended',ban:'banned',restore:'active'}[action];
  s.db.prepare('INSERT INTO market_restrictions VALUES(?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET status=excluded.status,reason=excluded.reason,updated=excluded.updated').run(kind,id,status,reason,now);
  let removed=0;
  if(action!=='restore'){
   const profiles=kind==='seller'?[id]:s.db.prepare("SELECT p.id FROM market_sellers p JOIN market_account_access a ON a.kind='seller' AND a.resource_id=p.id AND a.proof_hash=p.key_hash WHERE a.account_id=?").all(id).map(p=>p.id);
   const listings=s.db.prepare("SELECT id,body,token_hash FROM market_listings WHERE status IN ('published','pending')").all().filter(l=>profiles.includes(JSON.parse(l.body).profileId)||kind==='account'&&s.db.prepare("SELECT resource_id FROM market_account_access WHERE kind='listing' AND resource_id=? AND proof_hash=? AND account_id=?").get(l.id,l.token_hash,id));
   for(const l of listings){recordTakedown(s,l.id,reason,now);removed++;}
   const accounts=kind==='account'?[id]:s.db.prepare("SELECT a.account_id FROM market_account_access a JOIN market_sellers p ON a.resource_id=p.id AND a.proof_hash=p.key_hash WHERE a.kind='seller' AND p.id=?").all(id).map(a=>a.account_id);
   for(const account of accounts)for(const name of ['market_account_sessions','market_account_flows'])if(table(s,name))s.db.prepare(`DELETE FROM ${name} WHERE account_id=?`).run(account);
  }
  s.db.prepare('INSERT INTO market_moderation_events VALUES(?,?,?,?,?)').run(kind,id,action,reason,now);s.db.exec('COMMIT');
  return {kind,id,status,removed,listingsRestored:false};
 }catch(e){s.db.exec('ROLLBACK');throw e;}
}
export function moderationDesk(s,q=''){
 if(typeof q!=='string'||q.length>80)throw Error('Search with up to 80 characters.');
 const accounts=s.db.prepare('SELECT id,username,display_name AS name FROM market_accounts WHERE instr(lower(username),lower(?)) OR instr(lower(display_name),lower(?)) ORDER BY created DESC LIMIT 50').all(q,q).map(a=>({...a,restriction:restriction(s,'account',a.id)}));
 const sellers=s.db.prepare('SELECT id,name FROM market_sellers WHERE instr(lower(name),lower(?)) ORDER BY created DESC LIMIT 50').all(q).map(p=>({...p,restriction:restriction(s,'seller',p.id)}));
 return {accounts,sellers,reportCount:s.db.prepare('SELECT count(*) n FROM market_listing_reports WHERE closed=0').get().n,reports:s.db.prepare('SELECT * FROM market_listing_reports WHERE closed=0 ORDER BY created DESC LIMIT 50').all(),history:s.db.prepare('SELECT * FROM market_moderation_events ORDER BY rowid DESC LIMIT 50').all()};
}
export function reportListing(s,b,now=Date.now()){
 if(!b||typeof b.id!=='string'||!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(b.id)||!['suspected-scam','misleading','prohibited'].includes(b.category)||typeof b.details!=='string'||b.details.trim().length<20||b.details.length>1000||/[\x00-\x08\x0b-\x1f\x7f]/.test(b.details))throw Error('Choose a report reason and explain it in 20–1,000 characters.');
 if(!s.db.prepare("SELECT id FROM market_listings WHERE id=? AND status='published' AND expires>?").get(b.listingId,now))throw Error('Listing unavailable.');
 const old=s.db.prepare('SELECT * FROM market_listing_reports WHERE id=?').get(b.id);
 if(old){if(old.listing_id!==b.listingId||old.category!==b.category||old.details!==b.details.trim())throw Error('Report identifier already used.');return {submitted:true};}
 s.db.prepare('DELETE FROM market_listing_reports WHERE created<?').run(now-180*86400000);
 if(s.db.prepare('SELECT count(*) n FROM market_listing_reports').get().n>=10000)throw Error('Report inbox is full. Contact marketplace support.');
 s.db.prepare('INSERT INTO market_listing_reports VALUES(?,?,?,?,?,0)').run(b.id,b.listingId,b.category,b.details.trim(),now);return {submitted:true};
}
export {reasonText};
