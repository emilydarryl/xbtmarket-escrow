import {randomUUID,createECDH,createHash} from 'node:crypto';
import {existsSync} from 'node:fs';
import {Store} from '../../lib/store.mjs';
import {initializeMarketplace,submitListing,moderateListing} from '../../lib/marketplace.mjs';
import {initializeAccounts} from '../../lib/market-accounts.mjs';
import {accountPrincipal,grantAccountAccess} from '../../lib/market-identity.mjs';
import {createSeller,createOrder} from '../../lib/market-trades.mjs';
import {createEscrowSetup} from '../../lib/market-escrow-setup.mjs';
const tokens={buyer:'aa'.repeat(32),seller:'bb'.repeat(32),listing:'cc'.repeat(32),other:'dd'.repeat(32)};
const hash=x=>createHash('sha256').update(x).digest('hex');
const pub=n=>{const key=createECDH('secp256k1');key.setPrivateKey(Buffer.concat([Buffer.alloc(31),Buffer.from([n])]));return key.getPublicKey('hex','compressed');};
const keys={buyer:pub(11),seller:pub(22),market:pub(33)}; // Public fixtures, not user wallets.
function seed(path=':memory:',{origin='http://127.0.0.1:4367',mediatorPublicKey=keys.market}={}){
 if(path!==':memory:'&&existsSync(path))throw Error('Only a new synthetic account/order test database is accepted.');
 const store=new Store(path);initializeMarketplace(store);initializeAccounts(store);
 const sellerId=randomUUID(),listingId=randomUUID(),id=randomUUID(),accounts={};
 for(const role of ['buyer','seller','other']){const accountId=randomUUID();store.db.prepare('INSERT INTO market_accounts VALUES(?,?,?,?,?,?)').run(accountId,role+'_setup',role,randomUUID(),role==='seller'?sellerId:null,Date.now());accounts[role]=accountId;}
 createSeller(store,{id:sellerId,name:'Escrow fixture seller',consent:true},tokens.seller);
 const actors=Object.fromEntries(Object.entries(accounts).map(([role,id])=>[role,accountPrincipal(store,id)]));
 grantAccountAccess(store,actors.seller,'seller',sellerId,hash(tokens.seller));
 submitListing(store,{id:listingId,profileId:sellerId,title:'Tracked shipping fixture',description:'An accurate synthetic item for escrow account-binding checks.',seller:'Fixture seller',contact:'seller-private@example.test',category:'electronics',price:'5',region:'United States',delivery:'shipping',consent:true},tokens.listing,Date.now(),tokens.seller);
 moderateListing(store,listingId,'publish');
 const request={id,listingId,buyer:'Fixture buyer',contact:'buyer-private@example.test',destinationCountry:'United States',terms:'One synthetic item including tracked shipping and an agreed inspection period.',total:'5.00000000',consent:true};
 createOrder(store,request,tokens.buyer,Date.now(),true,actors.buyer);
 const plan=createEscrowSetup(store,{enabled:true,origin,mediatorPublicKey});
 return {store,sellerId,id,listingId,accounts,actors,plan,request};
}
export {seed as escrowBindingFixture,tokens,keys,pub,hash};
