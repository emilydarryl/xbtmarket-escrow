import {readFileSync} from 'node:fs';
import {validateProductionContract} from '../lib/market-escrow-contract.mjs';
export function verifyOutput(contract,scriptPubKey){
 validateProductionContract(contract);
 if(!/^[a-f0-9]{68}$/.test(scriptPubKey)||scriptPubKey!==contract.scriptPubKey)throw Error('Funding output does not match the reviewed contract.');
 return {matches:true,threshold:2,participants:3,type:'P2WSH',contractHash:contract.contractHash,chainChecked:false,confirmationsChecked:false,unspentChecked:false};
}
if(process.argv[1]?.endsWith('verify-contract.mjs')){
 try{
  const [path,script,...extra]=process.argv.slice(2);
  if(!path||!script||extra.length)throw Error('Usage: node tools/verify-contract.mjs contract.json SCRIPT_PUB_KEY_HEX');
  const content=readFileSync(path,'utf8');if(content.length>100000)throw Error('Contract file too large.');
  const data=JSON.parse(content);console.log(JSON.stringify(verifyOutput(data.contract||data,script),null,2));
 }catch(e){console.error(e.message);process.exitCode=1;}
}
