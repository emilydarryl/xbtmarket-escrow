import {createHash,timingSafeEqual} from 'node:crypto';
import {authorizedCapability} from './market-identity.mjs';
export const PHOTO_LIMIT=3,PHOTO_BYTES=300*1024;
export const PHOTO_STORAGE_BYTES=128*1024*1024;
const invalid=()=>{throw Error('Use up to three JPEG photos, each at most 300 KB and 1600 pixels per side.');};
// Server strips APP/COM metadata, including EXIF/GPS, even if the browser's
// re-encoding is bypassed. Parse progressive scan boundaries; reject trailers.
export function cleanPhoto(value){
  if(typeof value!=='string'||value.length>PHOTO_BYTES*4/3+30||!/^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/.test(value))invalid();
  const encoded=value.slice(23),bytes=Buffer.from(encoded,'base64');
  if(bytes.toString('base64')!==encoded||bytes.length>PHOTO_BYTES||bytes[0]!==255||bytes[1]!==216)invalid();
  const parts=[bytes.subarray(0,2)];let offset=2,width=0,height=0,scans=0,ended=false;
  while(offset<bytes.length){
    const start=offset;if(bytes[offset++]!==255)invalid();while(bytes[offset]===255)offset++;const marker=bytes[offset++];
    if(marker===217){if(offset!==bytes.length)invalid();parts.push(Buffer.from([255,217]));ended=true;break;}
    if(![192,194,196,219,218,221,254].includes(marker)&&!(marker>=224&&marker<=239))invalid();
    if(offset+2>bytes.length)invalid();const length=bytes.readUInt16BE(offset),end=offset+length;if(length<2||end>bytes.length)invalid();
    if(marker===192||marker===194){
      if(width||length<11||bytes[offset+2]!==8)invalid();height=bytes.readUInt16BE(offset+3);width=bytes.readUInt16BE(offset+5);
      const components=bytes[offset+7];if(![1,3].includes(components)||length!==8+3*components||!width||!height||width>1600||height>1600)invalid();
    }
    if(!(marker>=224&&marker<=239)&&marker!==254)parts.push(bytes.subarray(start,end));offset=end;
    if(marker===218){
      if(!width||length<6)invalid();scans++;const scanStart=offset;
      while(offset<bytes.length){if(bytes[offset]!==255){offset++;continue;}const next=bytes[offset+1];if(next===0||(next>=208&&next<=215)){offset+=2;continue;}if(next===255){offset++;continue;}break;}
      if(offset===scanStart)invalid();parts.push(bytes.subarray(scanStart,offset));
    }
  }
  if(!ended||!width||!scans)invalid();const data=Buffer.concat(parts);
  return {data,width,height,hash:createHash('sha256').update(data).digest('hex')};
}
export function listingPhotos(input,id){if(input===undefined)return [];if(!Array.isArray(input)||input.length>PHOTO_LIMIT)invalid();return input.map((value,index)=>({...cleanPhoto(value),url:'/api/market/photos/'+id+'/'+index}));}
export function photoAccess(store,id,index,{token=null,admin=false}={},now=Date.now()){
  if(!/^[a-f0-9-]{36}$/.test(id)||!Number.isInteger(index)||index<0||index>=PHOTO_LIMIT)return null;
  const listing=store.db.prepare('SELECT status,expires,token_hash FROM market_listings WHERE id=?').get(id);if(!listing)return null;
  const owner=authorizedCapability(store,token,'listing',id,listing.token_hash);
  if(!(listing.status==='published'&&listing.expires>now)&&!owner&&!admin)return null;
  return store.db.prepare('SELECT bytes FROM market_listing_photos WHERE listing_id=? AND position=?').get(id,index)?.bytes||null;
}
