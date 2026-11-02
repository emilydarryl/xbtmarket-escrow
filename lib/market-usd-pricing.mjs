// Dollar denomination only. All payment and refund accounting remains in XBT/sats.
// The caller must persist returned quotes and supply only server-owned quotes to validateUsdQuote.
import {createHash} from 'node:crypto';
const fail=message=>{throw Error(message);};
const decimal=(value,places,maxWhole,label)=>{
 if(typeof value!=='string'||!new RegExp('^(0|[1-9][0-9]{0,'+(maxWhole-1)+'})(\\.[0-9]{1,'+places+'})?$').test(value))fail('Enter a valid '+label+'.');
 const [whole,fraction='']=value.split('.');return BigInt(whole)*10n**BigInt(places)+BigInt(fraction.padEnd(places,'0'));
};
const formatted=(n,places)=>{const scale=10n**BigInt(places);return (n/scale)+'.'+(n%scale).toString().padStart(places,'0');};
export function usdCents(value){const n=decimal(value,2,8,'USD amount with at most two decimals');if(n<=0n)fail('USD price must be positive.');return n;}
export function xbtSats(value){return decimal(value,8,10,'XBT amount with at most eight decimals');}
export const satsXbt=value=>formatted(BigInt(value),8);
export function usdListingPrice(value){return formatted(usdCents(value),2);}

export function checkoutUsdcReference(data,now=Date.now()){
 const rows=data?.rows;
 if(!Array.isArray(rows))fail('A fresh XBT/USDC reference is unavailable.');
 const matches=rows.filter(r=>r.id==='neoxex');
 if(matches.length!==1)fail('A unique XBT/USDC reference is required.');
 const r=matches[0];
 if(r.pair!=='BTCB2_USDC'||r.quote!=='USDC'||r.stale!==false||r.unavailable!==false||!Number.isSafeInteger(r.fetchedAt)||!Number.isSafeInteger(r.sourceTime)||r.fetchedAt>now||r.sourceTime>now||now-r.fetchedAt>120000||now-r.sourceTime>300000)fail('The XBT/USDC reference is stale or unavailable. Refresh before continuing.');
 // Decimal parsing is exact; floating point is not used for the amount conversion.
 const rate=String(r.price), scaled=decimal(rate,8,10,'XBT/USDC reference');
 if(scaled<=0n)fail('Invalid XBT/USDC reference.');
 return {source:'neoxex',pair:'BTCB2_USDC',quote:'USDC',price:formatted(scaled,8),fetchedAt:r.fetchedAt,sourceTime:r.sourceTime,assumption:'1 USDC ≈ US$1'};
}
export function usdToSats(usd,rate){
 const cents=usdCents(usd),scaled=decimal(rate,8,10,'XBT/USDC reference');
 if(scaled<=0n)fail('Invalid XBT/USDC reference.');
 const numerator=cents*100000000000000n; // cents / 100 / rate * 1e8 sats
 const sats=(numerator+scaled-1n)/scaled;
 if(sats<=0n||sats>999999999999999999n)fail('Converted amount is outside the supported XBT range.');
 return sats;
}
const digest=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
export function createUsdQuote({listingId,listingUpdated,priceUsd,shippingXbt='0',shippingUsd=null,shippingAgreement=null,buyerId},data,now=Date.now()){
 if(typeof listingId!=='string'||!listingId||!Number.isSafeInteger(listingUpdated)||listingUpdated>now||typeof buyerId!=='string'||!buyerId||!Number.isSafeInteger(now))fail('A current listing and buyer are required.');
 const reference=checkoutUsdcReference(data,now),usd=usdListingPrice(priceUsd),itemSats=usdToSats(usd,reference.price),shippingSats=shippingUsd===null?xbtSats(shippingXbt):usdToSats(shippingUsd,reference.price),total=itemSats+shippingSats;
 if(total>999999999999999999n)fail('Order total is outside the supported XBT range.');
 const terms={schema:'xbt-usd-price-quote-v1',listingId,listingUpdated,buyerId,priceUsd:usd,reference,itemSats:String(itemSats),shippingSats:String(shippingSats),totalSats:String(total),totalXbt:satsXbt(total),rounding:'up-to-whole-sat',issuedAt:now,expiresAt:now+15*60000};
 if(shippingUsd!==null){if(xbtSats(shippingXbt)!==0n)fail('Choose one shipping currency.');terms.shippingUsd=usdListingPrice(shippingUsd);}
 if(shippingAgreement)terms.shippingAgreement=structuredClone(shippingAgreement);
 return {...terms,quoteHash:digest(terms)};
}
export function validateUsdQuote(saved,{listingId,listingUpdated,buyerId,totalXbt,quoteHash},now=Date.now()){
 if(!saved||saved.schema!=='xbt-usd-price-quote-v1')fail('Request a new dollar-price quote.');
 const {quoteHash:hash,...terms}=saved;
 if(hash!==digest(terms)||quoteHash!==hash)fail('The dollar-price quote changed.');
 if(!Number.isSafeInteger(now)||now<saved.issuedAt||now>=saved.expiresAt||saved.expiresAt!==saved.issuedAt+900000)fail('The dollar-price quote expired. Request and review a new quote.');
 if(saved.listingId!==listingId||saved.listingUpdated!==listingUpdated||saved.buyerId!==buyerId||saved.totalXbt!==totalXbt)fail('The quote does not match this buyer, listing or total.');
 // This returns an immutable accounting snapshot, never a recalculated market amount.
 return structuredClone(saved);
}
