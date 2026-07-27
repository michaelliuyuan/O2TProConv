// postproc_decode.js — Convert DECODE() to CASE WHEN
// Replace '' with placeholder to avoid quote-state issues, then convert
const fs = require('fs');
let input = fs.readFileSync(process.argv[2], 'utf8');

// Replace '' (escaped quotes) with a placeholder that won't interfere with quote tracking
const PLACEHOLDER = '\x01';
input = input.split("''").join(PLACEHOLDER);

const lines = input.split('\n');

function matchParen(s, op) {
  let depth = 0, inStr = false;
  for (let i = op; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (c === "'") inStr = false; continue; }
    if (c === "'") { inStr = true; continue; }
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

function splitTopComma(s) {
  const result = [];
  let depth = 0, inStr = false, cur = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) { cur += c; if (c === "'") inStr = false; continue; }
    if (c === "'") { inStr = true; cur += c; continue; }
    if (c === '(') { depth++; cur += c; continue; }
    if (c === ')') { depth--; cur += c; continue; }
    if (c === ',' && depth === 0) { result.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  result.push(cur.trim());
  return result;
}

function convDecode(line) {
  let out = '';
  while (true) {
    const m = line.match(/[Dd][Ee][Cc][Oo][Dd][Ee][ \t]*\(/);
    if (!m) { out += line; break; }
    const pos = m.index;
    if (pos > 0 && /[A-Za-z0-9_]/.test(line[pos-1])) { out += line.substring(0, pos + 1); line = line.substring(pos + 1); continue; }
    const cpos = pos + m[0].length - 1;
    const epos = matchParen(line, cpos);
    if (epos < 0) { out += line; break; }
    const mid = line.substring(cpos + 1, epos);
    const parts = splitTopComma(mid);
    if (parts.length < 3) { out += line.substring(0, epos + 1); line = line.substring(epos + 1); continue; }
    const expr = parts[0];
    let cs = 'CASE';
    let i = 1;
    while (i + 1 <= parts.length - 1) { cs += ' WHEN ' + expr + ' <=> ' + parts[i] + ' THEN ' + parts[i+1]; i += 2; }
    if (i <= parts.length - 1) cs += ' ELSE ' + parts[i];
    cs += ' END';
    out += line.substring(0, pos) + cs;
    line = line.substring(epos + 1);
  }
  return out;
}

function hasUnclosedDecode(line) {
  const m = line.match(/[Dd][Ee][Cc][Oo][Dd][Ee][ \t]*\(/);
  if (!m) return false;
  if (m.index > 0 && /[A-Za-z0-9_]/.test(line[m.index-1])) return false;
  return matchParen(line, m.index + m[0].length - 1) < 0;
}

let pending = '';
let output = '';
for (const line of lines) {
  if (line.match(/^[ \t]*--/)) {
    if (pending) { output += convDecode(pending) + '\n'; pending = ''; }
    output += line + '\n';
    continue;
  }
  if (pending) pending += ' ' + line;
  else pending = line;
  if (!hasUnclosedDecode(pending)) {
    output += convDecode(pending) + '\n';
    pending = '';
  }
}
if (pending) output += convDecode(pending) + '\n';

// Restore '' placeholders
output = output.split(PLACEHOLDER).join("''");
process.stdout.write(output);
