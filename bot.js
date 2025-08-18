// bot.js — Discord slash-command bot for /update

import { Client, GatewayIntentBits, Partials,
         REST, Routes, SlashCommandBuilder } from 'discord.js';
import fetch  from 'node-fetch';                       // keep: uses prebuilt binary
import fs     from 'fs';
import path   from 'path';

/* ---------- config ---------- */
const TOKEN      = process.env.DISCORD_BOT_TOKEN;
const MACROS_DIR = process.env.MACROS_DIR || path.resolve('macros');
const MACROS     = ['better-tiny-task', 'grow-garden'];

/* ---------- access control ---------- */
const ALLOWED_USERS = [
  '1339828846010175488'            // your specific user ID
];

const ALLOWED_ROLES = [
  '1378656437227618374',           // Macro Admins
  '1378656660234440795'            // Trusted Uploaders
];

/* ---------- 1. build slash command ---------- */
const updateCmd = new SlashCommandBuilder()
  .setName('update')
  .setDescription('Replace macro file on the download server')
  .setDMPermission(true)                       // works in DMs too
  .addStringOption(o =>
    o.setName('macro')
     .setDescription('Macro ID')
     .setRequired(true)
     .addChoices(...MACROS.map(m => ({ name: m, value: m }))))
  .addAttachmentOption(o =>
    o.setName('file')
     .setDescription('ZIP file to upload')
     .setRequired(true));

/* ---------- 2. register globally ---------- */
const rest  = new REST({ version: '10' }).setToken(TOKEN);
const appId = (await rest.get(Routes.user())).id;

await rest.put(
  Routes.applicationCommands(appId),           // global scope
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

  /* ----- permission gate ----- */
  const uid = i.user.id;
  const hasAllowedRole =
    i.inGuild() &&
    i.member.roles.cache.some(r => ALLOWED_ROLES.includes(r.id));

  if (!ALLOWED_USERS.includes(uid) && !hasAllowedRole) {
    return i.reply({
      content: '🚫 You are not allowed to run this command.',
      ephemeral: true
    });
  }

  /* ----- proceed with upload ----- */
  const macro = i.options.getString('macro');
  const file  = i.options.getAttachment('file');

  await i.deferReply();                    // public, visible to channel

  const res  = await fetch(file.url);
  if (!res.ok) {
    return i.editReply(`❌ Failed to fetch attachment (${res.status})`);
  }

  const filePath = path.join(MACROS_DIR, `${macro}.zip`);
  await fs.promises.writeFile(filePath, Buffer.from(await res.arrayBuffer()));
  const { size } = fs.statSync(filePath);

  await i.editReply(
    `✅ **${macro}** updated — ${(size / 1024).toFixed(1)} KB`
  );
});

client.login(TOKEN);
