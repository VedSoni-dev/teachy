#!/usr/bin/env node
// Builds academy/skillmarket/index.json from the skill files in academy/skillmarket/skills/.
// The Teachy app and the /skillmarket page both read index.json. Run after adding or
// changing a skill: `node scripts/build-skillmarket.mjs` (add --check to fail if it's stale).
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const marketDirectory = join(root, "academy", "skillmarket");
const skillsDirectory = join(marketDirectory, "skills");
const indexPath = join(marketDirectory, "index.json");
const checkOnly = process.argv.includes("--check");
const maximumBytes = 32 * 1024;
const validID = /^[a-z0-9]+(-[a-z0-9]+)*$/;

// The same small front-matter rules as SkillParser.frontMatter in the app.
function frontMatter(text) {
  const lines = text.replace(/\r\n?/g, "\n").replace(/^﻿/, "").split("\n");
  while (lines.length && lines[0].trim() === "") lines.shift();
  if (lines[0]?.trim() !== "---") return null;
  const end = lines.indexOf("---", 1);
  if (end < 0) return null;
  const fields = {};
  let openList = null;
  const unquote = (value) => value.trim().replace(/^(["'])(.*)\1$/, "$2");
  for (const raw of lines.slice(1, end)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("- ")) { if (openList) fields[openList].push(unquote(line.slice(2))); continue; }
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    if (!value) { openList = key; fields[key] = fields[key] ?? []; }
    else if (value.startsWith("[") && value.endsWith("]")) { openList = null; fields[key] = value.slice(1, -1).split(",").map(unquote).filter(Boolean); }
    else { openList = null; fields[key] = unquote(value); }
  }
  return fields;
}

const problems = [];
const listings = [];
for (const fileName of readdirSync(skillsDirectory).filter((name) => name.endsWith(".skill.md")).sort()) {
  const path = join(skillsDirectory, fileName);
  const text = readFileSync(path, "utf8");
  const fields = frontMatter(text);
  const where = `skills/${fileName}`;
  if (!fields) { problems.push(`${where}: no front matter`); continue; }
  const id = fields.id;
  if (Buffer.byteLength(text) > maximumBytes) problems.push(`${where}: larger than 32 KB`);
  if (!id || !validID.test(id) || id.length > 64) problems.push(`${where}: id must be lowercase letters, digits and hyphens`);
  if (id && fileName !== `${id}.skill.md`) problems.push(`${where}: file must be named ${id}.skill.md`);
  for (const required of ["name", "version", "author", "summary"]) if (!fields[required]) problems.push(`${where}: missing ${required}`);
  const bundleIds = Array.isArray(fields.bundleids) ? fields.bundleids : [];
  const sites = Array.isArray(fields.sites) ? fields.sites : [];
  if (!bundleIds.length && !sites.length) problems.push(`${where}: needs bundleIds or sites`);
  if (listings.some((listing) => listing.id === id)) problems.push(`${where}: duplicate id ${id}`);
  const apps = [fields.name, ...sites.map((site) => site.split("/")[0])].filter((value, position, all) => all.indexOf(value) === position);
  const listing = { id, name: fields.name, summary: fields.summary, author: fields.author, version: fields.version, file: `skills/${fileName}`, apps };
  if (fields.authorurl) listing.authorURL = fields.authorurl;
  if (fields.category) listing.category = fields.category;
  // Shown on the library's detail pane (the app and the site).
  if (fields.icon) listing.icon = fields.icon;
  if (fields.headline) listing.headline = fields.headline;
  if (fields.description) listing.description = fields.description;
  if (Array.isArray(fields.goodfor) && fields.goodfor.length) listing.goodFor = fields.goodfor;
  if (Array.isArray(fields.highlights) && fields.highlights.length) listing.highlights = fields.highlights;
  if (fields.added) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fields.added)) problems.push(`${where}: added must be YYYY-MM-DD`);
    listing.added = fields.added;
  }
  listings.push(listing);
}

if (problems.length) {
  console.error(problems.map((problem) => `✗ ${problem}`).join("\n"));
  process.exit(1);
}

const output = JSON.stringify({ version: 1, skills: listings.sort((a, b) => a.name.localeCompare(b.name)) }, null, 2) + "\n";
if (checkOnly) {
  const current = existsSync(indexPath) ? readFileSync(indexPath, "utf8") : "";
  if (current !== output) { console.error("✗ index.json is out of date: run node scripts/build-skillmarket.mjs"); process.exit(1); }
  console.log(`✓ index.json is current (${listings.length} skills)`);
} else {
  writeFileSync(indexPath, output);
  console.log(`✓ wrote academy/skillmarket/index.json (${listings.length} skills)`);
}
