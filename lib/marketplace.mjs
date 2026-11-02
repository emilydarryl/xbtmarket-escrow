import {initializeEngagement,listingViewCount} from './market-engagement.mjs';
import {usdListingPrice} from './market-usd-pricing.mjs';
import {captureListingLedger} from './market-ledger.mjs';
import {recordTakedown,reasonText,assertListingIdentityActive} from './market-moderation.mjs';
import {shippingPolicy} from '../public/market-shipping.js';
import {screenListing} from './market-screening.mjs';
import {initializeTrades,sellerAccess,pruneTrades} from './market-trades.mjs';
import {createHash} from 'node:crypto';
import {listingPhotos,cleanPhoto,PHOTO_LIMIT,PHOTO_STORAGE_BYTES} from './market-photos.mjs';
import {initializeConversations,pruneConversations} from './market-conversations.mjs';
import {assertActorActive,assertCapabilityActive,initializeIdentity,isAccountActor,authorizedCapability,grantAccountAccess} from './market-identity.mjs';
const hash = value => createHash('sha256').update(value).digest('hex');
export const marketCategories = ['mining','electronics','digital','services','other'];
function listingPrice(value){
  const price=typeof value==='string'?value.trim().replace(/^\./,'0.'):'';
  if(price.length>24||!/^(0|[1-9]\d{0,9})(\.\d{1,8})?$/.test(price)||BigInt(price.replace('.',''))===0n)throw Error('Enter a positive XBT price with up to 8 decimal places.');
  return price;
}
function listingArea(value,required=false){
  const text=typeof value==='string'?value.trim():'';
  if((required&&text.length<2)||text.length>150||/[\x00-\x1f\x7f]/.test(text))throw Error(required?'Enter your town/city, state or region, and country. Do not include a street address.':'Check the delivery or service coverage (up to 150 characters).');
  return text;
}
export function initializeMarketplace(store) {
  initializeIdentity(store);initializeEngagement(store);
  initializeTrades(store);
  store.db.exec(`CREATE TABLE IF NOT EXISTS market_listings(id TEXT PRIMARY KEY,created INTEGER NOT NULL,updated INTEGER NOT NULL,expires INTEGER NOT NULL,status TEXT NOT NULL,token_hash TEXT NOT NULL,body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS market_listing_screening(listing_id TEXT PRIMARY KEY,version INTEGER NOT NULL,status TEXT NOT NULL,reasons TEXT NOT NULL,checked INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS market_status ON market_listings(status,expires);
    CREATE TABLE IF NOT EXISTS market_listing_photos(listing_id TEXT NOT NULL,position INTEGER NOT NULL,bytes BLOB NOT NULL,PRIMARY KEY(listing_id,position));`);
  initializeConversations(store);
}
export function validateListing(b,{profileContactOrigin=null}={}) {
  if (!b || b.fax || b.consent !== true) throw Error('Confirm the listing rules and permission to publish your contact details.');
  const field=(key,min,max)=>{const s=typeof b[key]==='string'?b[key].trim():'';if(s.length<min||s.length>max||/[\x00-\x08\x0b-\x1f]/.test(s))throw Error(`Please check ${key}.`);return s;};
  const title=field('title',5,100),description=field('description',30,2000),seller=field('seller',2,80),region=listingArea(b.region,true),deliveryArea=listingArea(b.deliveryArea);
  let contact=field('contact',5,250);
  if(b.priceCurrency!==undefined&&!['XBT','USD'].includes(b.priceCurrency))throw Error('Choose XBT or USD pricing.');
  const pricing=b.priceCurrency==='USD'?{price:null,priceCurrency:'USD',priceUsd:usdListingPrice(b.price)}:{price:listingPrice(b.price)};
  if(!marketCategories.includes(b.category)||!['shipping','pickup','digital'].includes(b.delivery))throw Error('Choose a category and delivery option.');
  if(!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$/.test(contact)) {
    let u;try{u=new URL(contact);}catch{throw Error('Use a public email address or HTTPS seller contact link.');}
    const ownProfile=profileContactOrigin&&b.profileId&&u.href===profileContactOrigin+'/market/profile?id='+encodeURIComponent(b.profileId);
    if((u.protocol!=='https:'&&!ownProfile)||u.username||u.password||(!u.hostname.includes('.')&&!ownProfile))throw Error('Use a public email address or HTTPS seller contact link.');
    contact=u.href;
  }
  const shipping=shippingPolicy(b.shipping);if(shipping&&b.delivery!=='shipping')throw Error('Shipping options require shipping delivery.');
  if(shipping?.feeCurrency==='USD'&&pricing.priceCurrency!=='USD')throw Error('Use USD asking price for USD shipping charges.');
  if(shipping&&!deliveryArea)throw Error('Enter the countries or regions you ship to.');
  return {title,description,seller,contact,region,...(shipping?{shipping}:{}),...(deliveryArea?{deliveryArea}:{}),...pricing,category:b.category,delivery:b.delivery,consent:true};
}
function identity(id,token){if(!/^[a-f0-9-]{36}$/.test(id||'')||!/^[a-f0-9]{64}$/.test(token||''))throw Error('Invalid private listing key.');}
export function submitListing(store,b,token,now=Date.now(),sellerToken=null,photoBudgetBytes=PHOTO_STORAGE_BYTES,account=null,profileContactOrigin=null,{automatic=false}={}) {
  assertActorActive(store,account);assertActorActive(store,token);assertActorActive(store,sellerToken);identity(b?.id,token);const body=validateListing(b,{profileContactOrigin:isAccountActor(store,account)?profileContactOrigin:null});if(b.profileId){const profile=sellerAccess(store,b.profileId,sellerToken);body.profileId=profile.id;body.seller=profile.name;}
  const photos=listingPhotos(b.photos,b.id);if(photos.length)body.photos=photos.map(({url,width,height,hash})=>({url,width,height,hash}));const encoded=JSON.stringify(body);
  const old=store.db.prepare('SELECT token_hash,body,status FROM market_listings WHERE id=?').get(b.id);
  if(old){if(old.token_hash!==hash(token)||old.body!==encoded)throw Error('Submission identifier already used.');if(isAccountActor(store,account))grantAccountAccess(store,account,'listing',b.id,hash(token));return {id:b.id,status:old.status};}
  if(store.db.prepare('SELECT id FROM market_ledger_listings WHERE id=?').get(b.id))throw Error('Listing identifier is archived. Use a new submission.');
  const screening=automatic?screenListing(body):{version:1,status:'pending',reasons:['Manual review requested']};
  const bucket=Math.floor(now/3600000),limit=store.get('market-intake-limit'),count=limit?.bucket===bucket?limit.count:0;
  if(count>=30)throw Error('Listing submissions are busy. Please try again in an hour.');
  store.db.exec('BEGIN IMMEDIATE');try{
    const photoBytes=photos.reduce((sum,photo)=>sum+photo.data.length,0);
    if(photoBytes&&store.db.prepare('SELECT COALESCE(SUM(length(bytes)),0) n FROM market_listing_photos').get().n+photoBytes>photoBudgetBytes)throw Error('Photo storage is temporarily full. Please try later or submit without photos.');
    store.db.prepare('INSERT INTO market_listings VALUES (?,?,?,?,?,?,?)').run(b.id,now,now,now+30*86400000,screening.status,hash(token),encoded);
    store.db.prepare('INSERT INTO market_listing_screening VALUES(?,?,?,?,?)').run(b.id,screening.version,screening.status,JSON.stringify(screening.reasons),now);
    if(screening.status==='published'&&body.profileId)store.db.prepare('UPDATE market_sellers SET published=1 WHERE id=?').run(body.profileId);
    for(const [index,photo] of photos.entries())store.db.prepare('INSERT INTO market_listing_photos VALUES(?,?,?)').run(b.id,index,photo.data);
    if(isAccountActor(store,account))grantAccountAccess(store,account,'listing',b.id,hash(token));
    store.set('market-intake-limit',{bucket,count:count+1});captureListingLedger(store,b.id,now);store.db.exec('COMMIT');
  }catch(error){store.db.exec('ROLLBACK');throw error;}
  return {id:b.id,status:screening.status};
}
function publicRow(r){return {id:r.id,created:r.created,updated:r.updated,expires:r.expires,status:r.status,...JSON.parse(r.body)};}
export function marketListings(store,now=Date.now()) {
  return store.db.prepare("SELECT l.*,COALESCE(v.total,0) AS views FROM market_listings l LEFT JOIN market_listing_views v ON v.listing_id=l.id WHERE l.status='published' AND l.expires>? ORDER BY l.created DESC LIMIT 500").all(now).map(row=>({...publicRow(row),views:row.views}));
}
export function publicListing(store,id,now=Date.now()){const row=store.db.prepare("SELECT * FROM market_listings WHERE id=? AND status='published' AND expires>?").get(id,now);return row?{...publicRow(row),views:listingViewCount(store,id)}:null;}
export function marketQueue(store){
  return store.db.prepare('SELECT * FROM market_listings ORDER BY created DESC LIMIT 500').all().map(row=>{
    const screening=store.db.prepare('SELECT reasons FROM market_listing_screening WHERE listing_id=?').get(row.id);
    const reasons=screening?JSON.parse(screening.reasons):[];
    return {...publicRow(row),reviewReasons:row.status==='pending'?(reasons.length?reasons:['Manual review required, including seller-name changes']):[]};
  });
}
export function manageListing(store,id,token,action=null,now=Date.now(),closureReason=null) {
  if(!isAccountActor(store,token))identity(id,token);
  const r=store.db.prepare('SELECT * FROM market_listings WHERE id=?').get(id);
  if(!r||!authorizedCapability(store,token,'listing',id,r.token_hash))throw Error('Private listing link is unavailable.');
  if(action!==null){assertCapabilityActive(store,token,'listing',id,r.token_hash);
    if(!['sold','withdrawn'].includes(action))throw Error('Unsupported listing action.');
    if(!['pending','published','sold','withdrawn'].includes(r.status))throw Error('This listing is closed by the moderator.');
    const reason=closureReason??(action==='sold'?'owner_reported_sold':'unspecified');
    if(!(action==='sold'?['owner_reported_sold','market_sale','sold_elsewhere']:['no_sale','sold_elsewhere','other','unspecified']).includes(reason))throw Error('Choose a valid listing closure reason.');
    const closed=store.db.prepare('SELECT * FROM market_listing_closures WHERE listing_id=?').get(id);
    if(closed){if(closed.status!==action||closed.reason!==reason)throw Error('Listing closure is already recorded. Contact support to correct it.');return {...publicRow(r),expired:r.expires<=now};}
    if(reason==='no_sale'&&store.db.prepare("SELECT id FROM market_orders WHERE json_extract(body,'$.listingId')=? AND status IN ('payment_sent','paid','fulfilled','complete','refunded') LIMIT 1").get(id))throw Error('This listing has a recorded payment or deal. Choose Other and resolve the existing order separately.');
    store.db.exec('BEGIN IMMEDIATE');try{store.db.prepare('UPDATE market_listings SET status=?,updated=? WHERE id=?').run(action,now,id);store.db.prepare('INSERT INTO market_listing_closures VALUES(?,?,?,?)').run(id,action,reason,now);captureListingLedger(store,id,now);store.db.exec('COMMIT');}catch(error){store.db.exec('ROLLBACK');throw error;}
    r.status=action;r.updated=now;
  }
  return {...publicRow(r),expired:r.expires<=now};
}
export function updateListing(store,b,token,now=Date.now(),photoBudgetBytes=PHOTO_STORAGE_BYTES){
  const current=manageListing(store,b?.id,token,null,now);const credential=store.db.prepare('SELECT token_hash FROM market_listings WHERE id=?').get(b.id);assertCapabilityActive(store,token,'listing',b.id,credential.token_hash);
  if(current.expired||!['pending','published'].includes(current.status))throw Error('Only an active or pending listing can be edited.');
  if(Object.keys(b).some(key=>!['id','action','price','priceCurrency','region','deliveryArea','expectedUpdated','photos','shipping'].includes(key)))throw Error('Only price, location, shipping options and photos can be edited here.');
  if(!Number.isSafeInteger(b.expectedUpdated)||b.expectedUpdated!==current.updated)throw Error('This listing changed. Refresh its details before saving again.');
  const currency=b.priceCurrency??current.priceCurrency??'XBT';if(!['USD','XBT'].includes(currency))throw Error('Choose XBT or USD pricing.');
  const pricing=currency==='USD'?{price:null,priceCurrency:'USD',priceUsd:usdListingPrice(b.price)}:{price:listingPrice(b.price)},region=listingArea(b.region,true),deliveryArea=listingArea(b.deliveryArea);
  const row=store.db.prepare('SELECT body FROM market_listings WHERE id=?').get(b.id),body={...JSON.parse(row.body),...pricing,region};if(currency==='XBT'){delete body.priceCurrency;delete body.priceUsd;}
  if(deliveryArea)body.deliveryArea=deliveryArea;else delete body.deliveryArea;
  if(Object.hasOwn(b,'shipping')){if(current.delivery!=='shipping')throw Error('Shipping options require shipping delivery.');body.shipping=shippingPolicy(b.shipping);if(!deliveryArea)throw Error('Enter the countries or regions you ship to.');}
  if(body.shipping?.feeCurrency==='USD'&&currency!=='USD')throw Error('Use USD asking price for USD shipping charges.');
  let photos=null;
  if(Object.hasOwn(b,'photos')){
    if(!Array.isArray(b.photos)||b.photos.length>PHOTO_LIMIT)throw Error('Use up to three listing photos.');
    photos=b.photos.map(value=>{
      if(typeof value==='string')return cleanPhoto(value);
      if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==1||typeof value.hash!=='string')throw Error('Refresh the listing and choose its photos again.');
      const index=(current.photos||[]).findIndex(photo=>photo.hash===value.hash);
      const stored=index>=0?store.db.prepare('SELECT bytes FROM market_listing_photos WHERE listing_id=? AND position=?').get(b.id,index):null;
      if(!stored||hash(stored.bytes)!==value.hash)throw Error('This photo is not part of the current listing. Refresh before saving.');
      return {...current.photos[index],data:stored.bytes};
    });
    if(photos.length)body.photos=photos.map(({hash,width,height},index)=>({url:'/api/market/photos/'+b.id+'/'+index,hash,width,height}));else delete body.photos;
  }
  const screening=screenListing({region:region!==current.region?region:'',deliveryArea:deliveryArea!==(current.deliveryArea||'')?deliveryArea:'',description:JSON.stringify(body.shipping)!==JSON.stringify(current.shipping)?Object.values(body.shipping||{}).join(' '):''}),status=current.status==='published'&&screening.status==='pending'?'pending':current.status;
  const updated=Math.max(now,current.updated+1);
  store.db.exec('BEGIN IMMEDIATE');try{
    if(photos){
      const total=store.db.prepare('SELECT COALESCE(SUM(length(bytes)),0) n FROM market_listing_photos').get().n;
      const old=store.db.prepare('SELECT COALESCE(SUM(length(bytes)),0) n FROM market_listing_photos WHERE listing_id=?').get(b.id).n;
      if(total-old+photos.reduce((sum,photo)=>sum+photo.data.length,0)>photoBudgetBytes)throw Error('Photo storage is temporarily full. Try fewer or smaller photos.');
    }
    const saved=store.db.prepare("UPDATE market_listings SET body=?,updated=?,status=? WHERE id=? AND updated=? AND status IN ('pending','published') AND expires>?").run(JSON.stringify(body),updated,status,b.id,current.updated,now);
    if(saved.changes!==1)throw Error('This listing changed. Refresh its details before saving again.');
    if(status==='pending'&&current.status==='published')store.db.prepare('INSERT OR REPLACE INTO market_listing_screening VALUES(?,?,?,?,?)').run(b.id,screening.version,status,JSON.stringify(screening.reasons),now);
    if(photos){store.db.prepare('DELETE FROM market_listing_photos WHERE listing_id=?').run(b.id);for(const [index,photo] of photos.entries())store.db.prepare('INSERT INTO market_listing_photos VALUES(?,?,?)').run(b.id,index,photo.data);}
    captureListingLedger(store,b.id,updated);store.db.exec('COMMIT');
  }catch(error){store.db.exec('ROLLBACK');throw error;}
  return manageListing(store,b.id,token,null,now);
}
export function moderateListing(store,id,action,now=Date.now(),reason) {
  const r=store.db.prepare('SELECT * FROM market_listings WHERE id=?').get(id);
  if(!r||!['publish','reject','remove','reopen'].includes(action))throw Error('Unknown listing or action.');
  if(['publish','reopen'].includes(action))assertListingIdentityActive(store,r);
  if(action==='reopen'&&(!['removed','rejected'].includes(r.status)||r.expires<=now))throw Error('Only a closed, unexpired listing can return to review.');
  if(['remove','reopen'].includes(action))reason=reasonText(reason);
  if(action==='publish'&&(r.status!=='pending'||r.expires<=now))throw Error('Only an unexpired pending listing can be published.');
  const status={publish:'published',reject:'rejected',remove:'removed',reopen:'pending'}[action];
  store.db.exec('BEGIN IMMEDIATE');try{if(action==='remove')recordTakedown(store,id,reason,now);else{store.db.prepare('UPDATE market_listings SET status=?,updated=? WHERE id=?').run(status,now,id);store.db.prepare('INSERT INTO market_moderation_events VALUES(?,?,?,?,?)').run('listing',id,action,reason||'Listing review decision',now);}if(action==='publish')store.db.prepare("UPDATE market_sellers SET published=1 WHERE id=(SELECT json_extract(body,'$.profileId') FROM market_listings WHERE id=?)").run(id);captureListingLedger(store,id,now);store.db.exec('COMMIT');}catch(e){store.db.exec('ROLLBACK');throw e;}
  return {id,status};
}
export function pruneMarketplace(store,now=Date.now()){pruneConversations(store,now);pruneTrades(store,now);store.db.prepare('DELETE FROM market_listing_reports WHERE created<?').run(now-180*86400000);store.db.prepare('DELETE FROM market_takedowns WHERE retain_until<=?').run(now);store.db.prepare('DELETE FROM market_listings WHERE created<? AND id NOT IN (SELECT listing_id FROM market_takedowns)').run(now-90*86400000);store.db.exec('DELETE FROM market_listing_photos WHERE listing_id NOT IN (SELECT id FROM market_listings); DELETE FROM market_listing_screening WHERE listing_id NOT IN (SELECT id FROM market_listings)');}
