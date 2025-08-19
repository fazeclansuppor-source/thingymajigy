// server.js — static site · OAuth2 login · API · ZIP host
// Permanent bans: Discord IDs + browser fingerprints (no IP layer)
// + one-user admin console at /admin
// + Maintenance Mode toggle (hides site for non-admins with custom HTML)

import express                 from 'express';
import cors                    from 'cors';
import path                    from 'path';
import fs                      from 'fs';
import session                 from 'express-session';
import cookieParser            from 'cookie-parser';
import passport                from 'passport';
import { Strategy as Discord } from 'passport-discord';
import Database                from 'better-sqlite3';
import { v4 as uuid }          from 'uuid';

/* ---------- config ---------- */
const PORT        = process.env.PORT        || 8000;
const BASE_URL    = process.env.BASE_URL    || `http://localhost:${PORT}`;
const MACROS_DIR  = process.env.MACROS_DIR  || path.resolve('macros');
const TURNSTILE_SECRET = process.env.TURNSTILE_SECRET || '';
const TEMPL_DIR   = path.resolve('templates');
const SESSION_KEY = process.env.SESSION_SECRET || uuid();
const COOKIE_KEY  = process.env.COOKIE_SECRET  || uuid();
const MACROS      = ['better-tiny-task', 'grow-garden'];

/* ---------- allow / deny lists ---------- */
const ALLOWED_USERS = ['1339828846010175488'];                 // your Discord ID
const ALLOWED_ROLES = ['1378656437227618374','1378656660234440795'];
const INITIAL_BANNED_IDS = ['954770270961414235','950446866527584287'];

/* ---------- admin allow helper (used by multiple middlewares) ---------- */
function isAllowed(u) {
  if (!u) return false;
  if (ALLOWED_USERS.includes(u.id)) return true;
  if (u.roles?.some(r => ALLOWED_ROLES.includes(r.id))) return true;
  return false;
}

/* ---------- gag error generator ---------- */
function randomErrorPage() {
  const pick = a => a[Math.floor(Math.random() * a.length)];
  const titles = [
    '☢ Kernel Panic ☢', '💥 Segmentation Falafel 💥',
    '🔥 Blue Screen of Waffles 🔥', '⚡ Recursive Dimension Tear ⚡',
    '🦄 Cosmic Bit-Flip Catastrophe 🦄'
  ];
  const reasons = [
    'ERR_UNICORN_RAMPAGE','ERR_DIVIDE_BY_CUCUMBER',
    'ERR_NULL_POINTER_TO_HAPPINESS','ERR_STACK_OVERFLOW_PIZZA',
    'ERR_TOO_MUCH_SAUCE'
  ];
  const frames = [
    '0x0042 — 🍌 invokeBanana()', '0x00DE — 🥑 parseGuacamole()',
    '0x0BAD — 🦖 coreDump()',      '0xDEAD — 👾 hexDumpGremlins()',
    '0xBEEF — 🍔 grillStackBurger()'
  ];
  const stack = Array.from({ length: 3 }, () => pick(frames)).join('\n  ');
  return `<!doctype html><html><head><title>${pick(titles)}</title><style>
  body{background:#000;color:#0f0;font-family:"Courier New",monospace;padding:40px}
  a{color:#f0f}
  </style></head><body><pre>
Stack trace (abridged):
  ${stack}

Reason: <strong>${pick(reasons)}</strong>

Please consult our <a href="https://youtu.be/dQw4w9WgXcQ">Quantum Debugging Tutorial</a>.
</pre></body></html>`;
}

/* ---------- SQLite ---------- */
fs.mkdirSync(MACROS_DIR, { recursive: true });
const db = new Database(path.join(MACROS_DIR, 'macros.db'));

