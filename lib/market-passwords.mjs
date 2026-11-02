import {scrypt as derive,randomBytes,timingSafeEqual} from 'node:crypto';
import {promisify} from 'node:util';
const scrypt=promisify(derive);let running=0;
export function validatePassword(password){if(typeof password!=='string'||password.length<14||password.length>128)throw Error('Use a unique password between 14 and 128 characters. A long passphrase works well.');}
async function key(password,salt){if(running>=2){const e=Error('Sign-in is busy. Please try again in a moment.');e.status=429;throw e;}running++;try{return await scrypt(password,salt,32,{N:32768,r:8,p:3,maxmem:64*1024*1024});}finally{running--;}}
export async function hashPassword(password){validatePassword(password);const salt=randomBytes(16).toString('hex');return {salt,hash:(await key(password,salt)).toString('hex')};}
export async function verifyPassword(password,row){const value=typeof password==='string'&&password.length<=128?password:'';const calculated=await key(value,row?.salt||'0'.repeat(32));return !!row&&timingSafeEqual(calculated,Buffer.from(row.hash,'hex'));}
