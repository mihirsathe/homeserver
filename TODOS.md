# TODOS — post-audit remediation tail (2026-08-29)

Working list left over from the August 2026 audit remediation. Everything the
audit found that *could* be fixed from the box is done and verified
(`verify-stack.sh`: 82 passed / 0 failed / 1 warning). What remains needs a
credential, a decision, or time to pass. Delete lines as they land.

## Needs a credential (Mihir)

- [ ] **`BACKUP_REMOTE`** — rclone remote (B2 or similar) for the weekly
      appdata offsite leg. `rclone config` on the box, set the value in
      `homeserver/.env`. The Sunday 5:00 `media_stack_backup` script picks it
      up automatically; verify the first offsite copy the following Monday.
- [ ] **`BACKUP_NEXTCLOUD_REMOTE`** — same, for Nextcloud user files. This is
      the ONLY backup those files get. **Hard rule: no real files into
      Nextcloud until this is set** (deployment.md says the same).
- [ ] **`LICHESS_TOKEN`** — chess-coach runs without Lichess access. Mint a
      token, add to `homeserver/.env`, `docker compose up -d coach`.

## Needs a decision (Mihir)

- [ ] **Plex preferences** — bootstrap's prefs step never ran (verified);
      live = Plex defaults + a few UI-set values. Either re-run the step to
      enforce PR #24's set (turns Relay OFF, preset back to `veryfast`,
      enables BIF/chapter thumbnails + 3am scan) or bless the current state
      and trim `apply_plex_preferences` in bootstrap.py. NVENC is fine either
      way (on by default in this Plex version).
- [ ] **Slack `normal`-importance routing** — warnings/alerts go to Slack
      (`#dellbox-alerts` via the DellBox app webhook); `normal` events
      (parity finished clean, array started) are GUI-only. Flip
      `normal="1"` → `normal="5"` in `[notify]` in
      `/boot/config/plugins/dynamix/dynamix.cfg` to see the good news too.
- [ ] **NZBPlanet stays parked** (decided 2026-08-29). Remember: a full
      `bootstrap.py` re-run WOULD re-add it (`bootstrap.py:494`) — if the
      Plex prefs decision above is "re-run bootstrap", run only the prefs
      step or delete the indexer again after.

## Merge queue

- [ ] **homeserver PR #30** — audit docs alignment + verify-stack rework +
      P2 cleanup + Nextcloud deploy flips + this file.
- [ ] **claudecoach PR #1** — Docker README fix, Slack `app.action(None)`
      fix, ai-network compose change. The running container was built FROM
      this branch; merging changes nothing on the box.
- [ ] claudecoach `docker/.env` is deliberately uncommitted (box-local:
      channel/calendar IDs). Recreate from the deployment brief if ever lost.

## Nextcloud go-live (in order)

- [ ] Padlock test from an admin device: `https://nextcloud.tail9f0cb1.ts.net/`
- [ ] Log in (`admin` / `grep ^NEXTCLOUD_ADMIN_PASSWORD= generated.env`),
      change or record the password.
- [ ] Administration → Overview: expect the four greens listed in
      deployment.md (§ Nextcloud first-run).
- [ ] Set `BACKUP_NEXTCLOUD_REMOTE` (above) → then install desktop/mobile
      clients and start putting real files in.

## ClaudeCoach (owner's checklist, from RUNBOOK "Going live")

- [ ] Conversational E2E: say `plan 7` in `#coachchat` — listener should
      answer (it is connected and stable since the action-matcher fix).
- [ ] Shadow night 1 fires 2026-08-29 21:00. Next morning check:
      `docker exec claudecoach coach health` shows `last_run` ok; a
      `[SHADOW]` workout in Garmin Connect; an event on the `Lifting`
      calendar; Slack summary with buttons in `#coachchat`.
- [ ] Seven consecutive clean shadow nights → then the RUNBOOK "Going live"
      cutover (owner's call; never unset `COACH_SHADOW_MODE` before that).
- [ ] Remaining live-device work: CCFIX workouts, course-write smoke test
      (the gate ships closed until then).

## Watch for (time passes)

- [ ] **Sep 1, 03:00** — first scheduled parity check in ~4 months. Expect a
      result notification (GUI; Slack too if `normal` flipped). 0 errors.
- [ ] **Sunday** — first full scheduled backup cycle: plugin 04:00, verify
      script 05:00. Check `/mnt/user/backups/appdata/` for a fresh `ab_*`
      dir and `/var/log/homeserver/backup.log` for a clean verify pass.
- [ ] **Next reboot** — `restore_tools` User Script should re-link `gh` and
      its auth config and re-run `gh auth setup-git`. Verify `gh auth status`
      afterwards.

## Hygiene (low, eventually)

- [ ] The GitHub fine-grained PAT and the Slack webhook URL both transited
      the Claude session transcript. Fine for a homelab; rotate if that ever
      bothers you (PAT: github settings; webhook: delete + re-add in the
      DellBox Slack app).
- [ ] iDRAC NIC wording in hardware.md says "shared LOM (verify)" — confirm
      physically or via iDRAC UI and drop the "(verify)".
- [ ] Delete `/mnt/user/appdata/claudecoach-deploy_key{,.pub}` — superseded
      by the PAT (never added to GitHub).