db.exec(`
  CREATE TABLE IF NOT EXISTS stats      (id TEXT PRIMARY KEY, downloads INTEGER DEFAULT 0);
  CREATE TABLE IF NOT EXISTS banned_ids (id TEXT PRIMARY KEY, banned_at INTEGER);
  CREATE TABLE IF NOT EXISTS banned_fp  (fp TEXT PRIMARY KEY, banned_at INTEGER);
  CREATE TABLE IF NOT EXISTS config     (key TEXT PRIMARY KEY, value TEXT);
`);
MACROS.forEach(id => {
  db.prepare('INSERT OR IGNORE INTO stats(id) VALUES(?)').run(id);
  const stub = path.join(MACROS_DIR, `${id}.zip`);
  if (!fs.existsSync(stub)) fs.writeFileSync(stub, `Placeholder for ${id}`);
});
INITIAL_BANNED_IDS.forEach(id => {
  db.prepare("INSERT OR IGNORE INTO banned_ids(id,banned_at) VALUES(?,strftime('%s','now'))").run(id);
});

/* config helpers */
const cfgGet = (k, d='') => {
  const row = db.prepare('SELECT value FROM config WHERE key=?').get(k);
  return row?.value ?? d;
};
const cfgSet = (k, v) => {
  db.prepare(`
    INSERT INTO config(key,value) VALUES (?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value
  `).run(k, String(v));
};
const ensureDefault = (k, v) => {
  if (db.prepare('SELECT 1 FROM config WHERE key=?').get(k) == null) cfgSet(k, v);
};

/* defaults for Maintenance Mode */
ensureDefault('maintenance_enabled', '0');
ensureDefault(
  'maintenance_html',
  `<!doctype html><html><head>
<meta charset="utf-8">
<title>We’ll be right back</title>
<meta name="robots" content="noindex">
<style>
  html,body{background:#0b0b10;color:#e5e7eb;font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Noto Sans,sans-serif;height:100%;margin:0}
  .wrap{min-height:100%;display:flex;align-items:center;justify-content:center;padding:40px;text-align:center}
  .card{max-width:720px;width:100%;border:1px solid #374151;border-radius:16px;background:#111827;padding:32px}
  h1{font-size:28px;margin:0 0 8px} p{color:#9ca3af;margin:0}
</style></head><body>
<div class="wrap"><div class="card">
  <h1>Scheduled maintenance</h1>
  <p>Macro Stack is temporarily offline. Please check back soon.</p>
</div></div></body></html>`
);

/* helpers for bans */
const addIdBan = id => db.prepare(
  `INSERT OR IGNORE INTO banned_ids(id,banned_at) VALUES (?,strftime('%s','now'))`
).run(id);
// upsert so timestamp updates on repeat
const addFpBan = fp => db.prepare(`
  INSERT INTO banned_fp(fp,banned_at)
       VALUES (?,strftime('%s','now'))
  ON CONFLICT(fp) DO UPDATE SET banned_at=excluded.banned_at
`).run(fp);
const isIdBanned = id => db.prepare('SELECT 1 FROM banned_ids WHERE id=?').get(id);
const isFpBanned = fp => db.prepare('SELECT 1 FROM banned_fp WHERE fp=?').get(fp);

/* ---------- Express & passport ---------- */
const app = express();
app.set('trust proxy', 1); // behind Koyeb/ingress
app.use(cors());
app.use(express.json());
app.use(cookieParser(COOKIE_KEY));
app.use(session({
  secret: SESSION_KEY,
  resave: false,
  saveUninitialized: false,
  cookie: { sameSite: 'lax', secure: process.env.NODE_ENV === 'production' }
}));
app.use(passport.initialize());
app.use(passport.session());

passport.serializeUser((u, cb) => cb(null, u));
passport.deserializeUser((o, cb) => cb(null, o));

// ---- ONE canonical callback URL ----
const ORIGIN   = (process.env.BASE_URL || `http://localhost:${PORT}`).replace(/\/+$/, '');
const CALLBACK = `${ORIGIN}/auth/discord/callback`;
console.log('OAuth ORIGIN =', ORIGIN);
console.log('OAuth CALLBACK =', CALLBACK);

// ---- Cloudflare Turnstile verify helper ----
async function verifyTurnstile(token, remoteip) {
  try {
    if (!TURNSTILE_SECRET || !token) return false;

    const body = new URLSearchParams();
    body.append('secret', TURNSTILE_SECRET);   // server-side secret
    body.append('response', token);            // token from the browser
    if (remoteip) body.append('remoteip', remoteip);

    const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString()
    });

    const data = await r.json();
    return !!data.success;
  } catch (e) {
    console.error('Turnstile verify error:', e);
    return false;
  }
}

