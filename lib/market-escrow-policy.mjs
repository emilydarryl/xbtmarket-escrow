// Persistent launch policy. Never changes an existing order's payment agreement.
const need=(ok,message)=>{if(!ok)throw Error(message);};
const key='market-shipping-escrow-policy-v1';
export function xbtLimitSats(value){
 need(typeof value==='string'&&/^(0|[1-9][0-9]{0,7})(\.[0-9]{1,8})?$/.test(value),'Enter an exact positive XBT amount with up to eight decimal places.');
 const [whole,part='']=value.split('.'),sats=BigInt(whole)*100000000n+BigInt(part.padEnd(8,'0'));
 need(sats>0n&&sats<=2100000000000000n,'Invalid XBT limit.');return sats.toString();
}
export const formatXbt=sats=>{const n=BigInt(sats);return `${n/100000000n}.${String(n%100000000n).padStart(8,'0')}`;};
function validate(p){
 need(p&&p.schema===key&&Number.isSafeInteger(p.revision)&&p.revision>0&&Number.isSafeInteger(p.requiredFrom)&&p.requiredFrom>0&&typeof p.newDepositsPaused==='boolean','Escrow policy unavailable.');
 for(const k of ['maximumDepositSats','maximumBuyerSats','maximumMarketSats'])need(typeof p[k]==='string'&&/^[1-9][0-9]{0,15}$/.test(p[k])&&BigInt(p[k])<=2100000000000000n,'Invalid stored escrow limit.');
 need(BigInt(p.maximumDepositSats)<=BigInt(p.maximumBuyerSats)&&BigInt(p.maximumBuyerSats)<=BigInt(p.maximumMarketSats),'Limits must increase from order to buyer to marketplace.');return p;
}
export function shippingEscrowPolicy(store){const p=store.get(key);return p==null?null:validate(p);}
// Operator-only bootstrap; admin adjustments cannot erase the mandatory cutoff.
export function initializeShippingEscrowPolicy(store,{requiredFrom,maximumDepositXbt,maximumBuyerXbt,maximumMarketXbt},now=Date.now()){
 need(!shippingEscrowPolicy(store),'Escrow policy already initialized.');
 const p=validate({schema:key,revision:1,requiredFrom,newDepositsPaused:true,maximumDepositSats:xbtLimitSats(maximumDepositXbt),maximumBuyerSats:xbtLimitSats(maximumBuyerXbt),maximumMarketSats:xbtLimitSats(maximumMarketXbt),updatedAt:now});
 store.set(key,p);return p;
}
export function updateShippingEscrowPolicy(store,b,now=Date.now()){
 need(b&&Object.keys(b).sort().join()==='confirm,expectedRevision,maximumBuyerXbt,maximumDepositXbt,maximumMarketXbt,newDepositsPaused'&&b.confirm===true&&typeof b.newDepositsPaused==='boolean','Confirm the exact escrow settings.');
 store.db.exec('BEGIN IMMEDIATE');try{
  const old=shippingEscrowPolicy(store);need(old&&b.expectedRevision===old.revision,'Settings changed. Refresh before saving.');
  const p=validate({...old,revision:old.revision+1,newDepositsPaused:b.newDepositsPaused,maximumDepositSats:xbtLimitSats(b.maximumDepositXbt),maximumBuyerSats:xbtLimitSats(b.maximumBuyerXbt),maximumMarketSats:xbtLimitSats(b.maximumMarketXbt),updatedAt:now});
  store.set(key,p);store.db.exec('COMMIT');return p;
 }catch(e){store.db.exec('ROLLBACK');throw e;}
}
export function requiredShippingEscrow(store,order){const p=shippingEscrowPolicy(store);return order.escrowRequired===true||!!(p&&order.delivery==='shipping'&&order.created>=p.requiredFrom);}
export function rolloutTrialPolicy(store,fallback){const p=shippingEscrowPolicy(store);return p?{scope:'all-shipping-orders-v1',createdAfter:p.requiredFrom-1,maximumDepositSats:p.maximumDepositSats}:fallback;}
