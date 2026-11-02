import {createECDH,createPrivateKey,sign} from 'node:crypto';
import {productionContractMessage} from '../../lib/market-escrow-contract.mjs';
// Public fixture keys only; never imported by application code.
export function syntheticProductionProof(challenge,scalar,{highS=false,wrongDomain=false,message=productionContractMessage,schema='xbt-production-contract-proof-v1'}={}){
 const secret=Buffer.from(BigInt(scalar).toString(16).padStart(64,'0'),'hex');const e=createECDH('secp256k1');e.setPrivateKey(secret);const point=e.getPublicKey(undefined,'uncompressed');
 const key=createPrivateKey({format:'jwk',key:{kty:'EC',crv:'secp256k1',x:point.subarray(1,33).toString('base64url'),y:point.subarray(33).toString('base64url'),d:secret.toString('base64url')}});
 const raw=sign('sha256',wrongDomain?Buffer.from(JSON.stringify(challenge)):message(challenge),{key,dsaEncoding:'ieee-p1363'}),n=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n,s=BigInt('0x'+raw.subarray(32).toString('hex')),low=s>n/2n?n-s:s;
 const int=v=>{let h=v.toString(16);if(h.length%2)h='0'+h;let b=Buffer.from(h,'hex');if(b[0]&128)b=Buffer.concat([Buffer.from([0]),b]);return Buffer.concat([Buffer.from([2,b.length]),b]);};
 const body=Buffer.concat([int(BigInt('0x'+raw.subarray(0,32).toString('hex'))),int(highS?n-low:low)]);return {schema,challenge,signature:Buffer.concat([Buffer.from([48,body.length]),body]).toString('base64')};
}
