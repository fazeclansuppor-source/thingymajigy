// server.js — Static site + API + file host in one process

import express  from 'express';
import Database from 'better-sqlite3';
import cors     from 'cors';
import path     from 'path';
import fs       from 'fs';

/* ---------- 0 · CONFIG ---------- */
const PORT        = process.env.PORT || 8000;              // Koyeb forwards 8000
const MACROS_DIR  = process.env.MACROS_DIR || path.resolve('macros');
const TPL_DIR     = path.resolve('templates');             // <- index.html lives here
const STATIC_DIR  = path.resolve('.');                     // everything else (js/img)
const MACROS      = ['better-tiny-task', 'grow-garden'];

/* ---------- 1 · SQLITE ---------- */
fs.mkdirSync(MACROS_DIR, { recursive: true });
const db = new Database(path.join(MACROS_DIR, 'macros.db'));
db.prepare(`
  CREATE TABLE IF NOT EXISTS stats (
    id        TEXT PRIMARY KEY,
    downloads INTEGER DEFAULT 0
  )
`).run();

MACROS.forEach(id => {
  db.prepare('INSERT OR IGNORE INTO stats (id) VALUES (?)').run(id);
  const stub = path.join(MACROS_DIR, `${id}.zip`);
  if (!fs.existsSync(stub)) fs.writeFileSync(stub, `Placeholder for ${id}`);
});

/* ---------- 2 · EXPRESS ---------- */
const app = express();
app.use(cors());
app.use(express.json());

/* Static assets (js, css, images, etc.) */
app.use(express.static(STATIC_DIR));

/* Serve index.html from /templates when someone hits / */
app.get('/', (_req, res) =>
  res.sendFile(path.join(TPL_DIR, 'index.html'))
);

/* Direct ZIP access for re-downloads */
app.use('/macros', express.static(MACROS_DIR));

/* GET /stats */
app.get('/stats', (_req, res) => {
  const rows = db.prepare('SELECT id, downloads FROM stats').all();
  res.json({
    total:  rows.reduce((s, r) => s + r.downloads, 0),
    macros: Object.fromEntries(rows.map(r => [r.id, r.downloads]))
  });
});

/* POST /download/:id (count + stream) */
app.post('/download/:id', (req, res) => {
  const { id } = req.params;
  if (!MACROS.includes(id)) return res.status(404).send('Unknown macro');

  db.prepare(
    'UPDATE stats SET downloads = downloads + 1 WHERE id = ?'
  ).run(id);

  res.download(path.join(MACROS_DIR, `${id}.zip`));
});

/* ---------- 3 · START ---------- */
app.listen(PORT, () =>
  console.log(`🌐  Site + API listening on :${PORT}`)
);
