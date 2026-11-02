// A reversible review reservation only. Never a funding or spending permission.
export function initializeEscrowPreparation(store){
 store.db.exec(`CREATE TABLE IF NOT EXISTS market_escrow_preparations(
 order_id TEXT PRIMARY KEY,contract_hash TEXT NOT NULL,receipt_hash TEXT NOT NULL,created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS market_escrow_funding_authorizations(order_id TEXT PRIMARY KEY,activated INTEGER NOT NULL CHECK(activated IN (0,1)),body TEXT NOT NULL);
 CREATE TRIGGER IF NOT EXISTS escrow_funding_preparation_delete BEFORE DELETE ON market_escrow_preparations
 WHEN EXISTS(SELECT 1 FROM market_escrow_funding_authorizations WHERE order_id=OLD.order_id AND activated=1)
 BEGIN SELECT RAISE(ABORT,'Funding consent is permanent; reconcile deposits and settlement instead of unlocking.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_funding_delete BEFORE DELETE ON market_escrow_funding_authorizations WHEN OLD.activated=1
 BEGIN SELECT RAISE(ABORT,'Funding consent history cannot be deleted.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_funding_downgrade BEFORE UPDATE ON market_escrow_funding_authorizations
 WHEN OLD.activated=1 AND (NEW.activated!=1 OR NEW.order_id!=OLD.order_id)
 BEGIN SELECT RAISE(ABORT,'Funding consent cannot be revoked.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_preparation_order_update BEFORE UPDATE ON market_orders
 WHEN EXISTS(SELECT 1 FROM market_escrow_preparations WHERE order_id=OLD.id)
 BEGIN SELECT RAISE(ABORT,'Withdraw the reserved escrow review before changing this order.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_preparation_order_delete BEFORE DELETE ON market_orders
 WHEN EXISTS(SELECT 1 FROM market_escrow_preparations WHERE order_id=OLD.id)
 BEGIN SELECT RAISE(ABORT,'Reserved escrow order cannot be deleted.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_preparation_mode_insert BEFORE INSERT ON market_order_payment_modes
 WHEN EXISTS(SELECT 1 FROM market_escrow_preparations WHERE order_id=NEW.order_id)
 BEGIN SELECT RAISE(ABORT,'Withdraw the reserved escrow review before changing payment mode.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_preparation_mode_update BEFORE UPDATE ON market_order_payment_modes
 WHEN EXISTS(SELECT 1 FROM market_escrow_preparations WHERE order_id IN (OLD.order_id,NEW.order_id))
 BEGIN SELECT RAISE(ABORT,'Withdraw the reserved escrow review before changing payment mode.'); END;
 CREATE TRIGGER IF NOT EXISTS escrow_preparation_mode_delete BEFORE DELETE ON market_order_payment_modes
 WHEN EXISTS(SELECT 1 FROM market_escrow_preparations WHERE order_id=OLD.order_id)
 BEGIN SELECT RAISE(ABORT,'Withdraw the reserved escrow review before changing payment mode.'); END;`);
}
