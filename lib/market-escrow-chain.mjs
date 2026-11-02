// Read-only XBT observations. No wallet, address generation or broadcast methods.
// Checkpoint matches the repository's existing lib/source.mjs source policy.
export const XBT_CHAIN_PROFILE=Object.freeze({network:'main',genesis:'000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',checkpointHeight:961640,checkpointHash:'0000000000000050c1e5f69672f459293be14f46e5a494e7a8c8541396f18eeb'});
const need=(v,m)=>{if(!v)throw Error(m);};
const hash=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
export function createEscrowChainObserver(rpc,{minimumConfirmations=3,maximumTipAgeSeconds=7200,now=()=>Date.now()}={}){
 need(typeof rpc==='function'&&Number.isInteger(minimumConfirmations)&&minimumConfirmations>=3&&Number.isInteger(maximumTipAgeSeconds)&&maximumTipAgeSeconds>=60&&maximumTipAgeSeconds<=86400,'Explicit bounded observation policy required.');
 async function chain(){
  const info=await rpc('getblockchaininfo',[]),p=XBT_CHAIN_PROFILE;
  need(info?.chain===p.network&&info.initialblockdownload===false&&Number.isSafeInteger(info.blocks)&&info.blocks>=p.checkpointHeight&&info.headers===info.blocks&&hash(info.bestblockhash),'A synced main chain tip is required.');
  need(await rpc('getblockhash',[0])===p.genesis&&await rpc('getblockhash',[p.checkpointHeight])===p.checkpointHash,'XBT chain checkpoint mismatch.');
  const header=await rpc('getblockheader',[info.bestblockhash,true]);
  const seconds=Math.floor(now()/1000);
  need(header?.hash===info.bestblockhash&&header.height===info.blocks&&header.confirmations===1&&Number.isSafeInteger(header.time)&&header.time<=seconds+600&&seconds-header.time<=maximumTipAgeSeconds,'Chain tip is stale or inconsistent.');
  return info;
 }
 async function observe(pin){
  pin=structuredClone(pin);
  need(pin&&hash(pin.txid)&&Number.isSafeInteger(pin.vout)&&pin.vout>=0&&pin.vout<=0xffffffff&&hash(pin.fundingBlockHash)&&/^(0|[1-9][0-9]{0,15})$/.test(pin.valueSats)&&typeof pin.scriptPubKey==='string'&&/^0020[a-f0-9]{64}$/.test(pin.scriptPubKey),'Exact P2WSH funding pin required.');
  const tip=await chain(),out=await rpc('gettxout',[pin.txid,pin.vout,true]);
  need(BigInt(pin.valueSats)>0n,'Positive escrow funding amount required.');
  let result={status:'missing',unspent:false,observationOnly:true,fundingEnabled:false};
  if(out!==null){
   need(out&&out.bestblock===tip.bestblockhash&&Number.isSafeInteger(out.confirmations)&&out.confirmations>=minimumConfirmations&&out.confirmations<=tip.blocks+1&&typeof out.coinbase==='boolean','Funding confirmations or tip mismatch.');
   need(!out.coinbase||out.confirmations>=101,'Coinbase funding is immature.');
   need(typeof out.value==='number'&&Number.isFinite(out.value)&&out.value>=0&&out.value<=21000000&&Number(out.value.toFixed(8))===out.value,'Invalid exact output amount.');
   const value=BigInt(out.value.toFixed(8).replace('.',''));need(value.toString()===pin.valueSats&&out.scriptPubKey?.hex===pin.scriptPubKey,'Funding amount or script mismatch.');
   need(await rpc('getblockhash',[tip.blocks-out.confirmations+1])===pin.fundingBlockHash,'Funding block is no longer pinned to the active chain.');
   result={...result,status:'verified_unspent',unspent:true,confirmations:out.confirmations,valueSats:pin.valueSats};
  }
  const after=await rpc('getblockchaininfo',[]);need(after?.bestblockhash===tip.bestblockhash&&after.blocks===tip.blocks&&after.chain==='main'&&after.initialblockdownload===false,'Chain changed during observation; retry.');
  return {...result,chainProfile:XBT_CHAIN_PROFILE,bestBlockHash:tip.bestblockhash,checkedAt:new Date(now()).toISOString()};
 }
 return {observe,verifyChain:chain};
}
