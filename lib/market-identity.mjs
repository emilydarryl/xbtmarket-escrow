import {createHash} from 'node:crypto';
import {initializeModeration,assertAccountActive,assertResourceActive,assertCredentialActive} from './market-moderation.mjs';
const principals=new WeakMap();
export const keyDigest=value=>createHash('sha256').update(value).digest('hex');
export const validPrivateKey=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
export function initializeIdentity(store){initializeModeration(store);store.db.exec(`
 CREATE TABLE IF NOT EXISTS market_accounts(id TEXT PRIMARY KEY,username TEXT NOT NULL UNIQUE COLLATE NOCASE,display_name TEXT NOT NULL,user_handle TEXT NOT NULL UNIQUE,primary_seller TEXT,created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_account_access(account_id TEXT NOT NULL,kind TEXT NOT NULL,resource_id TEXT NOT NULL,proof_hash TEXT NOT NULL,PRIMARY KEY(kind,resource_id));
 CREATE INDEX IF NOT EXISTS market_access_owner ON market_account_access(account_id,kind);
`);}
export function accountPrincipal(store,accountId){if(!store.db.prepare('SELECT id FROM market_accounts WHERE id=?').get(accountId))throw Error('Account unavailable.');const actor=Object.freeze({accountId});principals.set(actor,store);return actor;}
export const isAccountActor=(store,actor)=>!!actor&&typeof actor==='object'&&principals.get(actor)===store;
export function grantAccountAccess(store,actor,kind,id,proofHash){
 if(!isAccountActor(store,actor)||!['seller','listing','order','chat'].includes(kind)||!/^[a-f0-9]{64}$/.test(proofHash))throw Error('Account access unavailable.');
 assertAccountActive(store,actor.accountId);assertResourceActive(store,kind,id,proofHash);
 const old=store.db.prepare('SELECT account_id,proof_hash FROM market_account_access WHERE kind=? AND resource_id=?').get(kind,id);
 if(old&&(old.account_id!==actor.accountId||old.proof_hash!==proofHash))throw Error('This record is already connected to another account.');
 if(!old)store.db.prepare('INSERT INTO market_account_access VALUES(?,?,?,?)').run(actor.accountId,kind,id,proofHash);
}
export function assertActorActive(store,actor){if(isAccountActor(store,actor))assertAccountActive(store,actor.accountId);else if(validPrivateKey(actor))assertCredentialActive(store,keyDigest(actor));}
export function assertCapabilityActive(store,actor,kind,id,proofHash){assertActorActive(store,actor);assertResourceActive(store,kind,id,proofHash);}
export function hasAccountAccess(store,actor,kind,id,proofHash){
 if(!isAccountActor(store,actor))return false;
 return !!store.db.prepare('SELECT resource_id FROM market_account_access WHERE account_id=? AND kind=? AND resource_id=? AND proof_hash=?').get(actor.accountId,kind,id,proofHash);
}
export function authorizedCapability(store,actor,kind,id,proofHash){
 if(validPrivateKey(actor))return keyDigest(actor)===proofHash;
 if(hasAccountAccess(store,actor,kind,id,proofHash))return true;
 if(kind==='listing'&&isAccountActor(store,actor)){
  const row=store.db.prepare('SELECT body,token_hash FROM market_listings WHERE id=?').get(id);if(!row||row.token_hash!==proofHash)return false;
  const profile=JSON.parse(row.body).profileId;if(!profile)return false;
  const seller=store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(profile);
  return !!seller&&hasAccountAccess(store,actor,'seller',profile,seller.key_hash);
 }
 return false;
}
