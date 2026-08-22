#!/usr/bin/env node
/**
 * sync-constants.js
 *
 * Reads shared/constants.js and generates src/constants.zig so the mpv
 * cplugin uses the same protocol values as the browser extension and
 * relay server.
 *
 * Usage:  node clients/mpv/scripts/sync-constants.js
 * (run from the repository root)
 */

import { readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SHARED = join(__dirname, '..', '..', '..', 'shared', 'constants.js');
const OUTPUT = join(__dirname, '..', 'src', 'constants.zig');

const src = readFileSync(SHARED, 'utf8');

// ── Extract simple string/number constants ──────────────────────
function extract(name) {
    const re = new RegExp(`export\\s+const\\s+${name}\\s*=\\s*['"\`](.+?)['"\`]`);
    const m = src.match(re);
    return m ? m[1] : null;
}
function extractNum(name) {
    const re = new RegExp(`export\\s+const\\s+${name}\\s*=\\s*(\\d+)`);
    const m = src.match(re);
    return m ? Number(m[1]) : null;
}

// ── Extract EVENTS object ───────────────────────────────────────
function extractEvents() {
    const block = src.match(/export\s+const\s+EVENTS\s*=\s*\{([\s\S]*?)\};/);
    if (!block) throw new Error('Could not find EVENTS in shared/constants.js');
    const entries = [];
    for (const line of block[1].split('\n')) {
        const m = line.match(/^\s*(\w+)\s*:\s*"([^"]+)"/);
        if (m) entries.push([m[1], m[2]]);
    }
    return entries;
}

// ── Build Zig source ────────────────────────────────────────────
const events = extractEvents();
const lines = [
    '// AUTO-GENERATED from shared/constants.js — do not edit manually.',
    '// Run:  node clients/mpv/scripts/sync-constants.js',
    '//',
    `// Generated at: ${new Date().toISOString()}`,
    '',
    `pub const protocol_version = "${extract('PROTOCOL_VERSION')}";`,
    `pub const app_version = "${extract('APP_VERSION')}";`,
    `pub const official_server_url = "${extract('OFFICIAL_SERVER_URL')}";`,
    `pub const official_server_token = "${extract('OFFICIAL_SERVER_TOKEN')}";`,
    '',
    `pub const heartbeat_interval_ms: u64 = ${extractNum('HEARTBEAT_INTERVAL')};`,
    `pub const force_sync_timeout_ms: u64 = ${extractNum('FORCE_SYNC_TIMEOUT')};`,
    `pub const episode_lobby_timeout_ms: u64 = ${extractNum('EPISODE_LOBBY_TIMEOUT')};`,
    '',
    '/// Socket.IO event names — mirrors shared/constants.js EVENTS.',
    'pub const events = struct {',
];

for (const [key, value] of events) {
    const zigName = key.toLowerCase();
    // "error" is a Zig keyword — use @"error" syntax.
    const ident = zigName === 'error' ? '@"error"' : zigName;
    lines.push(`    pub const ${ident} = "${value}";`);
}

lines.push('};');
lines.push('');

writeFileSync(OUTPUT, lines.join('\n'));
console.log(`✓ Generated ${OUTPUT}`);
