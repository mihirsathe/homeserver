#!/usr/bin/env python3
"""
gpu-arbiter.py — hand the GPU back to Plex the moment it starts transcoding.

WHERE THIS RUNS:
  Inside the `gpu-arbiter` container (stock python:3.12-alpine), bind-mounted
  read-only from ${STACK_DIR}/scripts/gpu-arbiter.py. Stdlib only — the same
  constraint generate-configs.py and bootstrap.py carry, so there is no image
  to build and nothing to keep patched beyond the base image.

WHAT IT DOES:
  Polls Plex's /status/sessions every POLL_INTERVAL seconds and counts
  sessions that are actually re-encoding video (videoDecision="transcode").
  On the first such session it:

    1. Creates HOLD_FILE. `ollama-gate` (Caddy) matches on that file existing
       and answers 503 + Retry-After to every endpoint that could pull a model
       onto the GPU. This is the part that matters — it stops the *next*
       request from re-loading a model behind our back.
    2. Asks Ollama to evict whatever is resident in VRAM (POST /api/generate
       with keep_alive=0), freeing it in about a second.

  When the last transcode has been gone for RELEASE_DELAY seconds it removes
  HOLD_FILE and inference resumes. The delay is hysteresis: back-to-back
  episodes in a binge would otherwise flap the hold open and closed between
  every file.

WHY POLL PLEX AND NOT nvidia-smi:
  Device-level NVENC session counters are unreliable on GeForce parts and tell
  you the encoder is *already* running. Plex's session list is authoritative,
  distinguishes a real re-encode from a Direct Play / Direct Stream (neither of
  which touches the encoder), and is the same API Tautulli reads.

FAILURE POSTURE — deliberately fails OPEN, not closed:
  No PLEX_TOKEN, Plex unreachable, or a malformed response ⇒ no hold. Ollama
  keeps serving. This is safe because the hold is only the *fourth* layer
  protecting Plex; the first three are static and always in force:

    1. OLLAMA_GPU_OVERHEAD reserves VRAM that Ollama will never allocate.
    2. OLLAMA_MAX_LOADED_MODELS / NUM_PARALLEL / CONTEXT_LENGTH bound the
       footprint of whatever does get loaded.
    3. OLLAMA_KEEP_ALIVE evicts idle models on its own.

  Failing closed would mean a dead Plex token silently bricks local AI for
  every container on the stack, to protect against a contention case layers
  1–3 already cover. See docs/decisions.md.

  A stale hold left behind by an unclean stop is cleared on startup, and the
  SIGTERM/SIGINT handlers release it on the way out.

ENVIRONMENT (all optional except PLEX_TOKEN; defaults match docker-compose.yml):
  PLEX_URL         http://plex:32400
  PLEX_TOKEN       from generated.env — written by bootstrap.py
  OLLAMA_URL       http://ollama:11434   (the engine, NOT the gate — the
                                          arbiter must be able to evict models
                                          while the gate is 503ing everyone)
  HOLD_FILE        /gate-state/hold
  HEARTBEAT_FILE   /gate-state/heartbeat  (mtime drives the healthcheck)
  POLL_INTERVAL    5    seconds between Plex polls
  RELEASE_DELAY    60   seconds a transcode must be gone before releasing
  HTTP_TIMEOUT     5    seconds per Plex/Ollama request
  WARN_EVERY       300  seconds between repeats of a sticky warning
"""

import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def _str(key: str, default: str) -> str:
    return os.environ.get(key, "").strip() or default


def _int(key: str, default: int) -> int:
    raw = os.environ.get(key, "").strip()
    if not raw:
        return default
    try:
        return max(1, int(raw))
    except ValueError:
        print(f"WARN: {key}={raw!r} is not an integer — using {default}")
        return default


PLEX_URL = _str("PLEX_URL", "http://plex:32400").rstrip("/")
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "").strip()
OLLAMA_URL = _str("OLLAMA_URL", "http://ollama:11434").rstrip("/")
HOLD_FILE = Path(_str("HOLD_FILE", "/gate-state/hold"))
HEARTBEAT_FILE = Path(_str("HEARTBEAT_FILE", "/gate-state/heartbeat"))
POLL_INTERVAL = _int("POLL_INTERVAL", 5)
RELEASE_DELAY = _int("RELEASE_DELAY", 60)
HTTP_TIMEOUT = _int("HTTP_TIMEOUT", 5)
WARN_EVERY = _int("WARN_EVERY", 300)

# An eviction can block behind an in-flight generation, so it gets its own
# generous timeout and runs off the poll loop (see _evict_async).
EVICT_TIMEOUT = 120


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S%z')}] {msg}", flush=True)


_last_warned: dict[str, float] = {}


def warn_once(key: str, msg: str) -> None:
    """Log a sticky condition at most once per WARN_EVERY seconds.

    Plex being unreachable is a per-poll event; at a 5s interval that would be
    720 identical lines an hour in `docker logs`.
    """
    now = time.monotonic()
    if now - _last_warned.get(key, -WARN_EVERY) >= WARN_EVERY:
        _last_warned[key] = now
        log(msg)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def _get(url: str, headers: dict | None = None, timeout: int = HTTP_TIMEOUT) -> bytes:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _post_json(url: str, payload: dict, timeout: int) -> bytes:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


