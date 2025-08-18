const db = require('better-sqlite3')('macros/macros.db');

console.table(
  db.prepare(`
    SELECT fp            AS fingerprint,
           datetime(banned_at,'unixepoch') AS detected_at
    FROM   banned_fp
    ORDER  BY banned_at DESC
  `).all()
);
