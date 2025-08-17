// site.js — lightweight static server for the front-end
import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 8080;

const app = express();

/* Serve every file in the project folder:
   index.html, graphics, macros/, etc. */
app.use(express.static(__dirname));

app.listen(PORT, () =>
  console.log(`🌐  Front-end available at  http://localhost:${PORT}`)
);
