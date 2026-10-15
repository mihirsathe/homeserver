#!/usr/bin/env node
// patch-watchlist-one-season.js — Seerr: a Plex Watchlist add requests ONE season.
//
// Run at image build time (see Dockerfile) against Seerr's compiled
// /app/dist/entity/MediaRequest.js. Edits exactly one spot and refuses to
// build if that spot is not there, so an upstream refactor fails the monthly
// update loudly instead of silently restoring the old behaviour.
//
// WHY: Plex's Watchlist stores the SHOW, never a season — verified 2026-10-08
// against discover.provider.plex.tv (REST), its per-season children with
// user state, and community.plex.tv (GraphQL): all three return the bare
// show, and the seasons carry no watchlistedAt. Seerr's watchlist sync then
// requests `seasons: 'all'` (server/lib/watchlistsync.ts), which turned one
// tap on Survivor into a 51-season / 806-episode Sonarr request. Upstream has
// the ask open since 2025 (seerr-team/seerr#1351, #1385 closed as dup,
// PR #2752 closed unmerged); nothing merged, so we carry it here.
//
// WHAT: in MediaRequest.request(), after Seerr has computed `finalSeasons`
// (the requested seasons minus those already requested/available) and ONLY
// for watchlist auto-requests (`options.isAutoRequest` with `seasons: 'all'`),
// trim the list to one season:
//   - show currently airing (TMDB lists a next episode, or the last episode
//     aired within 30 days)  → the season that episode belongs to, or the
//     first missing season at/after it;
//   - otherwise               → the earliest missing season.
//   If the chosen season is already in the library the list becomes empty and
//   Seerr's own NoSeasonsAvailableError path takes over (debug log, no
//   request) — exactly what it already does for fully-available titles.
// Later seasons of a show Sonarr holds arrive via its "Monitor New Items:
// all" default (every series on this box is set to it), so following a show
// still works without a second watchlist action. Manual requests in Seerr's
// UI are untouched: they never carry isAutoRequest.
//
// Usage: node patch-watchlist-one-season.js /app/dist/entity/MediaRequest.js
'use strict';
const fs = require('fs');

const MARKER = 'HOMESERVER-PATCH watchlist-one-season';
const target = process.argv[2];
if (!target) {
  console.error('usage: patch-watchlist-one-season.js <path to dist/entity/MediaRequest.js>');
  process.exit(2);
}

let src = fs.readFileSync(target, 'utf8');
if (src.includes(MARKER)) {
  console.log(`already patched: ${target}`);
  process.exit(0);
}

// Every identifier the patch leans on must be present in the compiled file,
// named exactly as below. Checked one by one so a failure names what moved.
const anchors = {
  signature: 'static async request(requestBody, user, options = {}) {',
  tmdbShow: 'const tmdbMediaShow = tmdbMedia;',
  allSeasons: "let requestedSeasons = requestBody.seasons === 'all'",
  finalSeasons: 'const finalSeasons = requestedSeasons.filter((rs) => !existingSeasons.includes(rs));',
  noSeasons: 'if (finalSeasons.length === 0) {',
  logger: 'const logger_1 = __importDefault(require("../logger"));',
};
const missing = Object.entries(anchors)
  .filter(([, s]) => src.split(s).length - 1 !== 1)
  .map(([k, s]) => `${k}: ${JSON.stringify(s)}`);
if (missing.length) {
  console.error(`REFUSING TO PATCH ${target} — anchor(s) not found exactly once:\n  ${missing.join('\n  ')}`);
  console.error('Seerr upstream changed MediaRequest.request(); re-derive the patch before rebuilding.');
  process.exit(1);
}
// The empty-list check must directly follow the finalSeasons line: the patch
// is inserted between them and relies on nothing else having been computed.
const seq = `${anchors.finalSeasons}\n            ${anchors.noSeasons}`;
if (src.split(seq).length - 1 !== 1) {
  console.error(`REFUSING TO PATCH ${target} — finalSeasons/length-check lines are no longer adjacent`);
  process.exit(1);
}

const insert = `${anchors.finalSeasons}
            // ${MARKER} — see homeserver/seerr/patch-watchlist-one-season.js
            if (options.isAutoRequest && requestBody.seasons === 'all' && finalSeasons.length > 0) {
                const hsSorted = [...finalSeasons].sort((a, b) => a - b);
                const hsLastAired = Date.parse(tmdbMediaShow.last_air_date || '') || 0;
                const hsAiring = !!tmdbMediaShow.next_episode_to_air ||
                    Date.now() - hsLastAired < 30 * 24 * 60 * 60 * 1000;
                const hsCurrent = tmdbMediaShow.last_episode_to_air?.season_number;
                const hsTarget = hsAiring && typeof hsCurrent === 'number' ? hsCurrent : hsSorted[0];
                const hsPick = hsSorted.find((sn) => sn >= hsTarget);
                logger_1.default.info('Watchlist auto-request trimmed to one season', {
                    label: 'Media Request',
                    tmdbId: requestBody.mediaId,
                    airing: hsAiring,
                    season: hsPick ?? null,
                    notRequested: hsSorted.filter((sn) => sn !== hsPick),
                });
                finalSeasons.splice(0, finalSeasons.length, ...(hsPick === undefined ? [] : [hsPick]));
            }
            ${anchors.noSeasons}`;
src = src.replace(seq, insert);
fs.writeFileSync(target, src);
console.log(`patched: ${target}`);