passport.use(new Discord({
  clientID: process.env.CLIENT_ID,
  clientSecret: process.env.CLIENT_SECRET,
  callbackURL: CALLBACK,
  scope: ['identify']
}, (_at, _rt, prof, cb) => cb(null, prof)));

// Always start login here (do NOT link directly to discord.com)
app.get('/auth/discord', (req, res, next) => {
  passport.authenticate('discord', { scope: ['identify'], callbackURL: CALLBACK })(req, res, next);
});

// Callback must use the same CALLBACK value
app.get('/auth/discord/callback', (req, res, next) => {
  passport.authenticate('discord', { callbackURL: CALLBACK }, (err, user, info) => {
    if (err) { console.error('❌ Discord auth error:', err, info); return res.status(500).send('Auth error'); }
    if (!user) { console.error('❌ Discord login failed:', info); return res.status(401).send('Login failed'); }
    req.logIn(user, (e) => {
      if (e) { console.error('❌ req.logIn error:', e); return res.status(500).send('Session error'); }
      return res.redirect('/');
    });
  })(req, res, next);
});

app.get('/logout',(req,res)=>{ req.logout(()=>{}); res.redirect('/'); });

/* ---------- Maintenance Mode gate (after auth routes, before static) ---------- */
app.use((req, res, next) => {
  // Allow admin & auth paths so you can sign in and flip the switch back
  const allowPaths = ['/admin', '/auth/discord', '/auth/discord/callback', '/logout'];
  const isAllowlisted = allowPaths.some(p => req.path === p || req.path.startsWith(p));

  const enabled = cfgGet('maintenance_enabled', '0') === '1';
  const adminOk = req.isAuthenticated?.() && isAllowed(req.user);

  if (!enabled || adminOk || isAllowlisted) return next();

  // Serve the configured HTML with a 503
  const html = cfgGet('maintenance_html');
  res.setHeader('Cache-Control','no-store');
  res.setHeader('Retry-After','600'); // hint for clients/CDNs (optional)
  return res.status(503).type('html').send(html);
});

/* ---------- Static front-end ---------- */
import { fileURLToPath } from 'url';
const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

app.use('/static', express.static(path.join(__dirname, 'static')));
app.use(express.static(TEMPL_DIR));
app.get('/', (_q,res)=>res.sendFile('index.html',{root:TEMPL_DIR}));

/* ---------- ban + login middleware ---------- */
function requireLogin(req, res, next) {
  const signedFp = req.signedCookies.fp;
  const rawFp    = req.cookies.fp;
  const fp       = signedFp || rawFp;

  console.log(`[AUTH] user=${req.user?.id||'anon'} fp=${fp||'<none>'} path=${req.path}`);

  if (req.signedCookies.perm_ban === '1') {
    return res.status(500).type('html').send(randomErrorPage());
  }
  if (!req.isAuthenticated?.()) {
    return res.status(500).type('html').send(randomErrorPage());
  }
  if (isAllowed(req.user)) return next();
  if (fp && isFpBanned(fp)) {
    return res.status(500).type('html').send(randomErrorPage());
  }
  if (isIdBanned(String(req.user.id))) {
    if (fp) addFpBan(fp);
    res.cookie('perm_ban','1',{
      signed: true, httpOnly: true, sameSite: 'lax',
      maxAge: 10*365*24*60*60*1000
    });
    return res.status(500).type('html').send(randomErrorPage());
  }
  next();
}

