import {createHash} from 'node:crypto';
import {isAccountActor,assertActorActive} from './market-identity.mjs';
export function initializeEngagement(store){store.db.exec(`
 CREATE TABLE IF NOT EXISTS market_listing_views(listing_id TEXT PRIMARY KEY,total INTEGER NOT NULL DEFAULT 0);
 CREATE TABLE IF NOT EXISTS market_listing_view_visitors(listing_id TEXT NOT NULL,visitor_hash TEXT NOT NULL,day INTEGER NOT NULL,PRIMARY KEY(listing_id,visitor_hash,day));
 CREATE TABLE IF NOT EXISTS market_saved_items(account_id TEXT NOT NULL,listing_id TEXT NOT NULL,created INTEGER NOT NULL,PRIMARY KEY(account_id,listing_id));
`);}
const available=(store,id,now)=>store.db.prepare("SELECT id,body FROM market_listings WHERE id=? AND status='published' AND expires>?").get(id,now);
export const listingViewCount=(store,id)=>store.db.prepare('SELECT total FROM market_listing_views WHERE listing_id=?').get(id)?.total||0;
export function recordListingView(store,id,visitor,now=Date.now()){
 if(typeof visitor!=='string'||! /^[a-f0-9-]{36}$/.test(visitor))throw Error('Invalid view request.');
 if(!available(store,id,now))throw Error('This offer is unavailable.');
 const day=Math.floor(now/86400000),hash=createHash('sha256').update(visitor+':'+day).digest('hex');
 store.db.exec('BEGIN IMMEDIATE');try{
  store.db.prepare('DELETE FROM market_listing_view_visitors WHERE day<?').run(day);
  const inserted=store.db.prepare('INSERT OR IGNORE INTO market_listing_view_visitors VALUES(?,?,?)').run(id,hash,day);
  if(inserted.changes)store.db.prepare('INSERT INTO market_listing_views VALUES(?,1) ON CONFLICT(listing_id) DO UPDATE SET total=total+1').run(id);
  store.db.exec('COMMIT');
 }catch(e){store.db.exec('ROLLBACK');throw e;}
 return {views:listingViewCount(store,id)};
}
function signedIn(store,actor){if(!isAccountActor(store,actor))throw Error('Sign in to save items.');}
export function setSavedItem(store,actor,id,saved,now=Date.now()){
 signedIn(store,actor);assertActorActive(store,actor);
 if(typeof id!=='string'||typeof saved!=='boolean')throw Error('Choose an item and save action.');
 if(!saved){store.db.prepare('DELETE FROM market_saved_items WHERE account_id=? AND listing_id=?').run(actor.accountId,id);return {saved:false};}
 if(!available(store,id,now))throw Error('This offer is unavailable.');
 const exists=store.db.prepare('SELECT 1 FROM market_saved_items WHERE account_id=? AND listing_id=?').get(actor.accountId,id);
 if(!exists&&store.db.prepare('SELECT count(*) n FROM market_saved_items WHERE account_id=?').get(actor.accountId).n>=500)throw Error('You can save up to 500 items. Remove an item first.');
 store.db.prepare('INSERT OR IGNORE INTO market_saved_items VALUES(?,?,?)').run(actor.accountId,id,now);return {saved:true};
}
export function savedItems(store,actor,now=Date.now()){
 signedIn(store,actor);
 return store.db.prepare('SELECT listing_id,created FROM market_saved_items WHERE account_id=? ORDER BY created DESC,listing_id LIMIT 500').all(actor.accountId).map(row=>{
  const listing=available(store,row.listing_id,now);
  return listing?{id:row.listing_id,available:true,...JSON.parse(listing.body),views:listingViewCount(store,row.listing_id)}:{id:row.listing_id,available:false,title:'Item no longer available'};
 });
}
