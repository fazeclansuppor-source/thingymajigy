# Macro Gallery with Download Limits + Discord Update Bot

## Setup

```bash
npm install            # installs express, discord.js, etc.
npm start              # starts API on :3000
npm run bot            # (in a second terminal) registers /update and starts the Discord bot
```

* **index.html** — front‑end (open in browser)
* **server.js** — Node + SQLite API, counts unique downloads (per browser)
* **bot.js** — Discord slash‑command to push new macro builds
* **macros/** — folder where each `<macro>.zip` lives
