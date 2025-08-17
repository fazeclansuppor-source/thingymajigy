// server.js – API + file host

import express   from 'express';
import Database  from 'better-sqlite3';
import cors      from 'cors';
import path      from 'path';
import fs        from 'fs';

const db = new Database('macros.db');

/* ---------- 1. one-time table ---------- */
db.prepare(`
  CREATE TABLE IF NOT EXISTS stats (
    id        TEXT PRIMARY KEY,
    downloads INTEGER DEFAULT 0
  )
`).run();

/* ---------- 2. macros folder ---------- */
const macrosDir = path.resolve('macros');
fs.mkdirSync(macrosDir, { recursive: true });

const MACROS = ['better-tiny-task', 'grow-garden'];
MACROS.forEach(id => {
  db.prepare('INSERT OR IGNORE INTO stats (id, downloads) VALUES (?,0)').run(id);
  const stub = path.join(macrosDir, `${id}.zip`);
  if (!fs.existsSync(stub)) fs.writeFileSync(stub, `Placeholder for ${id}`);
});

/* ---------- 3. app ---------- */
const app = express();
app.use(cors());
app.use(express.json());
app.use('/macros', express.static(macrosDir));   // direct GET fallback

/* --- GET /stats  (JSON counters) --- */
app.get('/stats', (req, res) => {
  const rows   = db.prepare('SELECT id, downloads FROM stats').all();
  const macros = Object.fromEntries(rows.map(r => [r.id, r.downloads]));
  const total  = rows.reduce((s, r) => s + r.downloads, 0);
  res.json({ total, macros });
});

/* --- POST /download/:id  (count + stream ZIP) --- */
app.post('/download/:id', (req, res) => {
  const { id } = req.params;

  const updated = db.prepare(
    'UPDATE stats SET downloads = downloads + 1 WHERE id = ?'
  ).run(id).changes;

  if (!updated) return res.status(404).send('Unknown macro');

  const filePath = path.join(macrosDir, `${id}.zip`);
  return res.download(filePath);         // streams the real file
});

/* ---------- 4. launch ---------- */
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`API running on :${PORT}`));