/* ---------- Admin UI & APIs ---------- */
app.get('/admin', requireLogin, (req,res)=>{
  if (!isAllowed(req.user)) return res.sendStatus(403);
  res.sendFile('admin.html',{root:TEMPL_DIR});
});
app.get('/admin/bans', requireLogin, (req,res)=>{
  if (!isAllowed(req.user)) return res.sendStatus(403);
  const ids=db.prepare('SELECT id FROM banned_ids').all().map(r=>r.id);
  const fp=db.prepare('SELECT fp FROM banned_fp').all().map(r=>r.fp);
  res.json({ ids, fp });
});
app.post('/admin/ban', requireLogin, (req,res)=>{
  if (!isAllowed(req.user)) return res.sendStatus(403);
  const { type, value } = req.body||{};
  if (!['id','fp'].includes(type)||!value) return res.sendStatus(400);
  (type==='id'?addIdBan:addFpBan)(value.trim());
  res.json({ ok:true });
});
app.delete('/admin/ban/:type/:value?', requireLogin, (req, res) => {
  if (!isAllowed(req.user)) return res.sendStatus(403);
  const { type } = req.params;
  const value = (req.params.value ?? '').trim();
  if (!['id','fp'].includes(type)) return res.sendStatus(400);
  const table = type==='id'?'banned_ids':'banned_fp';
  const column= type==='id'?'id':'fp';
  const stmt=db.prepare(`DELETE FROM ${table} WHERE ${column}=?`).run(value);
  if (value==='') db.prepare("DELETE FROM banned_ids WHERE id='' OR id IS NULL").run();
  res.json({ removed:stmt.changes });
});

/* ---------- Maintenance config APIs ---------- */
app.get('/admin/config', requireLogin, (req, res) => {
  if (!isAllowed(req.user)) return res.sendStatus(403);
  res.json({
    maintenance_enabled: cfgGet('maintenance_enabled','0') === '1',
    maintenance_html: cfgGet('maintenance_html','')
  });
});
app.post('/admin/config', requireLogin, (req, res) => {
  if (!isAllowed(req.user)) return res.sendStatus(403);
  const { maintenance_enabled, maintenance_html } = req.body || {};
  const on = maintenance_enabled ? '1' : '0';
  cfgSet('maintenance_enabled', on);
  if (typeof maintenance_html === 'string') cfgSet('maintenance_html', maintenance_html);
  res.json({ ok: true, maintenance_enabled: on === '1' });
});

/* ---------- stats & download ---------- */
app.get('/stats',(req,res)=>{
  const rows=db.prepare('SELECT id,downloads FROM stats').all();
  res.json({ total:rows.reduce((s,r)=>s+r.downloads,0),
    macros:Object.fromEntries(rows.map(r=>[r.id,r.downloads])),
    user:req.isAuthenticated?.()?{
      id:req.user.id,username:req.user.username,avatar:req.user.avatar
    }:null
  });
});
app.post('/download/:id', requireLogin, async (req, res) => {
  const { id } = req.params;
  const ok = await verifyTurnstile(req.body?.cfToken, req.ip);
  if (!ok) {
    console.warn('[DL] captcha_failed', { id, ip: req.ip });
    return res.status(403).json({ error: 'captcha_failed' });
  }
  req.session.cfok = Date.now();
  const filePath = path.join(MACROS_DIR, `${id}.zip`);
  if (!MACROS.includes(id)) {
    console.warn('[DL] unknown id', { id });
    return res.status(404).json({ error: 'unknown_macro' });
  }
  if (!fs.existsSync(filePath)) {
    console.error('[DL] missing file', { filePath });
    return res.status(404).json({ error: 'missing_file', filePath });
  }
  try {
    db.prepare('UPDATE stats SET downloads=downloads+1 WHERE id=?').run(id);
  } catch (e) {
    console.error('[DL] stats update failed', e);
    return res.status(500).json({ error: 'stats_update_failed' });
  }
  console.log('[DL] sending', { id, filePath });
  res.download(filePath, err => {
    if (err) {
      console.error('[DL] download error', err);
      if (!res.headersSent) res.status(500).json({ error: 'download_error' });
    }
  });
});

/* ---------- start & error handler ---------- */
app.listen(PORT,()=>console.log(`🌐  Site + API running on :${PORT}`));
app.use((err,req,res,_next)=>{
  console.error('❗ Unhandled server error:',err);
  if(res.headersSent) return;
  res.status(500).type('html').send(randomErrorPage());
});
