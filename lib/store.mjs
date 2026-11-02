import { DatabaseSync } from "node:sqlite";
export class Store {
  constructor(path) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS blocks(height INTEGER PRIMARY KEY,hash TEXT UNIQUE NOT NULL,body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY,time INTEGER NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS telemetry(provider TEXT NOT NULL,id TEXT NOT NULL,start INTEGER NOT NULL,end INTEGER NOT NULL,body TEXT NOT NULL,PRIMARY KEY(provider,id));
    CREATE INDEX IF NOT EXISTS telemetry_interval ON telemetry(provider,start,end);
    CREATE TABLE IF NOT EXISTS applications(id TEXT PRIMARY KEY,created INTEGER NOT NULL,status TEXT NOT NULL DEFAULT 'pending',body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS providers(id TEXT PRIMARY KEY,application TEXT NOT NULL,token_hash TEXT UNIQUE NOT NULL,active INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE IF NOT EXISTS intake_limits(bucket INTEGER PRIMARY KEY,count INTEGER NOT NULL);`);
  }
  blocks(limit = 2016) {
    return this.db
      .prepare("SELECT body FROM blocks ORDER BY height DESC LIMIT ?")
      .all(limit)
      .map((r) => JSON.parse(r.body));
  }
  get(key) {
    const r = this.db.prepare("SELECT value FROM meta WHERE key=?").get(key);
    return r ? JSON.parse(r.value) : null;
  }
  set(key, value) {
    this.db
      .prepare("INSERT OR REPLACE INTO meta VALUES (?,?)")
      .run(key, JSON.stringify(value));
  }
  saveBlocks(blocks, retention) {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const insert = this.db.prepare(
        "INSERT OR REPLACE INTO blocks VALUES (?,?,?)",
      );
      for (const b of blocks) insert.run(b.height, b.hash, JSON.stringify(b));
      this.db
        .prepare(
          "DELETE FROM blocks WHERE height < (SELECT MAX(height) FROM blocks)-?+1",
        )
        .run(retention);
      this.db.exec("COMMIT");
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }
  reset(reason) {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db.exec("DELETE FROM blocks");
      this.db
        .prepare("INSERT INTO events(time,kind,body) VALUES (?,?,?)")
        .run(Date.now(), "canonical-window-reset", JSON.stringify(reason));
      this.db.exec("COMMIT");
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }
  events() {
    return this.db
      .prepare("SELECT time,kind,body FROM events ORDER BY id DESC LIMIT 20")
      .all()
      .map((e) => ({ ...e, body: JSON.parse(e.body) }));
  }
  telemetry() {
    return this.db
      .prepare("SELECT body FROM telemetry WHERE end > ?")
      .all(Date.now() - 86400000)
      .map((r) => JSON.parse(r.body));
  }
  addTelemetry(record) {
    const previous = this.db
      .prepare("SELECT body FROM telemetry WHERE provider=? AND id=?")
      .get(record.provider, record.id);
    if (previous) {
      if (previous.body === JSON.stringify(record)) return false;
      throw new Error("Report id already used with different content");
    }
    if (
      this.db
        .prepare(
          "SELECT id FROM telemetry WHERE provider=? AND start < ? AND end > ? LIMIT 1",
        )
        .get(record.provider, record.end, record.start)
    )
      throw new Error("Reporting intervals overlap");
    this.db
      .prepare("INSERT INTO telemetry VALUES (?,?,?,?,?)")
      .run(
        record.provider,
        record.id,
        record.start,
        record.end,
        JSON.stringify(record),
      );
    this.db
      .prepare("DELETE FROM telemetry WHERE end < ?")
      .run(Date.now() - 35 * 86400000);
    return true;
  }
  close() {
    this.db.close();
  }
  expireApplications(now = Date.now()) {
    this.db
      .prepare(
        "DELETE FROM applications WHERE status='pending' AND created < ?",
      )
      .run(now - 90 * 86400000);
  }
  addApplication(application, now = Date.now()) {
    const existing = this.db
      .prepare("SELECT body FROM applications WHERE id=?")
      .get(application.id);
    if (existing) {
      if (existing.body !== JSON.stringify(application))
        throw new Error(
          "Request identifier already used. Refresh the page to submit new details.",
        );
      return false;
    }
    const bucket = Math.floor(now / 3600000);
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db
        .prepare(
          "DELETE FROM applications WHERE status='pending' AND created < ?",
        )
        .run(now - 90 * 86400000);
      this.db
        .prepare("DELETE FROM intake_limits WHERE bucket < ?")
        .run(bucket - 24);
      const used =
        this.db
          .prepare("SELECT count FROM intake_limits WHERE bucket=?")
          .get(bucket)?.count || 0;
      const pending = this.db
        .prepare(
          "SELECT COUNT(*) AS n FROM applications WHERE status='pending'",
        )
        .get().n;
      if (used >= 30 || pending >= 1000)
        throw new Error("Operator intake is busy. Please try again later.");
      this.db
        .prepare(
          "INSERT INTO intake_limits VALUES (?,1) ON CONFLICT(bucket) DO UPDATE SET count=count+1",
        )
        .run(bucket);
      this.db
        .prepare(
          "INSERT INTO applications(id,created,status,body) VALUES (?,?,'pending',?)",
        )
        .run(application.id, now, JSON.stringify(application));
      this.db.exec("COMMIT");
      return true;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
  applications() {
    return this.db
      .prepare("SELECT * FROM applications ORDER BY created DESC")
      .all()
      .map((r) => ({ ...r, body: JSON.parse(r.body) }));
  }
  approveApplication(application, provider, hash) {
    if (!/^[a-zA-Z0-9_-]{1,80}$/.test(provider) || !/^[a-f0-9]{64}$/.test(hash))
      throw new Error("Invalid provider or token digest");
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const row = this.db
        .prepare("SELECT status FROM applications WHERE id=?")
        .get(application);
      if (!row || row.status !== "pending")
        throw new Error("Application is not pending");
      this.db
        .prepare(
          "INSERT INTO providers(id,application,token_hash) VALUES (?,?,?)",
        )
        .run(provider, application, hash);
      this.db
        .prepare("UPDATE applications SET status='approved' WHERE id=?")
        .run(application);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
  providerForHash(hash) {
    return (
      this.db
        .prepare("SELECT id FROM providers WHERE token_hash=? AND active=1")
        .get(hash)?.id || null
    );
  }
  activeProviderIds() {
    return this.db
      .prepare("SELECT id FROM providers WHERE active=1")
      .all()
      .map((row) => row.id);
  }
  revokeProvider(id) {
    this.db.prepare("UPDATE providers SET active=0 WHERE id=?").run(id);
  }
  rejectApplication(id) {
    this.db
      .prepare("DELETE FROM applications WHERE id=? AND status='pending'")
      .run(id);
  }
}
