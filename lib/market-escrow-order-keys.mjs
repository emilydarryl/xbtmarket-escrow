// Public-only pay-to-contract derivation. Never accepts or stores private keys.
import {secp256k1} from '@noble/curves/secp256k1.js';
import {escrowDraftHash as hash} from './market-escrow-economics.mjs';
export const ORDER_KEY_N=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
export function productionOrderTweak(c,role){
 if(!['buyer','seller','market'].includes(role))throw Error('Unknown order key role.');
 const t=BigInt('0x'+hash({domain:'xbt-production-order-key-v3',chainProfile:c.chainProfile,origin:c.origin,orderId:c.preflight.orderId,revision:c.revision,preflightHash:c.preflight.preflightHash,keys:c.keys,role}));
 if(t===0n||t>=ORDER_KEY_N)throw Error('Invalid order tweak; a new review revision is required.');
 return t;
}
export function productionOrderKeys(c){
 const keys=Object.fromEntries(['buyer','seller','market'].map(role=>{
  const point=secp256k1.Point.fromHex(c.keys[role]).add(secp256k1.Point.BASE.multiply(productionOrderTweak(c,role)));
  if(point.equals(secp256k1.Point.ZERO))throw Error('Invalid order key; a new review revision is required.');
  return [role,point.toHex(true)];
 }));
 if(new Set(Object.values(keys)).size!==3)throw Error('Distinct order keys required.');
 return keys;
}
