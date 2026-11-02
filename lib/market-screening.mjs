import {readFileSync} from 'node:fs';
const policy=JSON.parse(readFileSync(new URL('../config/market-review-rules.json',import.meta.url),'utf8'));
function normalize(value){return String(value??'').normalize('NFKC').toLowerCase().replace(/[\p{Cf}\p{M}]/gu,'').replace(/[^\p{L}\p{N}]+/gu,' ').trim();}
if(!Number.isSafeInteger(policy.version)||!Array.isArray(policy.rules)||!policy.rules.length)throw Error('Invalid listing review policy.');
const rules=policy.rules.map(rule=>{
 if(typeof rule.label!=='string'||!Array.isArray(rule.terms)||!rule.terms.length)throw Error('Invalid listing review rule.');
 return {label:rule.label,terms:rule.terms.map(term=>{if(typeof term!=='string'||!normalize(term))throw Error('Invalid listing review term.');return normalize(term);})};
});
export function screenListing(body){
 // This is a text triage rule, not image analysis or a guarantee of compliance.
 const text=' '+normalize(['title','description','seller','contact','region','deliveryArea'].map(key=>body[key]||'').concat(Object.values(body.shipping||{})).join(' '))+' ';
 const reasons=rules.filter(rule=>rule.terms.some(term=>text.includes(' '+term+' ')||text.includes(' '+term+'s ')||text.includes(' '+term+'es '))).map(rule=>rule.label);
 return {version:policy.version,status:reasons.length?'pending':'published',reasons};
}
