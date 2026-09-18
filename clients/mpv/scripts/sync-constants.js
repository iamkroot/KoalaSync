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

// ── Extract object dictionary constants ─────────────────────────
function extractObject(name) {
    const block = src.match(new RegExp(`export\\s+const\\s+${name}\\s*=\\s*\\{([\\s\\S]*?)\\};`));
    if (!block) return [];
    const entries = [];
    for (const line of block[1].split('\n')) {
        const m = line.match(/^\s*(\w+)\s*:\s*['"]([^'"]+)['"]/);
        if (m) entries.push([m[1], m[2]]);
    }
    return entries;
}

function toZigIdent(key) {
    const name = key.toLowerCase().replace(/-/g, '_');
    const keywords = ['error', 'export', 'pub', 'const', 'var', 'type', 'fn'];
    return keywords.includes(name) ? `@"${name}"` : name;
}

function buildStruct(structName, doc, entries) {
    const res = [
        `/// ${doc}`,
        `pub const ${structName} = struct {`,
    ];
    for (const [key, value] of entries) {
        const ident = toZigIdent(key);
        res.push(`    pub const ${ident} = "${value}";`);
    }
    res.push('};');
    return res;
}

// ── Build Zig source ────────────────────────────────────────────
const events = extractObject('EVENTS');
const capabilities = extractObject('CAPABILITIES');
const controlModes = extractObject('CONTROL_MODES');
const errorCodes = extractObject('ERROR_CODES');

const forceSyncTimeout = extractNum('FORCE_SYNC_TIMEOUT') || 8500;
const forceSyncTargetDelayWarning = forceSyncTimeout + 2000;

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
    `pub const max_media_time: f64 = ${extractNum('MAX_MEDIA_TIME') || 86400};`,
    `pub const heartbeat_interval_ms: u64 = ${extractNum('HEARTBEAT_INTERVAL')};`,
    `pub const force_sync_timeout_ms: u64 = ${forceSyncTimeout};`,
    `pub const force_sync_target_delay_warning_ms: u64 = ${forceSyncTargetDelayWarning};`,
    `pub const episode_lobby_timeout_ms: u64 = ${extractNum('EPISODE_LOBBY_TIMEOUT')};`,
    `pub const episode_sync_v2_load_timeout_ms: u64 = ${extractNum('EPISODE_SYNC_V2_LOAD_TIMEOUT') || 120000};`,
    `pub const episode_sync_v2_prepare_timeout_ms: u64 = ${extractNum('EPISODE_SYNC_V2_PREPARE_TIMEOUT') || 15000};`,
    `pub const episode_sync_v2_execute_timeout_ms: u64 = ${extractNum('EPISODE_SYNC_V2_EXECUTE_TIMEOUT') || 10000};`,
    `pub const episode_sync_v2_stability_ms: u64 = ${extractNum('EPISODE_SYNC_V2_STABILITY_MS') || 1000};`,
    '',
    ...buildStruct('events', 'Socket.IO event names — mirrors shared/constants.js EVENTS.', events),
    '',
    ...buildStruct('capabilities', 'Server capability flags — mirrors shared/constants.js CAPABILITIES.', capabilities),
    '',
    ...buildStruct('control_modes', 'Room control modes — mirrors shared/constants.js CONTROL_MODES.', controlModes),
    '',
    ...buildStruct('error_codes', 'Stable server error identifiers — mirrors shared/constants.js ERROR_CODES.', errorCodes),
    '',
];

writeFileSync(OUTPUT, lines.join('\n'));
console.log(`✓ Generated ${OUTPUT}`);
