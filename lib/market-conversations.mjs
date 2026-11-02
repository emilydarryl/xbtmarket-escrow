import {createHash} from 'node:crypto';
import {sellerAccess} from './market-trades.mjs';
import {assertActorActive,assertCapabilityActive,isAccountActor,authorizedCapability,grantAccountAccess} from './market-identity.mjs';
const digest=value=>createHash('sha256').update(value).digest('hex');
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const validKey=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const text=(value,min,max)=>{if(typeof value!=='string'||value.trim().length<min||value.trim().length>max||/[\x00-\x08\x0b-\x1f]/.test(value))throw Error('Please check your name or message.');return value.trim();};
function limit(store,name,now,max){const bucket=Math.floor(now/3600000),old=store.get(name),count=old?.bucket===bucket?old.count:0;if(count>=max)throw Error('Messages are busy. Please try again later.');store.set(name,{bucket,count:count+1});}
function capacity(store,message){const usage=store.db.prepare('SELECT count(*) AS count,COALESCE(SUM(length(CAST(body AS BLOB))),0) AS bytes FROM market_conversation_messages').get();if(usage.count>=50000||usage.bytes+Buffer.byteLength(message)>32*1024*1024)throw Error('Message storage is temporarily full. Please try later.');}
export function initializeConversations(store){store.db.exec(`
 CREATE TABLE IF NOT EXISTS market_conversations(id TEXT PRIMARY KEY,listing_id TEXT NOT NULL,seller_id TEXT,buyer_hash TEXT NOT NULL,owner_hash TEXT NOT NULL,buyer TEXT NOT NULL,seller TEXT NOT NULL,title TEXT NOT NULL,created INTEGER NOT NULL,updated INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS market_conversation_seller ON market_conversations(seller_id,updated);
 CREATE INDEX IF NOT EXISTS market_conversation_listing ON market_conversations(listing_id,updated);
 CREATE TABLE IF NOT EXISTS market_conversation_messages(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,actor TEXT NOT NULL,time INTEGER NOT NULL,body TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS market_conversation_message_lookup ON market_conversation_messages(conversation_id,time);
`);}
function currentThread(store,id,now){if(!uuid(id))throw Error('Private conversation unavailable.');const thread=store.db.prepare('SELECT * FROM market_conversations WHERE id=? AND created>?').get(id,now-180*86400000);if(!thread)throw Error('Private conversation unavailable.');return thread;}
function role(store,thread,token,{sellerId,listingId}={}){
 if(!validKey(token)&&!isAccountActor(store,token))throw Error('Private conversation unavailable.');
 if(sellerId){sellerAccess(store,sellerId,token);if(thread.seller_id!==sellerId)throw Error('Private conversation unavailable.');return 'seller';}
 if(listingId){if(thread.listing_id!==listingId||!authorizedCapability(store,token,'listing',listingId,thread.owner_hash))throw Error('Private conversation unavailable.');return 'seller';}
 if(!authorizedCapability(store,token,'chat',thread.id,thread.buyer_hash))throw Error('Private conversation unavailable.');return 'buyer';
}
const summary=thread=>({id:thread.id,listingId:thread.listing_id,profileId:thread.seller_id,buyer:thread.buyer,seller:thread.seller,title:thread.title,created:thread.created,updated:thread.updated});
export function conversationView(store,id,token,access={},now=Date.now()){
 const thread=currentThread(store,id,now),actor=role(store,thread,token,access);
 const messages=store.db.prepare('SELECT id,actor,time,body AS text FROM market_conversation_messages WHERE conversation_id=? ORDER BY rowid').all(id);
 return {...summary(thread),role:actor,messages};
}
export function conversationInbox(store,token,{sellerId,listingId}={},now=Date.now()){
 if(!validKey(token)&&!isAccountActor(store,token))throw Error('Private inbox unavailable.');
 if(sellerId){sellerAccess(store,sellerId,token);return store.db.prepare('SELECT * FROM market_conversations WHERE seller_id=? AND created>? ORDER BY updated DESC LIMIT 100').all(sellerId,now-180*86400000).map(summary);}
 if(!uuid(listingId))throw Error('Private inbox unavailable.');
 const listing=store.db.prepare('SELECT id,token_hash FROM market_listings WHERE id=?').get(listingId),snapshot=store.db.prepare('SELECT owner_hash FROM market_conversations WHERE listing_id=? LIMIT 1').get(listingId),hash=listing?.token_hash||snapshot?.owner_hash,owned=hash&&authorizedCapability(store,token,'listing',listingId,hash);
 if(!owned)throw Error('Private inbox unavailable.');
 return store.db.prepare('SELECT * FROM market_conversations WHERE listing_id=? AND owner_hash=? AND created>? ORDER BY updated DESC LIMIT 100').all(listingId,hash,now-180*86400000).map(summary);
}
export function startConversation(store,body,token,now=Date.now(),account=null){assertActorActive(store,account);assertActorActive(store,token);
 if(!uuid(body?.id)||!uuid(body.listingId)||!uuid(body.messageId)||!validKey(token)||body.consent!==true||body.fax)throw Error('Check your message and privacy consent.');
 const buyer=text(body.buyer,2,80),message=text(body.message,1,2000),old=store.db.prepare('SELECT * FROM market_conversations WHERE id=?').get(body.id);
 if(old){const view=conversationView(store,body.id,token,{},now),first=view.messages[0];if(old.listing_id!==body.listingId||old.buyer!==buyer||first?.id!==body.messageId||first.text!==message)throw Error('Conversation identifier already used.');if(isAccountActor(store,account))grantAccountAccess(store,account,'chat',body.id,digest(token));return view;}
 const listing=store.db.prepare("SELECT * FROM market_listings WHERE id=? AND status='published' AND expires>?").get(body.listingId,now);if(!listing)throw Error('This offer is no longer available for a new conversation.');assertCapabilityActive(store,token,'listing',listing.id,listing.token_hash);const item=JSON.parse(listing.body);
 store.db.exec('BEGIN IMMEDIATE');try{
  limit(store,'market-conversation-intake',now,60);
  capacity(store,message);
  store.db.prepare('INSERT INTO market_conversations VALUES(?,?,?,?,?,?,?,?,?,?)').run(body.id,body.listingId,item.profileId||null,digest(token),listing.token_hash,buyer,item.seller,item.title,now,now);
  store.db.prepare('INSERT INTO market_conversation_messages VALUES(?,?,?,?,?)').run(body.messageId,body.id,'buyer',now,message);
  if(isAccountActor(store,account))grantAccountAccess(store,account,'chat',body.id,digest(token));
  store.db.exec('COMMIT');
 }catch(error){store.db.exec('ROLLBACK');throw error;}
 return conversationView(store,body.id,token,{},now);
}
export function sendConversationMessage(store,body,token,now=Date.now()){
 const view=conversationView(store,body?.id,token,body,now);const thread=currentThread(store,body.id,now);assertCapabilityActive(store,token,view.role==='buyer'?'chat':body.sellerId?'seller':'listing',view.role==='buyer'?thread.id:body.sellerId||thread.listing_id,view.role==='buyer'?thread.buyer_hash:body.sellerId?store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(body.sellerId).key_hash:thread.owner_hash);if(!uuid(body.messageId))throw Error('Missing message identifier.');const message=text(body.message,1,2000);
 const old=store.db.prepare('SELECT * FROM market_conversation_messages WHERE id=?').get(body.messageId);
 if(old){if(old.conversation_id!==body.id||old.actor!==view.role||old.body!==message)throw Error('Message identifier already used.');return view;}
 if(view.messages.length>=80)throw Error('This conversation has reached its 80-message limit.');
 store.db.exec('BEGIN IMMEDIATE');try{
  limit(store,'market-conversation-send',now,300);
  capacity(store,message);
  store.db.prepare('INSERT INTO market_conversation_messages VALUES(?,?,?,?,?)').run(body.messageId,body.id,view.role,now,message);
  store.db.prepare('UPDATE market_conversations SET updated=? WHERE id=?').run(now,body.id);
  store.db.exec('COMMIT');
 }catch(error){store.db.exec('ROLLBACK');throw error;}
 return conversationView(store,body.id,token,body,now);
}
export function pruneConversations(store,now=Date.now()){
 store.db.prepare('DELETE FROM market_conversation_messages WHERE conversation_id IN (SELECT id FROM market_conversations WHERE created<=?)').run(now-180*86400000);
 store.db.prepare('DELETE FROM market_conversations WHERE created<=?').run(now-180*86400000);
}
