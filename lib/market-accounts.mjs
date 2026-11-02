import {hashPassword,verifyPassword,validatePassword} from './market-passwords.mjs';
import {savedItems,setSavedItem} from './market-engagement.mjs';
import {randomBytes,randomUUID,timingSafeEqual} from 'node:crypto';
import {generateRegistrationOptions,verifyRegistrationResponse,generateAuthenticationOptions,verifyAuthenticationResponse} from '@simplewebauthn/server';
import {restriction} from './market-moderation.mjs';
import {assertActorActive,initializeIdentity,accountPrincipal,isAccountActor,keyDigest,validPrivateKey,grantAccountAccess,hasAccountAccess,authorizedCapability} from './market-identity.mjs';
const SESSION='__Host-xbt_market',FLOW='__Host-xbt_market_flow',minute=60000,day=86400000;
const cookie=(req,name)=>{const value=(req.headers.cookie||'').split(';').map(item=>item.trim()).find(item=>item.startsWith(name+'='))?.slice(name.length+1);return value&&/^[a-f0-9]{64}$/.test(value)?value:null;};
function setCookie(res,name,value,seconds){const existing=res.getHeader('Set-Cookie')||[];res.setHeader('Set-Cookie',[...(Array.isArray(existing)?existing:[existing]),`${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${seconds}`]);}
function limit(store,key,max,now=Date.now()){const bucket=Math.floor(now/3600000),old=store.get(key),count=old?.bucket===bucket?old.count:0;if(count>=max)throw Error('Account requests are busy. Please try again later.');store.set(key,{bucket,count:count+1});}
export function initializeAccounts(store){initializeIdentity(store);store.db.exec(`
 CREATE TABLE IF NOT EXISTS market_account_passwords(account_id TEXT PRIMARY KEY,salt TEXT NOT NULL,hash TEXT NOT NULL,updated INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_passkeys(id TEXT PRIMARY KEY,account_id TEXT NOT NULL,public_key BLOB NOT NULL,counter INTEGER NOT NULL,transports TEXT NOT NULL,device_type TEXT NOT NULL,backed_up INTEGER NOT NULL,name TEXT NOT NULL,created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_account_sessions(hash TEXT PRIMARY KEY,account_id TEXT NOT NULL,csrf TEXT NOT NULL,created INTEGER NOT NULL,last_seen INTEGER NOT NULL,expires INTEGER NOT NULL,authenticated INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_account_flows(hash TEXT PRIMARY KEY,kind TEXT NOT NULL,account_id TEXT,session_hash TEXT,data TEXT NOT NULL,expires INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_recovery_codes(hash TEXT PRIMARY KEY,account_id TEXT NOT NULL,created INTEGER NOT NULL);
`);}
export function accountSession(store,req,now=Date.now()){
 const token=cookie(req,SESSION);if(!token)return null;
 const session=store.db.prepare('SELECT s.*,a.username,a.display_name,a.primary_seller FROM market_account_sessions s JOIN market_accounts a ON a.id=s.account_id WHERE s.hash=? AND s.expires>? AND s.last_seen>?').get(keyDigest(token),now,now-7*day);
 if(!session)return null;
 if(now-session.last_seen>minute)store.db.prepare('UPDATE market_account_sessions SET last_seen=? WHERE hash=?').run(now,session.hash);
 return {...session,actor:accountPrincipal(store,session.account_id)};
}
export function newAccountSession(store,res,accountId,remember=false,now=Date.now()){
 const token=randomBytes(32).toString('hex'),csrf=randomBytes(32).toString('hex'),duration=remember?30*day:8*3600000;
 store.db.prepare('DELETE FROM market_account_sessions WHERE expires<=? OR last_seen<=?').run(now,now-7*day);
 store.db.prepare('DELETE FROM market_account_sessions WHERE hash IN (SELECT hash FROM market_account_sessions WHERE account_id=? ORDER BY created DESC,hash DESC LIMIT -1 OFFSET 19)').run(accountId);
 store.db.prepare('INSERT INTO market_account_sessions VALUES(?,?,?,?,?,?,?)').run(keyDigest(token),accountId,csrf,now,now,now+duration,now);
 setCookie(res,SESSION,token,duration/1000);return {csrf,expires:now+duration};
}
function recoveryCodes(store,accountId,now=Date.now()){
 const codes=Array.from({length:8},()=>randomBytes(20).toString('hex').match(/.{1,8}/g).join('-'));
 store.db.prepare('DELETE FROM market_recovery_codes WHERE account_id=?').run(accountId);
 for(const code of codes)store.db.prepare('INSERT INTO market_recovery_codes VALUES(?,?,?)').run(keyDigest(code.replaceAll('-','')),accountId,now);
 return codes;
}
function csrfMatches(session,req){const value=req.headers['x-market-csrf'];return !!session&&typeof value==='string'&&/^[a-f0-9]{64}$/.test(value)&&timingSafeEqual(Buffer.from(value,'hex'),Buffer.from(session.csrf,'hex'));}
export function authorizeAccountMutation(store,req,origin){const session=accountSession(store,req);if(!session||req.headers.origin!==origin||!csrfMatches(session,req))throw Error('Sign in again before changing this account.');return session;}
function flow(store,req,kind,res,now=Date.now()){
 const token=cookie(req,FLOW);if(!token)throw Error('Sign-in request expired. Please start again.');
 const saved=store.db.prepare('DELETE FROM market_account_flows WHERE hash=? AND kind=? AND expires>? RETURNING *').get(keyDigest(token),kind,now);
 setCookie(res,FLOW,'',0);if(!saved)throw Error('Sign-in request expired. Please start again.');return {...saved,data:JSON.parse(saved.data)};
}
function saveFlow(store,res,kind,data,session=null,now=Date.now()){
 limit(store,'market-auth-ceremonies',120,now);store.db.prepare('DELETE FROM market_account_flows WHERE expires<=?').run(now);
 const token=randomBytes(32).toString('hex');store.db.prepare('INSERT INTO market_account_flows VALUES(?,?,?,?,?,?)').run(keyDigest(token),kind,session?.account_id||null,session?.hash||null,JSON.stringify(data),now+5*minute);setCookie(res,FLOW,token,300);
}
function safeLabel(value,fallback){return typeof value==='string'&&value.trim().length>=2&&value.trim().length<=60&&!/[\x00-\x1f]/.test(value)?value.trim():fallback;}
function fresh(session){if(Date.now()-session.authenticated>10*minute)throw Error('Sign out and sign in again before this security change.');}
function sessionResult(store,session){
 const account=store.db.prepare('SELECT id,username,display_name,primary_seller,created FROM market_accounts WHERE id=?').get(session.account_id);
 const profiles=store.db.prepare("SELECT s.id,s.name FROM market_sellers s JOIN market_account_access a ON a.resource_id=s.id AND a.kind='seller' AND a.proof_hash=s.key_hash WHERE a.account_id=?").all(session.account_id);
 return {signedIn:true,account:{id:account.id,username:account.username,name:account.display_name,primarySeller:account.primary_seller,created:account.created,activityRestricted:(()=>{try{assertActorActive(store,session.actor);return false;}catch{return true;}})(),restriction:restriction(store,'account',account.id)?.status||null},profiles,csrf:session.csrf,reauthenticateAt:session.authenticated+10*minute,expires:session.expires};
}
export function claimAccountRecord(store,actor,{kind,id,proof}){
 if(!isAccountActor(store,actor)||!validPrivateKey(proof)||typeof id!=='string')throw Error('Open a valid saved private link.');
 const definitions={seller:['market_sellers','key_hash'],listing:['market_listings','token_hash'],order:['market_orders','buyer_hash'],chat:['market_conversations','buyer_hash']},definition=definitions[kind];if(!definition)throw Error('Unsupported private link.');
 const record=store.db.prepare(`SELECT * FROM ${definition[0]} WHERE id=?`).get(id),digest=keyDigest(proof);if(!record||record[definition[1]]!==digest)throw Error('Private link unavailable.');
 if((kind==='order'||kind==='chat')&&record.created<=Date.now()-180*day)throw Error('This private record has expired.');
 store.db.exec('BEGIN IMMEDIATE');try{grantAccountAccess(store,actor,kind,id,digest);if(kind==='seller')store.db.prepare('UPDATE market_accounts SET primary_seller=? WHERE id=?').run(id,actor.accountId);store.db.exec('COMMIT');}catch(error){store.db.exec('ROLLBACK');throw error;}
 return {connected:true,kind};
}
export function updateAccountNames(store,actor,{username,name,profileId},now=Date.now()){assertActorActive(store,actor);
 if(!isAccountActor(store,actor))throw Error('Sign in to change your account names.');
 if(typeof username!=='string'||!/^[a-zA-Z0-9][a-zA-Z0-9_-]{2,31}$/.test(username.trim()))throw Error('Use 3–32 letters, numbers, underscores or hyphens for your username.');
 username=username.trim();
 if(typeof name!=='string'||name.trim().length<2||name.trim().length>60||/[\x00-\x1f\x7f]/.test(name))throw Error('Use a public name with 2–60 characters.');name=name.trim();
 const profile=typeof profileId==='string'?store.db.prepare('SELECT * FROM market_sellers WHERE id=?').get(profileId):null;
 if(!profile||!hasAccountAccess(store,actor,'seller',profileId,profile.key_hash))throw Error('Choose a seller profile connected to your account.');
 if(store.db.prepare('SELECT id FROM market_accounts WHERE username=? AND id<>?').get(username,actor.accountId))throw Error('That username is unavailable. Choose another.');
 let listingsForReview=0;
 store.db.exec('BEGIN IMMEDIATE');try{
  store.db.prepare('UPDATE market_accounts SET username=?,display_name=? WHERE id=?').run(username,name,actor.accountId);
  store.db.prepare('UPDATE market_sellers SET name=? WHERE id=?').run(name,profileId);
  if(profile.name!==name)listingsForReview=Number(store.db.prepare("UPDATE market_listings SET body=json_set(body,'$.seller',?),status='pending',updated=? WHERE json_extract(body,'$.profileId')=? AND status IN ('pending','published') AND expires>?").run(name,now,profileId,now).changes);
  store.db.exec('COMMIT');
 }catch(error){store.db.exec('ROLLBACK');throw error;}
 return {updated:true,username,name,profileId,listingsForReview};
}
export function accountDashboard(store,actor,now=Date.now(),{section=null,page=0,orderView=order=>order}={}){
 if(!isAccountActor(store,actor))throw Error('Sign in to view your dashboard.');
 if(section!==null&&!['overview','listings','messages','orders'].includes(section)||!Number.isSafeInteger(page)||page<0||page>100000)throw Error('Choose a valid dashboard section and page.');
 const ownProfile=id=>{const row=store.db.prepare('SELECT key_hash FROM market_sellers WHERE id=?').get(id);return !!row&&hasAccountAccess(store,actor,'seller',id,row.key_hash);};
 const sellerGrant="EXISTS(SELECT 1 FROM market_account_access g JOIN market_sellers s ON s.id=g.resource_id AND s.key_hash=g.proof_hash WHERE g.account_id=? AND g.kind='seller' AND s.id=";
 const definitions={
  listings:{sql:"FROM market_listings l WHERE EXISTS(SELECT 1 FROM market_account_access g WHERE g.account_id=? AND g.kind='listing' AND g.resource_id=l.id AND g.proof_hash=l.token_hash) OR "+sellerGrant+"json_extract(l.body,'$.profileId'))",params:[actor.accountId,actor.accountId],alias:'l',sort:'l.created DESC,l.id'},
  orders:{sql:"FROM market_orders o WHERE o.created>? AND (EXISTS(SELECT 1 FROM market_account_access g WHERE g.account_id=? AND g.kind='order' AND g.resource_id=o.id AND g.proof_hash=o.buyer_hash) OR "+sellerGrant+"o.seller_id))",params:[now-180*day,actor.accountId,actor.accountId],alias:'o',sort:'o.updated DESC,o.id'},
  messages:{sql:"FROM market_conversations c WHERE c.created>? AND (EXISTS(SELECT 1 FROM market_account_access g WHERE g.account_id=? AND g.kind='chat' AND g.resource_id=c.id AND g.proof_hash=c.buyer_hash) OR EXISTS(SELECT 1 FROM market_account_access g WHERE g.account_id=? AND g.kind='listing' AND g.resource_id=c.listing_id AND g.proof_hash=c.owner_hash) OR "+sellerGrant+"c.seller_id))",params:[now-180*day,actor.accountId,actor.accountId,actor.accountId],alias:'c',sort:'c.updated DESC,c.id'}
 };
 const counts=Object.fromEntries(Object.entries(definitions).map(([name,query])=>[name,store.db.prepare('SELECT count(*) n '+query.sql).get(...query.params).n]));
 const rows=name=>{if(section!==null&&section!==name)return [];const query=definitions[name];return store.db.prepare('SELECT '+query.alias+'.* '+query.sql+' ORDER BY '+query.sort+' LIMIT ? OFFSET ?').all(...query.params,section===null?200:10,section===null?0:page*10);};
 const listings=rows('listings').map(row=>({id:row.id,created:row.created,status:row.status,expires:row.expires,...JSON.parse(row.body)}));
 const orders=rows('orders').flatMap(row=>{const body=JSON.parse(row.body),base={id:row.id,created:row.created,updated:row.updated,status:row.status,...body},entries=[];if(ownProfile(row.seller_id))entries.push({...base,role:'seller',sellerId:row.seller_id});if(hasAccountAccess(store,actor,'order',row.id,row.buyer_hash))entries.push({...base,role:'buyer'});return entries;});
 const conversations=rows('messages').flatMap(row=>{const base={id:row.id,title:row.title,buyer:row.buyer,seller:row.seller,updated:row.updated,listingId:row.listing_id},entries=[];if(row.seller_id&&ownProfile(row.seller_id))entries.push({...base,role:'seller',sellerId:row.seller_id});else if(authorizedCapability(store,actor,'listing',row.listing_id,row.owner_hash))entries.push({...base,role:'seller'});if(hasAccountAccess(store,actor,'chat',row.id,row.buyer_hash))entries.push({...base,role:'buyer'});return entries;});
 return {listings,orders:orders.map(orderView),conversations,counts,pagination:{page,size:10,total:counts[section]||0,pages:Math.max(1,Math.ceil((counts[section]||0)/10))},connected:store.db.prepare('SELECT count(*) n FROM market_account_access WHERE account_id=?').get(actor.accountId).n};
}
export async function accountRoute({store,req,res,url,send,jsonBody,origin,abuseGuard,orderView}){
 const expected=new URL(origin);if(req.headers.host?.toLowerCase().replace(/\.$/,'')!==expected.host.toLowerCase())return send(res,404,{error:'Not found'});
 const path=url.pathname.slice('/api/market/account'.length),session=accountSession(store,req);
 if(req.method==='GET'){
  if(path==='/session')return send(res,200,session?sessionResult(store,session):{signedIn:false});
  if(!session)return send(res,401,{error:'Sign in to view your account.'});
  if(path==='/dashboard'){try{return send(res,200,accountDashboard(store,session.actor,Date.now(),{section:url.searchParams.get('section'),page:Number(url.searchParams.get('page')||0),orderView}));}catch{return send(res,400,{error:'Choose a valid dashboard section and page.'});}}
  if(path==='/saved')return send(res,200,{items:savedItems(store,session.actor)});
  if(path==='/security')return send(res,200,{passwordEnabled:!!store.db.prepare('SELECT 1 FROM market_account_passwords WHERE account_id=?').get(session.account_id),passkeys:store.db.prepare('SELECT id,name,created,device_type AS deviceType,backed_up AS backedUp FROM market_passkeys WHERE account_id=? ORDER BY created').all(session.account_id),sessions:store.db.prepare('SELECT created,last_seen AS lastSeen,expires FROM market_account_sessions WHERE account_id=? AND expires>? AND last_seen>? ORDER BY created DESC LIMIT 20').all(session.account_id,Date.now(),Date.now()-7*day),recoveryCodesRemaining:store.db.prepare('SELECT count(*) n FROM market_recovery_codes WHERE account_id=?').get(session.account_id).n});
  return send(res,404,{error:'Not found'});
 }
 if(req.method!=='POST')return send(res,405,{error:'Method not allowed.'});
 if(req.headers.origin!==origin||!req.headers['content-type']?.startsWith('application/json'))return send(res,403,{error:'Origin or content type not allowed.'});
 try{
  const body=await jsonBody(req);
  if(path==='/password/register'){
   if(session)throw Error('Sign out before creating a different account.');
   if(body.consent!==true)throw Error('Confirm account storage and recovery before continuing.');
   if(typeof body.username!=='string'||!/^[a-zA-Z0-9][a-zA-Z0-9_-]{2,31}$/.test(body.username))throw Error('Use 3–32 letters, numbers, underscores or hyphens.');
   validatePassword(body.password);if(body.password!==body.repeat)throw Error('The passwords do not match.');
   abuseGuard?.(req,'signup');limit(store,'market-account-intake',120);
   if(store.db.prepare('SELECT id FROM market_accounts WHERE username=?').get(body.username))throw Error('That username is unavailable.');
   const password=await hashPassword(body.password),id=randomUUID(),sellerId=randomUUID(),sellerToken=randomBytes(32).toString('hex'),now=Date.now(),name=safeLabel(body.name,body.username);let codes;
   store.db.exec('BEGIN IMMEDIATE');try{
    store.db.prepare('INSERT INTO market_accounts VALUES(?,?,?,?,?,?)').run(id,body.username.toLowerCase(),name,randomBytes(32).toString('base64url'),sellerId,now);
    store.db.prepare('INSERT INTO market_sellers(id,created,key_hash,name) VALUES(?,?,?,?)').run(sellerId,now,keyDigest(sellerToken),name);
    grantAccountAccess(store,accountPrincipal(store,id),'seller',sellerId,keyDigest(sellerToken));
    store.db.prepare('INSERT INTO market_account_passwords VALUES(?,?,?,?)').run(id,password.salt,password.hash,now);
    codes=recoveryCodes(store,id,now);newAccountSession(store,res,id,body.remember===true,now);store.db.exec('COMMIT');
   }catch(e){store.db.exec('ROLLBACK');throw e;}
   return send(res,200,{created:true,recoveryCodes:codes});
  }
  if(path==='/password/login'){
   if(session){if(body.reauthenticate!==true)throw Error('You are already signed in. Sign out to switch accounts.');authorizeAccountMutation(store,req,origin);}
   abuseGuard?.(req,'password');limit(store,'market-password-logins',500);
   const username=typeof body.username==='string'?body.username.trim().slice(0,32):'';
   const account=store.db.prepare('SELECT id FROM market_accounts WHERE username=?').get(username);
   if(session&&account?.id!==session.account_id)throw Error('Sign in with the current account.');
   if(account)limit(store,'market-password-login:'+account.id,10);
   const row=account?store.db.prepare('SELECT * FROM market_account_passwords WHERE account_id=?').get(account.id):null;
   if(!await verifyPassword(body.password,row))throw Error('Username or password did not match. You can also use a passkey or recovery code.');
   // Recheck after asynchronous hashing so a concurrent password reset cannot create a session.
   const current=store.db.prepare('SELECT hash FROM market_account_passwords WHERE account_id=?').get(account.id);
   if(!current||current.hash!==row.hash)throw Error('Sign-in changed. Please try again.');
   if(session){const active=authorizeAccountMutation(store,req,origin);if(active.hash!==session.hash)throw Error('Sign-in changed. Please try again.');store.db.prepare('DELETE FROM market_account_sessions WHERE hash=?').run(session.hash);}
   newAccountSession(store,res,account.id,body.remember===true);return send(res,200,{signedIn:true});
  }
  if(path==='/register/options'){
   const adding=body.add===true;if(adding){authorizeAccountMutation(store,req,origin);fresh(session);if(store.db.prepare('SELECT count(*) n FROM market_passkeys WHERE account_id=?').get(session.account_id).n>=6)throw Error('Up to six passkeys are supported.');}
   else{if(session)throw Error('Sign out before creating a different account.');if(body.consent!==true)throw Error('Confirm account storage and recovery before continuing.');if(typeof body.username!=='string'||!/^[a-zA-Z0-9][a-zA-Z0-9_-]{2,31}$/.test(body.username))throw Error('Use 3–32 letters, numbers, underscores or hyphens.');if(store.db.prepare('SELECT id FROM market_accounts WHERE username=?').get(body.username))throw Error('That username is unavailable.');abuseGuard?.(req,'signup');limit(store,'market-account-intake',120);}
   const existing=adding?store.db.prepare('SELECT * FROM market_accounts WHERE id=?').get(session.account_id):null;
   const data={username:existing?.username||body.username.toLowerCase(),name:existing?.display_name||safeLabel(body.name,body.username),id:existing?.id||randomUUID(),userHandle:existing?.user_handle||randomBytes(32).toString('base64url'),remember:body.remember===true,label:safeLabel(body.label,'Passkey')};
   const options=await generateRegistrationOptions({rpName:'XBT Market',rpID:expected.hostname,userName:data.username,userDisplayName:data.name,userID:Buffer.from(data.userHandle,'base64url'),attestationType:'none',supportedAlgorithmIDs:[-7,-257],authenticatorSelection:{residentKey:'required',userVerification:'required'},excludeCredentials:adding?store.db.prepare('SELECT id FROM market_passkeys WHERE account_id=?').all(session.account_id):[]});
   saveFlow(store,res,adding?'add':'register',{...data,challenge:options.challenge},adding?session:null);return send(res,200,{options});
  }
  if(path==='/register/verify'){
   const adding=body.add===true;if(adding){authorizeAccountMutation(store,req,origin);fresh(session);}
   const saved=flow(store,req,adding?'add':'register',res),data=saved.data;
   if(adding&&(saved.account_id!==session.account_id||saved.session_hash!==session.hash))throw Error('Passkey request belongs to another session.');
   const verification=await verifyRegistrationResponse({response:body.response,expectedChallenge:data.challenge,expectedOrigin:origin,expectedRPID:expected.hostname,requireUserVerification:true,supportedAlgorithmIDs:[-7,-257]});if(!verification.verified)throw Error('Passkey could not be verified.');
   const info=verification.registrationInfo,key=info.credential,now=Date.now();let codes;
   if(adding){const active=accountSession(store,req,now);if(!active||active.hash!==session.hash||store.db.prepare('SELECT count(*) n FROM market_passkeys WHERE account_id=?').get(session.account_id).n>=6)throw Error('Account session changed. Sign in again before adding a passkey.');}
   store.db.exec('BEGIN IMMEDIATE');try{
    if(!adding){const sellerId=randomUUID(),sellerToken=randomBytes(32).toString('hex');store.db.prepare('INSERT INTO market_accounts VALUES(?,?,?,?,?,?)').run(data.id,data.username,data.name,data.userHandle,sellerId,now);store.db.prepare('INSERT INTO market_sellers(id,created,key_hash,name) VALUES(?,?,?,?)').run(sellerId,now,keyDigest(sellerToken),data.name);grantAccountAccess(store,accountPrincipal(store,data.id),'seller',sellerId,keyDigest(sellerToken));codes=recoveryCodes(store,data.id,now);}
    store.db.prepare('INSERT INTO market_passkeys VALUES(?,?,?,?,?,?,?,?,?)').run(key.id,data.id,Buffer.from(key.publicKey),key.counter,JSON.stringify(key.transports||[]),info.credentialDeviceType,info.credentialBackedUp?1:0,data.label,now);
    if(!adding)newAccountSession(store,res,data.id,data.remember,now);store.db.exec('COMMIT');
   }catch(error){store.db.exec('ROLLBACK');throw error;}
   return send(res,200,{created:!adding,passkeyAdded:true,...(codes?{recoveryCodes:codes}:{})});
  }
  if(path==='/login/options'){if(session&&body.reauthenticate!==true)throw Error('You are already signed in.');if(session)authorizeAccountMutation(store,req,origin);const allowCredentials=session?store.db.prepare('SELECT id,transports FROM market_passkeys WHERE account_id=?').all(session.account_id).map(k=>({id:k.id,transports:JSON.parse(k.transports)})):[];const options=await generateAuthenticationOptions({rpID:expected.hostname,allowCredentials,userVerification:'required'});saveFlow(store,res,'login',{challenge:options.challenge,remember:body.remember===true},session);return send(res,200,{options});}
  if(path==='/login/verify'){
   const saved=flow(store,req,'login',res),key=store.db.prepare('SELECT p.*,a.user_handle FROM market_passkeys p JOIN market_accounts a ON a.id=p.account_id WHERE p.id=?').get(body.response?.id);if(!key)throw Error('Passkey sign-in failed.');if(saved.session_hash&&(!session||session.hash!==saved.session_hash||key.account_id!==saved.account_id))throw Error('Sign-in account changed. Start again.');
   if(body.response.response?.userHandle&&body.response.response.userHandle!==key.user_handle)throw Error('Passkey sign-in failed.');
   const verification=await verifyAuthenticationResponse({response:body.response,expectedChallenge:saved.data.challenge,expectedOrigin:origin,expectedRPID:expected.hostname,requireUserVerification:true,credential:{id:key.id,publicKey:new Uint8Array(key.public_key),counter:key.counter,transports:JSON.parse(key.transports)}});if(!verification.verified)throw Error('Passkey sign-in failed.');
   const info=verification.authenticationInfo;store.db.exec('BEGIN IMMEDIATE');try{const changed=store.db.prepare('UPDATE market_passkeys SET counter=?,device_type=?,backed_up=? WHERE id=? AND counter=?').run(info.newCounter,info.credentialDeviceType,info.credentialBackedUp?1:0,key.id,key.counter);if(changed.changes!==1)throw Error('Passkey changed. Please sign in again.');if(saved.session_hash)store.db.prepare('DELETE FROM market_account_sessions WHERE hash=?').run(saved.session_hash);newAccountSession(store,res,key.account_id,saved.data.remember);store.db.exec('COMMIT');}catch(error){store.db.exec('ROLLBACK');throw error;}return send(res,200,{signedIn:true});
  }
  if(path==='/recover'){
   limit(store,'market-recovery-attempts',30);const code=typeof body.code==='string'?body.code.trim().toLowerCase().replaceAll('-',''):'';if(!/^[a-f0-9]{40}$/.test(code)||typeof body.username!=='string')throw Error('Recovery details unavailable.');
   const row=store.db.prepare('SELECT r.hash,r.account_id FROM market_recovery_codes r JOIN market_accounts a ON a.id=r.account_id WHERE r.hash=? AND a.username=?').get(keyDigest(code),body.username);if(!row)throw Error('Recovery details unavailable.');
   store.db.exec('BEGIN IMMEDIATE');try{const consumed=store.db.prepare('DELETE FROM market_recovery_codes WHERE hash=?').run(row.hash);if(consumed.changes!==1)throw Error('Recovery details unavailable.');store.db.prepare('DELETE FROM market_account_sessions WHERE account_id=?').run(row.account_id);store.db.prepare('DELETE FROM market_account_passwords WHERE account_id=?').run(row.account_id);newAccountSession(store,res,row.account_id,false);store.db.exec('COMMIT');}catch(error){store.db.exec('ROLLBACK');throw error;}return send(res,200,{recovered:true});
  }
  const current=authorizeAccountMutation(store,req,origin);
  if(path==='/password/set'){
   fresh(current);limit(store,'market-password-change:'+current.account_id,10);validatePassword(body.password);if(body.password!==body.repeat)throw Error('The passwords do not match.');
   const password=await hashPassword(body.password),active=authorizeAccountMutation(store,req,origin);fresh(active);
   store.db.exec('BEGIN IMMEDIATE');try{
    store.db.prepare('INSERT INTO market_account_passwords VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET salt=excluded.salt,hash=excluded.hash,updated=excluded.updated').run(active.account_id,password.salt,password.hash,Date.now());
    store.db.prepare('DELETE FROM market_account_sessions WHERE account_id=? AND hash<>?').run(active.account_id,active.hash);store.db.exec('COMMIT');
   }catch(e){store.db.exec('ROLLBACK');throw e;}
   return send(res,200,{passwordEnabled:true});
  }
  if(path==='/password/remove'){
   fresh(current);if(!store.db.prepare('SELECT 1 FROM market_passkeys WHERE account_id=?').get(current.account_id))throw Error('Add a passkey before removing password sign-in.');
   store.db.prepare('DELETE FROM market_account_passwords WHERE account_id=?').run(current.account_id);store.db.prepare('DELETE FROM market_account_sessions WHERE account_id=? AND hash<>?').run(current.account_id,current.hash);return send(res,200,{passwordEnabled:false});
  }
  if(path==='/saved'){limit(store,'market-save:'+current.account_id,120);return send(res,200,setSavedItem(store,current.actor,body.id,body.saved));}
  if(path==='/logout'){store.db.prepare('DELETE FROM market_account_sessions WHERE hash=?').run(current.hash);setCookie(res,SESSION,'',0);return send(res,200,{signedOut:true});}
  if(path==='/logout-all'){fresh(current);store.db.prepare('DELETE FROM market_account_sessions WHERE account_id=?').run(current.account_id);setCookie(res,SESSION,'',0);return send(res,200,{signedOut:true});}
  if(path==='/names'){fresh(current);limit(store,'market-name-change:'+current.account_id,10);return send(res,200,updateAccountNames(store,current.actor,body));}
  if(path==='/claim')return send(res,200,claimAccountRecord(store,current.actor,body));
  if(path==='/recovery-codes'){fresh(current);store.db.exec('BEGIN IMMEDIATE');try{const codes=recoveryCodes(store,current.account_id);store.db.exec('COMMIT');return send(res,200,{recoveryCodes:codes});}catch(error){store.db.exec('ROLLBACK');throw error;}}
  if(path==='/passkey/remove'){fresh(current);if(store.db.prepare('SELECT count(*) n FROM market_passkeys WHERE account_id=?').get(current.account_id).n<=1)throw Error('Keep at least one passkey. Add another before removing this one.');store.db.exec('BEGIN IMMEDIATE');try{const removed=store.db.prepare('DELETE FROM market_passkeys WHERE account_id=? AND id=?').run(current.account_id,body.id);if(removed.changes!==1)throw Error('Passkey unavailable.');store.db.prepare('DELETE FROM market_account_sessions WHERE account_id=? AND hash<>?').run(current.account_id,current.hash);store.db.exec('COMMIT');}catch(error){store.db.exec('ROLLBACK');throw error;}return send(res,200,{removed:true});}
  return send(res,404,{error:'Not found'});
 }catch(error){return send(res,error.status||400,{error:error.message?.includes('UNIQUE constraint')?'That account or passkey is already connected. Start again or sign in.':error.message||'Unable to complete account request.'});}
}
export function pruneAccounts(store,now=Date.now()){
 store.db.prepare('DELETE FROM market_account_flows WHERE expires<=?').run(now);store.db.prepare('DELETE FROM market_account_sessions WHERE expires<=? OR last_seen<=?').run(now,now-7*day);
 for(const [kind,table] of [['seller','market_sellers'],['order','market_orders'],['chat','market_conversations']])store.db.prepare('DELETE FROM market_account_access WHERE kind=? AND resource_id NOT IN (SELECT id FROM '+table+')').run(kind);
 store.db.exec("DELETE FROM market_account_access WHERE kind='listing' AND resource_id NOT IN (SELECT id FROM market_listings) AND NOT EXISTS(SELECT 1 FROM market_conversations c WHERE c.listing_id=market_account_access.resource_id AND c.owner_hash=market_account_access.proof_hash)");
}
