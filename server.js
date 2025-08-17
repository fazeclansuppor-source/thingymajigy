// server.js — Static site + API + file host in one process

import express   from 'express';
import Database  from 'better-sqlite3';
import cors      from 'cors';
import path      from 'path';
import fs        from 'fs';

/* ---------- 0. config ---------- */
const PORT       = process.env.PORT || 8000;           // Koyeb forwards 8000
const MACROS_DIR = process.env.MACROS_DIR              // /persistent/macros
                 || path.resolve('macros');
const PUBLIC_DIR = path.resolve('public');             // index.html folder
const MACROS     = ['better-tiny-task', 'grow-garden'];

/* ---------- 1. SQLite ---------- */
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

/* ---------- 2. Express ---------- */
const app = express();
app.use(cors());
app.use(express.json());

/* Static site */
app.use(express.static(PUBLIC_DIR));           // index.html, JS, images

/* Direct ZIP access */
app.use('/macros', express.static(MACROS_DIR));

/* GET /stats */
app.get('/stats', (_req, res) => {
  const rows = db.prepare('SELECT id, downloads FROM stats').all();
  res.json({
    total:  rows.reduce((s, r) => s + r.downloads, 0),
    macros: Object.fromEntries(rows.map(r => [r.id, r.downloads]))
  });
});

/* POST /download/:id */
app.post('/download/:id', (req, res) => {
  const { id } = req.params;
  if (!MACROS.includes(id)) return res.status(404).send('Unknown macro');

  db.prepare(
    'UPDATE stats SET downloads = downloads + 1 WHERE id = ?'
  ).run(id);

  res.download(path.join(MACROS_DIR, `${id}.zip`));
});

/* ---------- 3. start ---------- */
app.listen(PORT, () =>
  console.log(`🌐  Site + API listening on :${PORT}`)
);
