import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const source=JSON.parse(readFileSync(new URL('../SOURCE-MANIFEST.json',import.meta.url),'utf8'));
for(const f of source.files){const actual=createHash('sha256').update(readFileSync(new URL('../'+f.path,import.meta.url))).digest('hex');if(actual!==f.sha256)throw Error('Source hash mismatch: '+f.path);}
console.log(JSON.stringify({passed:true,sourceFiles:source.files.length}));
