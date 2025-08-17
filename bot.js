// bot.js  —  global-command version
import { Client, GatewayIntentBits, Partials,
         REST, Routes, SlashCommandBuilder } from 'discord.js';
import fetch  from 'node-fetch';
import fs     from 'fs';
import path   from 'path';

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const MACROS_DIR = path.resolve('macros');
const MACROS = ['better-tiny-task', 'grow-garden'];

/* ---------- 1. build the command ---------- */
const updateCmd = new SlashCommandBuilder()
  .setName('update')
  .setDescription('Replace macro file on the download server')
  .setDMPermission(true)                       // ✅ usable in DMs
  .addStringOption(o =>
      o.setName('macro')
       .setDescription('Macro ID')
       .setRequired(true)
       .addChoices(...MACROS.map(m => ({ name: m, value: m }))))
  .addAttachmentOption(o =>
      o.setName('file')
       .setDescription('ZIP file to upload')
       .setRequired(true));

/* ---------- 2. register it *globally* ---------- */
const rest  = new REST({ version: '10' }).setToken(TOKEN);
const appId = (await rest.get(Routes.user())).id;

await rest.put(
  Routes.applicationCommands(appId),           // ← GLOBAL scope
  { body: [updateCmd.toJSON()] }
);

console.log('🌍  Slash command pushed globally (may take ~1 h to appear)');

/* ---------- 3. run the bot ---------- */
const client = new Client({
  intents: [GatewayIntentBits.Guilds],
  partials: [Partials.Channel]
});

client.once('ready', () =>
  console.log(`🤖 Logged in as ${client.user.tag}`)
);

client.on('interactionCreate', async i => {
  if (!i.isChatInputCommand() || i.commandName !== 'update') return;

  const macro = i.options.getString('macro');
  const file  = i.options.getAttachment('file');

  await i.deferReply();

  const data = Buffer.from(await (await fetch(file.url)).arrayBuffer());
  fs.writeFileSync(path.join(MACROS_DIR, `${macro}.zip`), data);

  await i.editReply(
    `✅ **${macro}** updated — ${(data.length / 1024).toFixed(1)} KB`
  );
});

client.login(TOKEN);
