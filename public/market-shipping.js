const clean=(value,max,label)=>{if(typeof value!=='string'||value.trim().length>max||/[\x00-\x1f\x7f]/.test(value))throw Error('Check '+label+'.');return value.trim();};
export function shippingPolicy(value){
 if(value===undefined)return undefined;
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(key=>!['cost','fee','feeCurrency','dispatch','estimate','returns'].includes(key)))throw Error('Check the shipping options.');
 if(!['quote','free','fixed'].includes(value.cost))throw Error('Choose how shipping is charged.');
 const policy={cost:value.cost};
 if(value.cost==='fixed'){
  const currency=value.feeCurrency||'XBT';if(!['XBT','USD'].includes(currency))throw Error('Choose XBT or USD shipping.');
  const fee=clean(value.fee,24,'shipping charge').replace(/^\./,'0.');
  if(currency==='USD'){if(!/^(0|[1-9]\d{0,7})(\.\d{1,2})?$/.test(fee)||!/[1-9]/.test(fee))throw Error('Enter a positive USD shipping charge with up to two decimals.');policy.feeCurrency='USD';policy.fee=fee;}else{
  if(!/^(0|[1-9]\d{0,9})(\.\d{1,8})?$/.test(fee)||!/[1-9]/.test(fee))throw Error('Enter a positive shipping charge in XBT with up to eight decimals.');policy.fee=fee;}
 }
 for(const [key,max] of [['dispatch',120],['estimate',120],['returns',600]]){const text=clean(value[key]??'',max,'shipping '+key);if(text)policy[key]=text;}
 return policy;
}
export function destinationCountry(value){const country=clean(value??'',80,'destination country');if(country.length<2||!/[\p{L}]/u.test(country)||/[^\p{L}\p{M} .,'’()\-]/u.test(country))throw Error('Enter the destination country only, without a street address or postcode.');return country;}
export function shippingTotal(price,policy){
 if(policy?.feeCurrency==='USD')throw Error('Request a current USD checkout quote.');
 if(!policy||policy.cost==='quote')return price;
 const sats=value=>{if(!/^(0|[1-9]\d{0,9})(\.\d{1,8})?$/.test(value))throw Error('Check the XBT amount.');const [whole,part='']=value.split('.');return BigInt(whole)*100000000n+BigInt(part.padEnd(8,'0'));};
 const total=sats(price)+(policy.cost==='fixed'?sats(policy.fee):0n);return (total/100000000n)+'.'+(total%100000000n).toString().padStart(8,'0');
}
export function shippingLines(item){
 if(item.delivery!=='shipping')return [];
 const policy=item.shipping;
 return ['Ships to: '+(item.deliveryArea||'Ask the seller about your country'),!policy||policy.cost==='quote'?'Shipping charge: ask the seller before agreeing the total':policy.cost==='free'?'Shipping included in the listed price':'Shipping charge: '+policy.fee+' '+(policy.feeCurrency||'XBT')+' per order (added to the listed price)','Dispatch: '+(policy?.dispatch||'Agree with seller'),'Estimated delivery: '+(policy?.estimate||'Agree with seller'),'Returns: '+(policy?.returns||'Agree return and refund terms before paying')];
}
const el=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
export function shippingFields(form){
 const group=el('fieldset'),legend=el('legend','Shipping options'),label=el('label','Shipping charge'),select=el('select');select.name='shippingCost';
 for(const [value,text] of [['quote','Quote before payment'],['free','Included in listed price'],['fixed','Fixed charge per order']]){const option=el('option',text);option.value=value;select.append(option);}label.append(select);group.append(legend,label);
 const currencyLabel=el('label','Shipping price currency'),currency=el('select');currency.name='shippingFeeCurrency';for(const v of ['XBT','USD']){const o=el('option',v);o.value=v;currency.append(o);}currencyLabel.append(currency);group.append(currencyLabel);
 const updateCurrency=()=>{currencyLabel.hidden=select.value!=='fixed';const usd=form.elements.priceCurrency?.value==='USD';currency.options[1].disabled=!usd;if(!usd&&currency.value==='USD'){currency.value='XBT';if(form.elements.shippingFee)form.elements.shippingFee.value='';}const label=form.elements.shippingFee?.closest('label');if(label)label.firstChild.textContent='Shipping charge in '+currency.value;};currency.addEventListener('change',updateCurrency);form.addEventListener('change',e=>{if(e.target.name==='priceCurrency')updateCurrency();});
 for(const [name,text,max] of [['shippingFee','Shipping charge in XBT',24],['shippingDispatch','Dispatch timeframe (optional)',120],['shippingEstimate','Estimated delivery time (optional)',120],['shippingReturns','Return / refund terms (optional)',600]]){
  const label=el('label',text),input=el(name==='shippingReturns'?'textarea':'input');input.name=name;input.maxLength=max;if(name==='shippingFee')input.inputMode='decimal';label.append(input);group.append(label);
 }
 group.append(el('p','Use tracked shipping: a carrier and tracking number are required when marking an order shipped. Charges are per order. Confirm destination, delivery costs and return terms before accepting payment. Exchange exact addresses privately outside this site. Estimates are supplied by the seller.'));
 select.addEventListener('change',()=>{updateCurrency();form.elements.shippingFee.closest('label').hidden=select.value!=='fixed';form.elements.shippingFee.required=!group.hidden&&select.value==='fixed';});
 return {node:group,load(policy,visible){group.hidden=!visible;for(const input of group.querySelectorAll('input,textarea,select'))input.disabled=!visible;select.value=policy?.cost||'quote';currency.value=policy?.feeCurrency||'XBT';for(const [name,key] of [['shippingFee','fee'],['shippingDispatch','dispatch'],['shippingEstimate','estimate'],['shippingReturns','returns']])form.elements[name].value=policy?.[key]||'';select.dispatchEvent(new Event('change'));},value(){return shippingPolicy({cost:select.value,feeCurrency:currency.value,fee:form.elements.shippingFee.value,dispatch:form.elements.shippingDispatch.value,estimate:form.elements.shippingEstimate.value,returns:form.elements.shippingReturns.value});}};
}