# ---------------------------------------------------------------------------
# Plex
# ---------------------------------------------------------------------------
def count_video_transcodes() -> int | None:
    """Active sessions re-encoding video, or None if Plex couldn't be asked.

    Only videoDecision="transcode" counts. Direct Play and Direct Stream never
    touch NVENC, and an audio-only transcode is a CPU job. Sessions flagged
    complete="1" have finished encoding but linger in the list for a while —
    counting them would hold the GPU long after the encoder went idle.
    """
    if not PLEX_TOKEN:
        warn_once(
            "no-token",
            "WARN: PLEX_TOKEN is empty — cannot see Plex sessions, so the GPU "
            "hold will never engage. Run bootstrap.py, then "
            "`docker compose --env-file .env.docker up -d gpu-arbiter`.",
        )
        return None

    try:
        body = _get(
            f"{PLEX_URL}/status/sessions",
            {"X-Plex-Token": PLEX_TOKEN, "Accept": "application/xml"},
        )
    except urllib.error.HTTPError as e:
        if e.code == 401:
            warn_once("plex-401", "WARN: Plex rejected PLEX_TOKEN (401) — rotate it per docs/operations.md.")
        else:
            warn_once("plex-http", f"WARN: Plex /status/sessions returned HTTP {e.code}")
        return None
    except (urllib.error.URLError, OSError) as e:
        warn_once("plex-net", f"WARN: Plex unreachable at {PLEX_URL} ({e}) — assuming idle.")
        return None

    try:
        root = ET.fromstring(body)
    except ET.ParseError as e:
        warn_once("plex-xml", f"WARN: could not parse Plex session XML ({e}) — assuming idle.")
        return None

    return sum(
        1
        for ts in root.iter("TranscodeSession")
        if ts.get("complete") != "1"
        and (ts.get("videoDecision") or "").lower() == "transcode"
    )


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------
def _resident_models() -> list[str]:
    """Models currently holding VRAM, per /api/ps.

    size_vram==0 means the model is resident in system RAM only (Ollama fell
    back to CPU because it didn't fit). Evicting those buys Plex nothing and
    would throw away a warm model for no reason.
    """
    raw = _get(f"{OLLAMA_URL}/api/ps")
    models = json.loads(raw).get("models") or []
    return [
        name
        for m in models
        if (name := m.get("model") or m.get("name")) and (m.get("size_vram") or 0) > 0
    ]


def _evict() -> None:
    try:
        resident = _resident_models()
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError) as e:
        log(f"WARN: could not read Ollama /api/ps ({e}) — skipping eviction.")
        return

    if not resident:
        log("  no models resident in VRAM — nothing to evict")
        return

    for name in resident:
        try:
            # An empty prompt with keep_alive=0 is Ollama's documented unload
            # path: it returns as soon as the model is dropped, without
            # generating. It can still block behind a generation already in
            # flight for the same model, which is why this runs off-loop.
            _post_json(
                f"{OLLAMA_URL}/api/generate",
                {"model": name, "prompt": "", "keep_alive": 0},
                timeout=EVICT_TIMEOUT,
            )
            log(f"  evicted {name} from VRAM")
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
            log(f"  WARN: failed to evict {name} ({e})")


_evicting = threading.Lock()


def _evict_async() -> None:
    """Run an eviction in the background if one isn't already running.

    The hold file is written before this is called, so new requests are
    already being turned away; eviction is cleanup of what's already resident
    and must not stall the poll loop behind an in-flight generation.
    """
    if not _evicting.acquire(blocking=False):
        log("  eviction already in progress — not starting another")
        return

    def run() -> None:
        try:
            _evict()
        finally:
            _evicting.release()

    threading.Thread(target=run, name="evict", daemon=True).start()


# ---------------------------------------------------------------------------
# Hold file
# ---------------------------------------------------------------------------
def engage_hold() -> None:
    """Create the hold file, then evict. Order matters — see module docstring."""
    tmp = HOLD_FILE.with_suffix(".tmp")
    tmp.write_text(f"held since {time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n")
    # Atomic rename so Caddy's file matcher never observes a half-written file.
    tmp.replace(HOLD_FILE)


def release_hold() -> None:
    HOLD_FILE.unlink(missing_ok=True)


def heartbeat() -> None:
    HEARTBEAT_FILE.touch()


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
_stop = threading.Event()


def _on_signal(signum, _frame) -> None:
    log(f"Received signal {signum} — releasing hold and exiting.")
    _stop.set()


def main() -> None:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    HOLD_FILE.parent.mkdir(parents=True, exist_ok=True)

    log("gpu-arbiter starting")
    log(f"  plex={PLEX_URL}  ollama={OLLAMA_URL}")
    log(f"  poll={POLL_INTERVAL}s  release_delay={RELEASE_DELAY}s  hold_file={HOLD_FILE}")
    log(f"  plex_token={'set' if PLEX_TOKEN else 'MISSING — hold will never engage'}")

    # A hold left over from an unclean stop would 503 every inference request
    # forever, since nothing else on the stack ever removes this file.
    if HOLD_FILE.exists():
        log("Clearing stale hold file from a previous run.")
        release_hold()

    holding = False
    last_busy = 0.0

    while not _stop.is_set():
        try:
            heartbeat()
            transcodes = count_video_transcodes()
            busy = bool(transcodes)  # None (unknown) and 0 both mean "not busy"

            if busy:
                last_busy = time.monotonic()
                if not holding:
                    log(f"Plex started transcoding ({transcodes} session(s)) — yielding GPU.")
                    engage_hold()
                    holding = True
                    _evict_async()
            elif holding:
                idle_for = time.monotonic() - last_busy
                if idle_for >= RELEASE_DELAY:
                    log(f"No video transcode for {int(idle_for)}s — releasing GPU back to Ollama.")
                    release_hold()
                    holding = False
        except Exception as e:  # noqa: BLE001 — the loop must outlive any single failure
            log(f"ERROR: unexpected failure in poll loop ({e!r}) — continuing.")

        _stop.wait(POLL_INTERVAL)

    release_hold()
    log("gpu-arbiter stopped, hold released.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        release_hold()
        sys.exit(0)
