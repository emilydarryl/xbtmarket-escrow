import {createHash} from 'node:crypto';

const MAX_SATS = 21000000n * 100000000n;
export const FEE_POLICY_VERSION = 'seller-success-v1';
export const FEE_RATE_BPS = 200;

export function xbtToSats(value) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d{0,7})(\.\d{1,8})?$/.test(value)) {
    throw Error('Use an exact XBT amount with up to eight decimals.');
  }
  const [whole, fraction = ''] = value.split('.');
  const sats = BigInt(whole) * 100000000n + BigInt(fraction.padEnd(8, '0'));
  if (sats > MAX_SATS) throw Error('XBT amount exceeds the supported range.');
  return sats;
}

export function satsToXbt(value) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d{0,15})$/.test(value)) throw Error('Integer satoshis required.');
  const sats = BigInt(value);
  if (sats > MAX_SATS) throw Error('XBT amount exceeds the supported range.');
  return `${sats / 100000000n}.${String(sats % 100000000n).padStart(8, '0')}`;
}

export function feePolicy(total) {
  const totalSats = xbtToSats(total);
  if (totalSats === 0n) throw Error('A positive order total is required.');
  return {
    version: FEE_POLICY_VERSION,
    rateBps: FEE_RATE_BPS,
    basis: 'agreed-total-including-delivery',
    payer: 'seller',
    totalSats: String(totalSats),
    feeSats: String((totalSats * BigInt(FEE_RATE_BPS) + 9999n) / 10000n),
    currency: 'XBT',
    method: 'XBT-CHAIN',
    due: 'buyer-completion',
    refund: 'full-sale-refund-review',
  };
}

export function feeBinding(order) {
  const expected = feePolicy(order.total);
  if (JSON.stringify(order.platformFeePolicy) !== JSON.stringify(expected) || !order.feeAcceptedAt) {
    throw Error('This order has no accepted platform-fee policy.');
  }
  const contract = {orderId: order.id, sellerId: order.profileId, policy: expected};
  return {
    orderId: order.id,
    feeSats: expected.feeSats,
    contractHash: createHash('sha256').update(JSON.stringify(contract)).digest('hex'),
    method: 'XBT-CHAIN',
  };
}
