#!/usr/bin/env bash
# =============================================================================
#  mostly-a-SDR :: remote-control API  —  one-file installer
#  ---------------------------------------------------------------------------
#  Adds an HTTP/JSON API, a phone-friendly web UI and a native Android app
#  source tree to  https://github.com/pinchepasta/mostly-a-SDR
#
#  Usage:
#     ./one-file-installer.sh                 install everything (deps, API, service, android src)
#     ./one-file-installer.sh --port 9000     different port
#     ./one-file-installer.sh --no-deps       skip rpitx-ui build (tools already present)
#     ./one-file-installer.sh --token abc     fixed API token
#     ./one-file-installer.sh --new-token     rotate the token
#     ./one-file-installer.sh --update        refresh app files, keep config/token
#     ./one-file-installer.sh --uninstall     remove everything this script made
#
#  Everything it writes lives in: /opt/mostly-a-sdr-api, /etc/mostly-a-sdr,
#  /var/log/mostly-a-sdr, /etc/systemd/system/mostly-a-sdr-api.service
# =============================================================================
set -euo pipefail

APP_NAME="mostly-a-sdr-api"
API_VERSION="1.0.0"
REPO_URL="${MASDR_REPO:-https://github.com/pinchepasta/mostly-a-SDR}"
OPT_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/mostly-a-sdr"
CONF_FILE="${CONF_DIR}/api.json"
LOG_DIR="/var/log/mostly-a-sdr"
WORK_DIR="/var/tmp/mostly-a-sdr"
UNIT="/etc/systemd/system/${APP_NAME}.service"
AVAHI_SVC="/etc/avahi/services/${APP_NAME}.service"
SUDOERS="/etc/sudoers.d/mostly-a-sdr"
PORT=8765
BIND="0.0.0.0"
TOKEN=""
REPO_DIR="${HOME}/mostly-a-SDR"
DO_DEPS=1
DO_SERVICE=1
DO_ANDROID=1
DO_UNINSTALL=0
NEW_TOKEN=0

C_G=$'\033[1;32m'; C_P=$'\033[1;35m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
say()  { printf '%s\n' "${C_G}▓▒░${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[!]${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[x]${C_0} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--port)      PORT="$2"; shift 2 ;;
		--bind)      BIND="$2"; shift 2 ;;
		--token)     TOKEN="$2"; shift 2 ;;
		--dir)       REPO_DIR="$2"; shift 2 ;;
		--repo)      REPO_URL="$2"; shift 2 ;;
		--no-deps)   DO_DEPS=0; shift ;;
		--no-service) DO_SERVICE=0; shift ;;
		--no-android) DO_ANDROID=0; shift ;;
		--new-token) NEW_TOKEN=1; shift ;;
		--update)    DO_DEPS=0; DO_SERVICE=0; shift ;;
		--uninstall) DO_UNINSTALL=1; shift ;;
		-h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
command -v python3 >/dev/null || die "python3 is required"
command -v systemctl >/dev/null || warn "systemd not found - service step may fail"

# -----------------------------------------------------------------------------
#  1. dependencies + the upstream toolkit
# -----------------------------------------------------------------------------
install_deps() {
	say "installing OS packages"
	$SUDO apt-get update -qq
	$SUDO apt-get install -y --no-install-recommends \
		git ca-certificates python3 curl \
		whiptail imagemagick ffmpeg rtl-sdr qrencode avahi-daemon
	# build deps the upstream installer needs (idempotent, cheap if present)
	$SUDO apt-get install -y --no-install-recommends \
		build-essential cmake pkg-config libfftw3-dev libsndfile1-dev \
		libsoxr-dev libcli11-dev buffer || true
}

install_upstream() {
	if [ -x /usr/bin/testvfo.sh ] && [ -x /usr/bin/testsub.sh ]; then
		say "rpitx-ui tools already present - skipping build (use --force by deleting /usr/bin/testvfo.sh)"
		return 0
	fi
	if [ -d "${REPO_DIR}/.git" ]; then
		say "updating ${REPO_DIR}"
		git -C "${REPO_DIR}" pull --ff-only || true
	else
		say "cloning ${REPO_URL} -> ${REPO_DIR}"
		git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
	fi
	[ -x "${REPO_DIR}/install.sh" ] || die "no install.sh in ${REPO_DIR}"
	say "building rpitx-ui (this takes a while on a Pi 3)"
	chmod +x "${REPO_DIR}/install.sh"
	( cd "${REPO_DIR}" && yes n | ./install.sh ) || warn "upstream installer returned non-zero (usually the reboot prompt)"
}

# -----------------------------------------------------------------------------
#  2. directories + config
# -----------------------------------------------------------------------------
prepare_dirs() {
	$SUDO mkdir -p "${OPT_DIR}/web" "${OPT_DIR}/android" "${CONF_DIR}" "${LOG_DIR}" "${WORK_DIR}"
	$SUDO chmod 750 "${CONF_DIR}"
}

write_config() {
	local tok="$TOKEN"
	if [ -z "$tok" ]; then
		if [ -f "$CONF_FILE" ] && [ "$NEW_TOKEN" -eq 0 ]; then
			tok="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('token',''))" "$CONF_FILE" 2>/dev/null || true)"
		fi
		[ -n "$tok" ] || tok="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
	fi
	[ -f "$CONF_FILE" ] && $SUDO cp -f "$CONF_FILE" "${CONF_FILE}.bak"
	$SUDO tee "$CONF_FILE" >/dev/null <<JSON
{
  "bind": "${BIND}",
  "port": ${PORT},
  "token": "${tok}",
  "freq_mhz": 434.0,
  "auto_stop_seconds": 0,
  "stop_before_start": true,
  "max_upload_mb": 64,
  "cors_origin": "*",
  "sub_dir": "${HOME}/rpitx-ui-sub-captures",
  "media_dir": "/usr/share/rpitx-ui",
  "repo_dir": "${REPO_DIR}",
  "log_dir": "${LOG_DIR}",
  "work_dir": "${WORK_DIR}",
  "capture_dir": "${HOME}/rpitx-ui-sub-captures",
  "dvbt_cmd": "dvbt-tsrfsend.py {ts}",
  "verbose": false
}
JSON
	$SUDO chmod 640 "$CONF_FILE"
	TOKEN="$tok"
}

# -----------------------------------------------------------------------------
#  3. the API server  (pure python3 stdlib - no pip, no venv, no deps)
# -----------------------------------------------------------------------------
write_server() {
	say "writing API server"
	cat > "${OPT_DIR}/sdr_api.py" <<'PY_EOF'
#!/usr/bin/env python3
# =============================================================================
#  mostly-a-SDR :: remote API  (v1)
#  ---------------------------------------------------------------------------
#  Wraps the rpitx-ui toolkit, the RTL-SDR bridge and the FT8 helper in an
#  HTTP/JSON API so a phone (Android app or the bundled web UI) can drive the
#  Pi remotely.  Pure python3 standard library.
#
#  Auth:  Authorization: Bearer <token>   (or ?token=... / X-Token: ...)
#  Docs:  GET /api/v1/  -> machine readable endpoint + mode catalogue
# =============================================================================
from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
API = "/api/v1"
HERE = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(HERE, "web")
DEFAULT_CONFIG = os.environ.get("MASDR_CONFIG", "/etc/mostly-a-sdr/api.json")

DEFAULTS = {
    "bind": "0.0.0.0",
    "port": 8765,
    "token": "",
    "freq_mhz": 434.0,
    "auto_stop_seconds": 0,
    "stop_before_start": True,
    "max_upload_mb": 64,
    "cors_origin": "*",
    "sub_dir": "~/rpitx-ui-sub-captures",
    "media_dir": "/usr/share/rpitx-ui",
    "repo_dir": "~/mostly-a-SDR",
    "log_dir": "/var/log/mostly-a-sdr",
    "work_dir": "/var/tmp/mostly-a-sdr",
    "capture_dir": "~/rpitx-ui-sub-captures",
    "dvbt_cmd": "dvbt-tsrfsend.py {ts}",
    "verbose": False,
}

LOG_LOCK = threading.Lock()
LOG = deque(maxlen=5000)


def log(*a):
    line = time.strftime("%H:%M:%S ") + " ".join(str(x) for x in a)
    with LOG_LOCK:
        LOG.append(line)
    try:
        print(line, flush=True)
    except Exception:
        pass


def load_config(path):
    cfg = dict(DEFAULTS)
    try:
        with open(path) as fh:
            cfg.update(json.load(fh))
    except (OSError, ValueError):
        pass
    for k in ("sub_dir", "media_dir", "repo_dir", "log_dir", "work_dir", "capture_dir"):
        cfg[k] = os.path.expanduser(str(cfg.get(k) or ""))
    cfg["port"] = int(cfg.get("port") or 8765)
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(24)
    return cfg


def save_config(path, cfg):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=True)
        os.replace(tmp, path)
    except OSError as exc:
        log("config save failed:", exc)


CFG = load_config(DEFAULT_CONFIG)
USE_SUDO = os.geteuid() != 0 and shutil.which("sudo") is not None
SUDO = "sudo " if USE_SUDO else ""

DIRS = {
    "sub": CFG["sub_dir"],
    "media": CFG["media_dir"],
    "iq": CFG["work_dir"],
    "capture": CFG["capture_dir"],
    "log": CFG["log_dir"],
    "repo": CFG["repo_dir"],
}

TOOL_NAMES = [
    "testvfo.sh", "testchirp.sh", "testspectrum.sh", "snap2spectrum.sh",
    "testfmrds.sh", "testnfm.sh", "testssb.sh", "testam.sh", "testfreedv.sh",
    "testsstv.sh", "testpocsag.sh", "testopera.sh", "testrtty.sh",
    "testmorse.sh", "testrfgen.sh", "testsub.sh", "sendiq", "rtl_sdr",
    "rtl_fm", "hacktv", "ffmpeg", "pift8", "spectrumpaint", "tune",
]

for _d in set(DIRS.values()):
    try:
        os.makedirs(_d, exist_ok=True)
    except OSError:
        pass


# ---------------------------------------------------------------- helpers
def num(v):
    """Render a frequency the same way the shell menus do: 434.0 -> '434.0e6'."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    return ("%f" % f).rstrip("0").rstrip(".") + "e6"


def fq(p, ctx):
    return num(p.get("freq") or ctx.cfg["freq_mhz"])


def which(tool):
    if tool.endswith(".sh") or "/" in tool:
        return shutil.which(tool) or tool
    return shutil.which(tool) or tool


def resolve_file(name, prm):
    if not name:
        return None
    kind = prm.get("kind", "sub")
    base = DIRS.get(kind, CFG["sub_dir"])
    cand = name if os.path.isabs(name) else os.path.join(base, os.path.basename(name))
    if os.path.isfile(cand):
        return cand
    return None


def list_files(kind, exts=None):
    base = DIRS.get(kind)
    if not base or not os.path.isdir(base):
        return []
    out = []
    for n in sorted(os.listdir(base)):
        fp = os.path.join(base, n)
        if not os.path.isfile(fp):
            continue
        if exts and not any(n.lower().endswith(e.lower()) for e in exts):
            continue
        try:
            st = os.stat(fp)
        except OSError:
            continue
        out.append({"name": n, "size": st.st_size, "mtime": int(st.st_mtime), "kind": kind})
    return out


def pgrep(name):
    try:
        r = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True, timeout=5)
        return [int(x) for x in r.stdout.split()]
    except Exception:
        return []


# ---------------------------------------------------------------- mode registry
MODES = []


def add_mode(mid, label, group, params=None, builder=None, help_=""):
    MODES.append({"id": mid, "label": label, "group": group, "help": help_,
                  "params": params or [], "builder": builder})


def P(name, type_, default=None, choices=None, required=False, help_="", kind=None,
      exts=None, minv=None, maxv=None, integer=False, maxlen=None, unit=""):
    return {"name": name, "type": type_, "default": default, "choices": choices,
            "required": required, "help": help_, "kind": kind, "exts": exts,
            "min": minv, "max": maxv, "integer": integer, "maxlen": maxlen, "unit": unit}


P_FILE = lambda n, kind, exts, h: P(n, "file", None, None, True, h, kind, exts)
P_PLAY = lambda: P("playback", "choice", "loop", ["loop", "once"], False,
                   "loop = repeat forever until stopped, once = play N times")
P_FREQ = lambda: P("freq", "number", None, None, False, "override TX frequency in MHz")

# --- rpitx-ui test modes -----------------------------------------------------
add_mode("tune", "Tune (bare carrier)", "basic", [P_FREQ()],
         lambda p, c: {"argv": ["testvfo.sh", fq(p, c)]}, "Unmodulated carrier.")
add_mode("chirp", "Chirp (moving carrier)", "basic", [P_FREQ()],
         lambda p, c: {"argv": ["testchirp.sh", fq(p, c)]}, "Carrier sweeping around the frequency.")
add_mode("spectrum", "Spectrum painting", "basic",
         [P_FREQ(), P_FILE("file", "media", [".jpg"], "320x256 .jpg to paint as spectrum")],
         lambda p, c: {"argv": ["testspectrum.sh", fq(p, c), p["file"]]})
add_mode("rfmyface", "RfMyFace (camera -> RF)", "basic", [P_FREQ()],
         lambda p, c: {"argv": ["snap2spectrum.sh", fq(p, c)]},
         "Snaps the Pi camera and paints it as spectrum.")

add_mode("wfm", "WFM + RDS broadcast", "audio",
         [P_FREQ(), P_FILE("file", "media", [".aif", ".aiff", ".caf", ".flac", ".mp3", ".wav"], "audio file"),
          P_PLAY(), P("pi", "text", "0x1234", None, False, "RDS PI code (hex)"),
          P("ps", "text", "rpitx-ui", None, False, "RDS programme service, max 8 ASCII", maxlen=8),
          P("rt", "text", "mostly-a-SDR", None, False, "RDS radiotext, max 64 ASCII", maxlen=64),
          P("pe", "choice", "50", ["50", "75"], False, "FM pre-emphasis in us")],
         lambda p, c: {"argv": ["testfmrds.sh", fq(p, c), p["file"], p["playback"], p["pi"], p["ps"], p["rt"], p["pe"]]})
add_mode("nfm", "NFM voice", "audio",
         [P_FREQ(), P_FILE("file", "media", [".aif", ".aiff", ".caf", ".flac", ".mp3", ".wav"], "audio file"),
          P_PLAY(), P("deviation", "choice", "wide", ["wide", "narrow"], False, "wide = +-5 kHz, narrow = +-2.5 kHz")],
         lambda p, c: {"argv": ["testnfm.sh", fq(p, c), p["file"], p["playback"], p["deviation"]]})
add_mode("ssb", "SSB voice", "audio",
         [P_FREQ(), P_FILE("file", "media", [".aif", ".aiff", ".caf", ".flac", ".mp3", ".wav"], "audio file"),
          P_PLAY(), P("sideband", "choice", "usb", ["usb", "lsb"], False)],
         lambda p, c: {"argv": ["testssb.sh", fq(p, c), p["file"], p["playback"], p["sideband"]]})
add_mode("am", "AM", "audio",
         [P_FREQ(), P_FILE("file", "media", [".aif", ".aiff", ".caf", ".flac", ".mp3", ".wav"], "audio file"),
          P_PLAY()],
         lambda p, c: {"argv": ["testam.sh", fq(p, c), p["file"], p["playback"]]})

add_mode("freedv", "FreeDV digital voice", "digital",
         [P_FREQ(), P_FILE("file", "media", [".rf"], "FreeDV .rf file")],
         lambda p, c: {"argv": ["testfreedv.sh", fq(p, c), p["file"]]})
add_mode("sstv", "SSTV picture", "digital",
         [P_FREQ(), P_FILE("file", "media", [".jpg"], "320x256 .jpg")],
         lambda p, c: {"argv": ["testsstv.sh", fq(p, c), p["file"]]})
add_mode("pocsag", "POCSAG pager", "digital",
         [P_FREQ(), P("message", "text", "1:YOURCALL", None, True, "ADDR:MESSAGE, one per line")],
         lambda p, c: {"argv": ["testpocsag.sh", fq(p, c), p["message"]]})
add_mode("opera", "Opera beacon", "digital",
         [P_FREQ(), P("callsign", "text", "F5OEO", None, True)],
         lambda p, c: {"argv": ["testopera.sh", fq(p, c), p["callsign"]]})
add_mode("rtty", "RTTY", "digital",
         [P_FREQ(), P("message", "text", "HELLO WORLD", None, True)],
         lambda p, c: {"argv": ["testrtty.sh", fq(p, c), p["message"]]})
add_mode("cw", "CW / Morse", "digital",
         [P_FREQ(), P("message", "text", "CQ CQ DE RPITX", None, True),
          P("wpm", "number", 5, None, False, "words per minute", minv=1, maxv=60, integer=True)],
         lambda p, c: {"argv": ["testmorse.sh", fq(p, c), str(int(p["wpm"])), p["message"]]})

add_mode("rfgen", "RF generator", "basic",
         [P_FREQ(), P("mode", "choice", "noise", ["noise", "sweep", "multitone"], False),
          P("bandwidth", "number", 200000, None, False, "Hz, below the sample rate", minv=1, maxv=499999, integer=True),
          P("samplerate", "number", 500000, None, False, "Hz", minv=1000, maxv=1000000, integer=True),
          P("tones", "number", 8, None, False, "only for multitone", minv=2, maxv=1024, integer=True)],
         lambda p, c: {"argv": ["testrfgen.sh", fq(p, c), str(int(p["bandwidth"])), str(int(p["samplerate"])),
                                p["mode"], str(int(p["tones"])) if p["mode"] == "multitone" else ""]})

# --- Sub-GHz -----------------------------------------------------------------
def _b_sub(p, c):
    argv = ["testsub.sh", p["file"], p["playback"]]
    if p["playback"] == "once":
        argv.append(str(int(p.get("repeat") or 1)))
    return {"argv": argv}


add_mode("sub", "Sub-GHz replay (.sub)", "subghz",
         [P_FILE("file", "sub", [".sub"], "Flipper Zero .sub RAW capture"),
          P_PLAY(),
          P("repeat", "number", 3, None, False, "repeats when playback=once", minv=1, maxv=100, integer=True)],
         _b_sub, "Replays a Flipper-compatible capture. The frequency stored in the file wins.")


def _b_sdrtool(p, c):
    tool = os.path.join(CFG["repo_dir"], "sdrtool.py")
    if not os.path.isfile(tool):
        tool = shutil.which("sdrtool.py") or "sdrtool.py"
    op = p["op"]
    cu8 = p.get("cu8") or ""
    out = p.get("out") or ""
    argv = [tool, op, cu8] if cu8 else [tool, op]
    if out:
        argv.append(out)
    return {"argv": argv, "cwd": CFG["work_dir"]}


add_mode("sdrtool", "sdrtool.py (capture tooling)", "subghz",
         [P("op", "choice", "info", ["info", "freq", "sub", "analyze", "fields", "hex", "render"], False,
            "info/freq need a capture; sub/analyze need a capture + output path"),
          P("cu8", "file", None, None, False, "capture (.cu8) for info/freq/sub/analyze", "iq", [".cu8"]),
          P("out", "text", None, None, False, "output path (relative to work dir)")],
         _b_sdrtool)

# --- RTL-SDR bridge ----------------------------------------------------------
add_mode("record", "RTL-SDR record (IQ)", "rtl-sdr",
         [P("freq", "number", 434.0, None, True, "receive frequency MHz"),
          P("gain", "number", 35, None, False, "0 = AGC, 1-45", minv=0, maxv=49, integer=True),
          P("samplerate", "number", 250000, None, False, "Hz", minv=100000, maxv=2400000, integer=True),
          P("name", "text", "record.iq", None, False, "output file in the work dir")],
         lambda p, c: {"argv": ["rtl_sdr", "-s", str(int(p["samplerate"])), "-g", str(int(p["gain"])),
                                "-f", num(p["freq"]), os.path.join(CFG["work_dir"], os.path.basename(p["name"]))]})
add_mode("play", "RTL-SDR replay (IQ)", "rtl-sdr",
         [P("freq", "number", 434.0, None, True, "transmit frequency MHz"),
          P("file", "file", None, None, True, "IQ file", "iq", [".iq", ".cu8"]),
          P("samplerate", "number", 250000, None, False, "Hz", minv=100000, maxv=2400000, integer=True)],
         lambda p, c: {"argv": ["sendiq", "-s", str(int(p["samplerate"])), "-f", num(p["freq"]),
                                "-t", "u8", "-i", p["file"]]})
add_mode("transponder", "Transponder (RX -> TX)", "rtl-sdr",
         [P("freq_in", "number", 434.0, None, True, "receive MHz"),
          P("gain", "number", 35, None, False, "0 = AGC", minv=0, maxv=49, integer=True),
          P("freq_out", "number", 434.0, None, True, "transmit MHz")],
         lambda p, c: {"argv": ["bash", "-c",
                                "FREQ_IN=%sM GAIN=%s FREQ_OUT=%s . ./transponder.sh"
                                % (p["freq_in"], int(p["gain"]), num(p["freq_out"]))],
                       "cwd": CFG["repo_dir"]})
add_mode("fm2ssb", "FM -> SSB transcoder", "rtl-sdr",
         [P("freq_in", "number", 434.0, None, True, "receive MHz"),
          P("gain", "number", 35, None, False, "0 = AGC", minv=0, maxv=49, integer=True),
          P("freq_out", "number", 434.0, None, True, "transmit MHz")],
         lambda p, c: {"argv": ["bash", "-c",
                                "FREQ_IN=%sM GAIN=%s FREQ_OUT=%s . ./fm2ssb.sh"
                                % (p["freq_in"], int(p["gain"]), num(p["freq_out"]))],
                       "cwd": CFG["repo_dir"]})

# --- FT8 ---------------------------------------------------------------------
def _b_ft8(p, c):
    return {"argv": ["pift8", "-f", num(p["freq"]), "-m", p["message"],
                     "-o", str(int(p["offset"])), "-s", str(p["slot"])]}


add_mode("ft8", "FT8 message (pift8)", "ft8",
         [P("freq", "number", 14.074, None, True, "dial frequency MHz"),
          P("message", "text", "CQ F5OEO JN06", None, True, "13-char FT8 payload"),
          P("offset", "number", 1240, None, False, "audio offset Hz", minv=10, maxv=2600, integer=True),
          P("slot", "choice", "1", ["0", "1"], False, "even/odd time slot")],
         _b_ft8)

# --- TV ----------------------------------------------------------------------
def _q(x):
    return shlex.quote(str(x))


def _b_dvbt(p, c):
    src = p["source"]
    if src == "file":
        inp = "-re -stream_loop -1 -i %s" % _q(p["file"])
    else:
        inp = ('-re -f lavfi -i testsrc2=size=720x576:rate=25 '
               '-re -f lavfi -i sine=frequency=1000:sample_rate=48000')
    rate = int(p["rate"])
    vb = (rate - 128000) * 85 // 100
    hz = int(round(float(p["freq"] or c.cfg["freq_mhz"]) * 1e6))
    cmd = c.cfg.get("dvbt_cmd") or "dvbt-tsrfsend.py {ts}"
    cmd = (cmd.replace("{ts}", '"$D/tx.ts"').replace("{freq_hz}", str(hz))
              .replace("{freq_mhz}", str(p["freq"] or c.cfg["freq_mhz"]))
              .replace("{bw_hz}", str(int(p["bw"]) * 1000000)))
    sh = f"""
set -u
D=$(mktemp -d {_q(CFG['work_dir'])}/dvbt.XXXXXX)
mkfifo "$D/tx.ts"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$D"' EXIT
{SUDO}ffmpeg -nostdin -loglevel error {inp} \\
  -vf "scale=720:576,fps=25,format=yuv420p" \\
  -c:v mpeg2video -b:v {vb} -maxrate {vb} -minrate {vb} -bufsize {vb//2} -g 12 \\
  -c:a mp2 -b:a 128000 -ar 48000 -ac 2 \\
  -f mpegts -muxrate {rate} -mpegts_service_type digital_tv \\
  -metadata service_name={_q(p['name'])} -y "$D/tx.ts" >"$D/ffmpeg.log" 2>&1 &
sleep 1
{SUDO}bash -c {_q(cmd)} >"$D/modulator.log" 2>&1 &
wait
"""
    return {"shell": sh}


def _b_tv(p, c, analog):
    sr = int(p["samplerate"])
    src = p["source"]
    work = CFG["work_dir"]
    pre = ""
    if src == "text":
        pre = (f'D=$(mktemp -d {work}/tv.XXXXXX); '
               f'{SUDO}ffmpeg -nostdin -loglevel error -y -f lavfi -i "color=c=black:s=768x576" '
               f'-vf "drawtext=text={_q(p["text"])}:fontcolor=white:fontsize=64:'
               f'x=(w-text_w)/2:y=(h-text_h)/2" -frames:v 1 "$D/card.png" && IN="$D/card.png"; ')
    elif src == "slideshow":
        pre = (f'D=$(mktemp -d {work}/tv.XXXXXX); '
               f'for f in {_q(DIRS["media"])}/*.jpg; do '
               f'printf "file \'%s\'\\nduration %s\\n" "$f" {int(p["delay"])}; done > "$D/list.txt"; '
               f'{SUDO}ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$D/list.txt" '
               f'-c:v mpeg2video "$D/show.mkv" && IN="$D/show.mkv"; ')
    if src == "colourbars":
        inp = "test:colourbars"
    elif src == "text" or src == "slideshow":
        inp = 'ffmpeg:"$IN"'
    else:
        inp = "ffmpeg:" + p["file"]
    if analog:
        mode = p["standard"]
        extra = "--nocolour --noaudio --level %s" % p["level"]
        for flag, arg in (("filter", "--filter"), ("invert", "--invert-video"),
                          ("interlace", "--interlace"), ("vits", "--vits")):
            if p.get(flag):
                extra += " " + arg
    else:
        mode = p["mode"]
        extra = ""
    sh = f"""
set -u
{pre}
trap 'rm -rf "${{D:-}}" 2>/dev/null' EXIT
{SUDO}hacktv -o file:- -t float -m {_q(mode)} -s {sr} {extra} -r {_q(inp)} 2>/dev/null \\
 | {SUDO}sendiq -i /dev/stdin -s {sr} -f {num(p["freq"] or c.cfg["freq_mhz"])} -t float
"""
    return {"shell": sh}


add_mode("dvbt", "DVB-T broadcast", "tv",
         [P_FREQ(), P("source", "choice", "test", ["test", "file"], False),
          P("file", "file", None, None, False, "video file", "media", [".mp4", ".mkv", ".avi", ".mov", ".ts", ".mpg", ".webm"]),
          P("bw", "choice", "8", ["5", "6", "7", "8"], False, "channel bandwidth MHz"),
          P("rate", "number", 3732000, None, False, "TS bitrate", minv=1000000, maxv=32000000, integer=True),
          P("name", "text", "mostly-a-SDR", None, False, "service name", maxlen=16)],
         _b_dvbt, "Needs an external SDR + modulator.")
add_mode("lowtv", "Low-res analogue TV", "tv",
         [P_FREQ(), P("mode", "choice", "240-am", ["240-am", "30-am"], False),
          P("source", "choice", "colourbars", ["colourbars", "image", "video", "text", "slideshow"], False),
          P("file", "file", None, None, False, "image or video", "media", [".jpg", ".jpeg", ".png", ".bmp", ".mp4", ".mkv", ".avi"]),
          P("text", "text", "CQ CQ DE MOSTLY-A-SDR", None, False, "text card content", maxlen=40)],
         lambda p, c: _b_tv({**p, "samplerate": 192000}, c, False))
add_mode("analogtv", "Analogue TV to a real set", "tv",
         [P_FREQ(), P("standard", "choice", "g", ["g", "i", "pal-d", "l", "m"], False),
          P("samplerate", "number", 3000000, None, False, "Hz", minv=100000, maxv=3400000, integer=True),
          P("level", "text", "1.0", None, False, "video level 0.1-1.0"),
          P("source", "choice", "colourbars", ["colourbars", "image", "video", "text", "slideshow"], False),
          P("file", "file", None, None, False, "image or video", "media", [".jpg", ".jpeg", ".png", ".bmp", ".mp4", ".mkv", ".avi"]),
          P("text", "text", "CQ CQ DE MOSTLY-A-SDR", None, False, "", maxlen=40),
          P("delay", "number", 10, None, False, "slideshow seconds per picture", minv=1, maxv=60, integer=True),
          P("filter", "bool", False), P("invert", "bool", False),
          P("interlace", "bool", False), P("vits", "bool", False)],
         lambda p, c: _b_tv(p, c, True), "Freq = picture carrier. Black/white, silent.")

MODES_BY_ID = {m["id"]: m for m in MODES}


# ---------------------------------------------------------------- validation
def validate(spec, raw):
    out = {}
    for prm in spec["params"]:
        n, t = prm["name"], prm["type"]
        v = raw.get(n, prm.get("default"))
        if t == "number":
            if v in (None, ""):
                v = prm.get("default")
            try:
                v = float(v)
            except (TypeError, ValueError):
                return None, "parameter '%s' must be a number" % n
            if prm.get("integer"):
                v = int(round(v))
            if prm.get("min") is not None and v < prm["min"]:
                return None, "parameter '%s' must be >= %s" % (n, prm["min"])
            if prm.get("max") is not None and v > prm["max"]:
                return None, "parameter '%s' must be <= %s" % (n, prm["max"])
        elif t == "choice":
            if v in (None, ""):
                v = prm.get("default")
            if v not in prm["choices"]:
                return None, "parameter '%s' must be one of: %s" % (n, ", ".join(prm["choices"]))
        elif t == "bool":
            v = bool(v)
        elif t == "file":
            if not v:
                if prm.get("required"):
                    return None, "parameter '%s' is required" % n
                out[n] = None
                continue
            path = resolve_file(str(v), prm)
            if not path:
                return None, "file '%s' not found in %s" % (v, DIRS.get(prm.get("kind", "sub")))
            v = path
        else:
            v = "" if v is None else str(v).strip()
            if prm.get("required") and not v:
                return None, "parameter '%s' is required" % n
            if prm.get("maxlen") and len(v) > prm["maxlen"]:
                return None, "parameter '%s' is longer than %d characters" % (n, prm["maxlen"])
        out[n] = v
    return out, None


# ---------------------------------------------------------------- TX manager
class Tx:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.proc = None
        self.mode = None
        self.params = {}
        self.argv = []
        self.started = 0.0
        self.timer = None
        self.last_exit = None
        self.last_mode = None

    def active(self):
        with self.lock:
            p = self.proc
        return p is not None and p.poll() is None

    def _pump(self, proc):
        path = os.path.join(self.cfg["log_dir"], "tx.log")
        fh = None
        try:
            os.makedirs(self.cfg["log_dir"], exist_ok=True)
            fh = open(path, "a")
            fh.write("\n=== %s ===\n" % time.strftime("%F %T"))
        except OSError:
            fh = None
        try:
            for line in iter(proc.stdout.readline, ""):
                line = line.rstrip("\n")
                if line:
                    log("tx:", line)
                if fh:
                    fh.write(line + "\n")
                    fh.flush()
        except Exception:
            pass
        finally:
            if fh:
                fh.close()
            rc = proc.wait()
            with self.lock:
                self.last_exit = {"code": rc, "at": time.time(), "mode": self.mode}
                self.last_mode = self.mode
                self.proc = None
            log("tx finished: mode=%s rc=%s" % (self.mode, rc))

    def start(self, mode, params, built, duration=0.0):
        if self.cfg.get("stop_before_start", True) and self.active():
            self.stop("preempt")
        argv = built.get("argv")
        shell = built.get("shell")
        cwd = built.get("cwd") or self.cfg["repo_dir"]
        env = dict(os.environ)
        env.update(built.get("env") or {})
        env.setdefault("MAS_QUICK", "1")
        env.setdefault("TERM", "dumb")

        if argv:
            cmd = [which(argv[0])] + [str(x) for x in argv[1:]]
            if USE_SUDO:
                cmd = ["sudo"] + cmd
            shown = cmd
            proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                                    start_new_session=True)
        else:
            shown = ["bash", "-c", shell]
            proc = subprocess.Popen(shown, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                                    start_new_session=True)

        with self.lock:
            self.proc = proc
            self.mode = mode
            self.params = params
            self.argv = shown
            self.started = time.time()
            self.last_exit = None
        log("tx started: mode=%s pid=%d duration=%s" % (mode, proc.pid, duration or "inf"))
        threading.Thread(target=self._pump, args=(proc,), daemon=True).start()
        if duration and float(duration) > 0:
            self.timer = threading.Timer(float(duration), lambda: self.stop("duration"))
            self.timer.daemon = True
            self.timer.start()
        return proc.pid

    def stop(self, reason="api"):
        with self.lock:
            proc = self.proc
            timer = self.timer
            self.timer = None
        if timer:
            try:
                timer.cancel()
            except Exception:
                pass
        if proc and proc.poll() is None:
            log("tx stop (%s) pid=%d" % (reason, proc.pid))
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except OSError:
                pass
            deadline = time.time() + 2.0
            while time.time() < deadline and proc.poll() is None:
                time.sleep(0.1)
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    pass
        self.killall()
        return True

    def killall(self):
        for name in ("hacktv", "csdr", "freedv", "piam", "pichirp", "pifmrds",
                     "pimorse", "pinfm", "piopera", "pirfgen", "pirtty", "pisub",
                     "pissb", "pisstv", "pocsag", "rpitx", "sendiq",
                     "spectrumpaint", "tune", "pift8", "testvfo.sh", "testchirp.sh",
                     "testspectrum.sh", "snap2spectrum.sh", "testfmrds.sh",
                     "testnfm.sh", "testssb.sh", "testam.sh", "testfreedv.sh",
                     "testsstv.sh", "testpocsag.sh", "testopera.sh", "testrtty.sh",
                     "testmorse.sh", "testrfgen.sh", "testsub.sh", "rtl_sdr", "rtl_fm"):
            try:
                subprocess.run([SUDO.strip() or "true"] + (["killall", name] if SUDO else ["killall", name]),
                               capture_output=True, timeout=5)
            except Exception:
                pass

    def status(self):
        with self.lock:
            proc = self.proc
            mode = self.mode
            params = self.params
            started = self.started
            argv = self.argv
            last = self.last_exit
        alive = proc is not None and proc.poll() is None
        external = []
        if not alive:
            external = [n for n in TOOL_NAMES if pgrep(n)]
        return {
            "active": bool(alive or external),
            "mode": mode if alive else (external[0] if external else None),
            "params": params if alive else {},
            "pid": proc.pid if alive else None,
            "started": started if alive else None,
            "elapsed": round(time.time() - started, 1) if alive else 0,
            "argv": argv if alive else [],
            "external": external,
            "last_exit": last,
        }


# ---------------------------------------------------------------- context
class Ctx:
    def __init__(self, cfg):
        self.cfg = cfg
        self.tx = Tx(cfg)


CTX = Ctx(CFG)


def sysinfo():
    info = {"hostname": socket.gethostname(), "version": VERSION, "freq_mhz": CTX.cfg["freq_mhz"]}
    try:
        with open("/proc/device-tree/model") as fh:
            info["model"] = fh.read().strip("\x00").strip()
    except OSError:
        info["model"] = os.uname().machine
    try:
        with open("/proc/uptime") as fh:
            info["uptime_s"] = int(float(fh.read().split()[0]))
    except OSError:
        pass
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as fh:
            info["temp_c"] = round(int(fh.read().strip()) / 1000.0, 1)
    except OSError:
        pass
    try:
        info["load"] = os.getloadavg()
        st = os.statvfs("/")
        info["disk_free_mb"] = int(st.f_bavail * st.f_frsize / 1048576)
    except OSError:
        pass
    ips = []
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout
        ips = [i for i in out.split() if not i.startswith("127.")]
    except Exception:
        pass
    info["ip"] = ips
    info["tools"] = {t: bool(shutil.which(t)) for t in TOOL_NAMES}
    info["missing_tools"] = [t for t, ok in info["tools"].items() if not ok]
    return info


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mostlyASDR/" + VERSION

    # ---- plumbing -----------------------------------------------------------
    def log_message(self, fmt, *a):
        if CTX.cfg.get("verbose"):
            log("http:", fmt % a)

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", CTX.cfg.get("cors_origin", "*"))
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Token,X-Filename")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json_out(self, obj, code=200):
        self._send(code, json.dumps(obj, default=str).encode())

    def err(self, code, msg, **kw):
        obj = {"ok": False, "error": msg}
        obj.update(kw)
        self.json_out(obj, code)

    def body_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode() or "{}")
        except ValueError:
            return {"_raw": raw.decode(errors="replace")}

    def body_raw(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("body too large (%d > %d)" % (n, limit))
        return self.rfile.read(n)

    def auth_ok(self):
        tok = CTX.cfg.get("token") or ""
        if not tok:
            return True
        got = None
        hdr = self.headers.get("Authorization", "")
        if hdr.lower().startswith("bearer "):
            got = hdr[7:].strip()
        got = got or self.headers.get("X-Token")
        if not got:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got = (q.get("token") or [None])[0]
        return bool(got) and hmac.compare_digest(got, tok)

    def require_auth(self):
        if self.auth_ok():
            return True
        self.err(401, "unauthorized - send Authorization: Bearer <token>")
        return False

    # ---- verbs --------------------------------------------------------------
    def do_OPTIONS(self):
        self._send(204, b"")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        u = urllib.parse.urlparse(self.path)
        path = u.path.rstrip("/") or "/"
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        try:
            if path == "/" or path == "/index.html":
                return self.static("index.html")
            if path.startswith("/static/"):
                return self.static(path[len("/static/"):])
            if path in ("/manifest.webmanifest", "/icon.svg", "/favicon.ico"):
                return self.static(path.lstrip("/"))
            if path == API or path == API + "/":
                return self.endpoints()
            if not path.startswith(API):
                return self.err(404, "not found")
            ep = path[len(API):].strip("/")

            # public
            if ep == "health":
                return self.json_out({"ok": True, "version": VERSION})
            if ep == "ping":
                return self.json_out({"ok": True, "version": VERSION,
                                      "host": socket.gethostname(), "needs_token": bool(CTX.cfg.get("token"))})

            if not self.require_auth():
                return

            if ep == "status" and method == "GET":
                return self.json_out({"ok": True, "status": CTX.tx.status(),
                                      "system": {k: sysinfo()[k] for k in ("hostname", "model", "temp_c", "ip")}})
            if ep == "system" and method == "GET":
                return self.json_out({"ok": True, "system": sysinfo()})
            if ep == "modes" and method == "GET":
                return self.json_out({"ok": True, "freq_mhz": CTX.cfg["freq_mhz"],
                                      "groups": sorted({m["group"] for m in MODES}),
                                      "modes": [{k: v for k, v in m.items() if k != "builder"} for m in MODES]})
            if ep == "config" and method == "GET":
                safe = dict(CTX.cfg)
                safe["token"] = CTX.cfg["token"]
                return self.json_out({"ok": True, "config": safe})
            if ep == "config" and method == "POST":
                b = self.body_json()
                for k in ("freq_mhz", "auto_stop_seconds", "stop_before_start", "verbose"):
                    if k in b:
                        CTX.cfg[k] = b[k]
                save_config(DEFAULT_CONFIG, CTX.cfg)
                return self.json_out({"ok": True, "config": CTX.cfg})
            if ep == "freq" and method == "POST":
                b = self.body_json()
                try:
                    CTX.cfg["freq_mhz"] = float(b.get("mhz") or b.get("freq"))
                except (TypeError, ValueError):
                    return self.err(400, "send {\"mhz\": 434.0}")
                save_config(DEFAULT_CONFIG, CTX.cfg)
                return self.json_out({"ok": True, "freq_mhz": CTX.cfg["freq_mhz"]})
            if ep == "files" and method == "GET":
                kind = q.get("kind", "sub")
                exts = [e for e in (q.get("ext") or "").split(",") if e]
                return self.json_out({"ok": True, "kind": kind, "dir": DIRS.get(kind),
                                      "files": list_files(kind, exts or None)})
            if ep == "file" and method == "GET":
                return self.get_file(q)
            if ep == "file" and method == "DELETE":
                return self.del_file(q)
            if ep == "upload" and method == "POST":
                return self.upload(q)
            if ep == "log" and method == "GET":
                try:
                    n = max(1, min(2000, int(q.get("lines", 200))))
                except ValueError:
                    n = 200
                with LOG_LOCK:
                    lines = list(LOG)[-n:]
                txlog = os.path.join(CTX.cfg["log_dir"], "tx.log")
                if q.get("file") == "tx" and os.path.isfile(txlog):
                    try:
                        with open(txlog, errors="replace") as fh:
                            lines = fh.read().splitlines()[-n:]
                    except OSError:
                        pass
                return self.json_out({"ok": True, "lines": lines})
            if ep == "events" and method == "GET":
                return self.sse()
            if ep == "tx" and method == "POST":
                return self.tx_start()
            if ep == "stop" and method == "POST":
                CTX.tx.stop("api")
                return self.json_out({"ok": True, "status": CTX.tx.status()})
            if ep == "raw" and method == "POST":
                b = self.body_json()
                cmd = b.get("cmd")
                if not cmd:
                    return self.err(400, "send {\"cmd\": \"testvfo.sh 434e6\"}")
                if b.get("background"):
                    CTX.tx.start("raw", {"cmd": cmd}, {"shell": cmd})
                    return self.json_out({"ok": True, "pid": CTX.tx.proc.pid})
                r = subprocess.run(["bash", "-lc", cmd], capture_output=True, text=True,
                                   timeout=float(b.get("timeout", 60)))
                return self.json_out({"ok": r.returncode == 0, "code": r.returncode,
                                      "stdout": r.stdout[-20000:], "stderr": r.stderr[-8000:]})
            if ep == "sdrtool" and method == "POST":
                b = self.body_json()
                op = b.get("op")
                tool = os.path.join(CTX.cfg["repo_dir"], "sdrtool.py")
                argv = [tool, op]
                for k in ("cu8", "out", "pkt", "name", "value", "hex"):
                    if b.get(k):
                        argv.append(str(b[k]))
                if b.get("mode"):
                    argv += ["--mode", b["mode"]]
                r = subprocess.run([sys.executable] + argv, capture_output=True, text=True,
                                   cwd=CTX.cfg["work_dir"], timeout=120)
                return self.json_out({"ok": r.returncode == 0, "stdout": r.stdout,
                                      "stderr": r.stderr, "argv": argv})
            if ep == "restart" and method == "POST":
                subprocess.Popen(["systemctl", "restart", "mostly-a-sdr-api"])
                return self.json_out({"ok": True})
            return self.err(404, "unknown endpoint %s" % path)
        except BrokenPipeError:
            pass
        except ValueError as exc:
            self.err(400, str(exc))
        except Exception as exc:  # noqa
            log("handler error:", repr(exc))
            try:
                self.err(500, "%s: %s" % (type(exc).__name__, exc))
            except Exception:
                pass

    # ---- handlers -----------------------------------------------------------
    def endpoints(self):
        return self.json_out({
            "ok": True, "name": "mostly-a-SDR remote API", "version": VERSION,
            "auth": "Authorization: Bearer <token>",
            "endpoints": {
                "GET  /api/v1/health": "liveness, no auth",
                "GET  /api/v1/ping": "version + host, no auth",
                "GET  /api/v1/status": "TX state + system summary",
                "GET  /api/v1/system": "host, temp, load, disk, tool availability",
                "GET  /api/v1/modes": "mode catalogue with parameter schemas",
                "GET  /api/v1/config": "current config",
                "POST /api/v1/config": "update freq_mhz / auto_stop_seconds / stop_before_start",
                "POST /api/v1/freq": "{\"mhz\":434.0}",
                "GET  /api/v1/files?kind=sub|media|iq": "list files",
                "GET  /api/v1/file?kind=sub&name=x.sub": "download",
                "POST /api/v1/upload?kind=sub&name=x.sub": "raw body upload",
                "DELETE /api/v1/file?kind=sub&name=x.sub": "delete",
                "POST /api/v1/tx": "{\"mode\":\"sub\",\"params\":{...},\"duration\":10}",
                "POST /api/v1/stop": "kill current TX",
                "GET  /api/v1/log?lines=200": "server + TX log",
                "GET  /api/v1/events": "server-sent events status stream",
                "POST /api/v1/raw": "{\"cmd\":\"...\",\"background\":false}",
                "POST /api/v1/sdrtool": "run sdrtool.py on a capture",
                "POST /api/v1/restart": "restart the service",
            },
        })

    def tx_start(self):
        b = self.body_json()
        mid = b.get("mode")
        spec = MODES_BY_ID.get(mid)
        if not spec:
            return self.err(400, "unknown mode '%s'" % mid, modes=sorted(MODES_BY_ID))
        params, err = validate(spec, b.get("params") or {})
        if err:
            return self.err(400, err)
        if b.get("freq"):
            params["freq"] = float(b["freq"])
            CTX.cfg["freq_mhz"] = float(b["freq"])
            save_config(DEFAULT_CONFIG, CTX.cfg)
        try:
            built = spec["builder"](params, CTX)
        except KeyError as exc:
            return self.err(400, "missing parameter %s" % exc)
        duration = b.get("duration", CTX.cfg.get("auto_stop_seconds") or 0)
        pid = CTX.tx.start(mid, params, built, duration)
        return self.json_out({"ok": True, "mode": mid, "pid": pid, "params": params,
                              "argv": built.get("argv") or built.get("shell"),
                              "duration": duration}, 202)

    def get_file(self, q):
        kind = q.get("kind", "sub")
        base = DIRS.get(kind)
        name = os.path.basename(q.get("name", ""))
        if not base or not name:
            return self.err(400, "need kind and name")
        fp = os.path.join(base, name)
        if not os.path.isfile(fp):
            return self.err(404, "no such file")
        import mimetypes
        ctype = mimetypes.guess_type(fp)[0] or "application/octet-stream"
        with open(fp, "rb") as fh:
            data = fh.read()
        self._send(200, data, ctype, {"Content-Disposition": 'attachment; filename="%s"' % name})

    def del_file(self, q):
        kind = q.get("kind", "sub")
        base = DIRS.get(kind)
        name = os.path.basename(q.get("name", ""))
        fp = os.path.join(base or "", name)
        if not os.path.isfile(fp):
            return self.err(404, "no such file")
        try:
            os.remove(fp)
        except OSError as exc:
            return self.err(500, str(exc))
        return self.json_out({"ok": True, "removed": name})

    def upload(self, q):
        kind = q.get("kind", "sub")
        if kind not in DIRS:
            return self.err(400, "unknown kind")
        name = os.path.basename(q.get("name") or self.headers.get("X-Filename") or "upload.bin")
        name = re.sub(r"[^A-Za-z0-9._-]", "_", name) or "upload.bin"
        limit = int(CTX.cfg.get("max_upload_mb", 64)) * 1024 * 1024
        data = self.body_raw(limit)
        os.makedirs(DIRS[kind], exist_ok=True)
        fp = os.path.join(DIRS[kind], name)
        with open(fp, "wb") as fh:
            fh.write(data)
        log("upload %s (%d bytes)" % (fp, len(data)))
        return self.json_out({"ok": True, "kind": kind, "name": name, "size": len(data)})

    def static(self, rel):
        import mimetypes
        fp = os.path.normpath(os.path.join(WEB_DIR, rel.lstrip("/")))
        if not fp.startswith(WEB_DIR) or not os.path.isfile(fp):
            if rel == "favicon.ico":
                fp = os.path.join(WEB_DIR, "icon.svg")
            else:
                return self.err(404, "no static file %s" % rel)
        with open(fp, "rb") as fh:
            data = fh.read()
        self._send(200, data, mimetypes.guess_type(fp)[0] or "text/plain")

    def sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", CTX.cfg.get("cors_origin", "*"))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                payload = {"status": CTX.tx.status(),
                           "freq_mhz": CTX.cfg["freq_mhz"],
                           "ts": time.time()}
                self.wfile.write(b"data: " + json.dumps(payload, default=str).encode() + b"\n\n")
                self.wfile.flush()
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError):
            pass


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="mostly-a-SDR remote API")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--port", type=int)
    ap.add_argument("--bind")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    global CFG, CTX, DIRS
    CFG = load_config(a.config)
    if a.port:
        CFG["port"] = a.port
    if a.bind:
        CFG["bind"] = a.bind
    if a.verbose:
        CFG["verbose"] = True
    DIRS = {"sub": CFG["sub_dir"], "media": CFG["media_dir"], "iq": CFG["work_dir"],
            "capture": CFG["capture_dir"], "log": CFG["log_dir"], "repo": CFG["repo_dir"]}
    CTX = Ctx(CFG)
    if not os.path.exists(a.config):
        save_config(a.config, CFG)

    for d in (CFG["log_dir"], CFG["work_dir"], CFG["sub_dir"]):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError as exc:
            log("cannot create", d, exc)

    srv = ThreadingHTTPServer((CFG["bind"], CFG["port"]), Handler)
    srv.daemon_threads = True

    def shutdown(signum, frame):
        log("signal %s - stopping" % signum)
        try:
            CTX.tx.stop("shutdown")
        except Exception:
            pass
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log("mostly-a-SDR API v%s listening on http://%s:%d/  (auth=%s)"
        % (VERSION, CFG["bind"], CFG["port"], "on" if CFG.get("token") else "OFF"))
    missing = [t for t in TOOL_NAMES if not shutil.which(t)]
    if missing:
        log("tools not found (those modes will fail): " + ", ".join(missing))
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
        log("bye")


if __name__ == "__main__":
    main()
PY_EOF
	chmod 755 "${OPT_DIR}/sdr_api.py"
	python3 -c "import ast,sys;ast.parse(open('${OPT_DIR}/sdr_api.py').read())" || die "generated sdr_api.py has a syntax error"
}

# -----------------------------------------------------------------------------
#  4. web UI  (also installable as a PWA on the phone)
# -----------------------------------------------------------------------------
write_web() {
	say "writing web UI"
	cat > "${OPT_DIR}/web/index.html" <<'HTML_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#050505">
<meta name="mobile-web-app-capable" content="yes">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon.svg">
<link rel="stylesheet" href="/static/style.css">
<title>mostly-a-SDR remote</title>
</head>
<body>
<header>
  <div class="brand">▓▒░ mostly-a-SDR <span>remote</span></div>
  <div class="stat"><span id="dot"></span><span id="state">offline</span></div>
  <div class="freq">
    <input id="freq" type="number" step="0.001" value="434.0"><span>MHz</span>
    <button id="setfreq">SET</button>
    <button id="stop" class="danger">STOP</button>
  </div>
</header>

<nav>
  <button data-tab="modes" class="on">Modes</button>
  <button data-tab="files">Files</button>
  <button data-tab="log">Log</button>
  <button data-tab="sys">System</button>
  <button data-tab="conn">Connect</button>
</nav>

<main>
  <section id="tab-conn">
    <div class="card">
      <label>Pi address <input id="host" placeholder="192.168.1.50 or mostly-a-sdr.local"></label>
      <label>Port <input id="port" type="number" value="8765"></label>
      <label>Token <input id="token" type="password" placeholder="from the installer output"></label>
      <button id="connect" class="big">CONNECT</button>
      <p id="connerr" class="dim"></p>
      <p class="dim">Tip: open this page as <code>http://HOST:8765/?token=YOURTOKEN</code> to log in automatically, then "Add to home screen".</p>
    </div>
  </section>

  <section id="tab-modes" class="hide"><div id="modes"></div></section>

  <section id="tab-files" class="hide">
    <div class="card row">
      <select id="kind">
        <option value="sub">.sub captures</option>
        <option value="media">media / audio / images</option>
        <option value="iq">IQ recordings</option>
      </select>
      <button id="refresh">refresh</button>
      <label class="upload">upload<input id="file" type="file" hidden></label>
    </div>
    <div id="files"></div>
  </section>

  <section id="tab-log" class="hide">
    <div class="card row"><button id="logrefresh">refresh</button><span class="dim">server + TX output</span></div>
    <pre id="log"></pre>
  </section>

  <section id="tab-sys" class="hide"><pre id="sys"></pre></section>
</main>

<div id="toast"></div>
<script src="/static/app.js"></script>
</body>
</html>
HTML_EOF

	cat > "${OPT_DIR}/web/style.css" <<'CSS_EOF'
:root{--bg:#050505;--fg:#39ff88;--pink:#ff2fb0;--dim:#6b6b6b;--line:#1c1c1c}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
header{padding:10px 12px;border-bottom:1px solid var(--line);position:sticky;top:0;background:#000;z-index:5}
.brand{font-weight:700;letter-spacing:.5px}
.brand span{color:var(--pink)}
.stat{font-size:12px;color:var(--dim);margin:4px 0}
#dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:#444;margin-right:6px;vertical-align:middle}
#dot.live{background:var(--pink);box-shadow:0 0 8px var(--pink)}
#dot.rec{background:#ffd400}
.freq{display:flex;gap:6px;align-items:center;font-size:12px;color:var(--dim);flex-wrap:wrap}
input,select,button,textarea{background:#0c0c0c;color:var(--fg);border:1px solid #262626;border-radius:4px;padding:8px;font:inherit}
input[type=number]{width:96px}
button{cursor:pointer}
button.danger{border-color:var(--pink);color:var(--pink)}
button.big{padding:12px;width:100%;margin-top:8px}
nav{display:flex;gap:6px;padding:8px 12px;border-bottom:1px solid var(--line);position:sticky;top:104px;background:#000;z-index:4}
nav button{flex:1;font-size:12px;padding:8px 4px}
nav button.on{border-color:var(--fg);color:#000;background:var(--fg)}
main{padding:12px;padding-bottom:60px}
.card{border:1px solid var(--line);border-radius:6px;padding:12px;margin-bottom:12px;background:#080808}
.card.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
label{display:block;margin-bottom:8px;font-size:12px;color:var(--dim)}
label input,label select{display:block;width:100%;margin-top:4px;color:var(--fg)}
.dim{color:var(--dim);font-size:12px}
.hide{display:none}
.mode{border:1px solid var(--line);border-radius:6px;padding:10px;margin-bottom:8px;background:#080808}
.mode h3{margin:0 0 4px;font-size:14px}
.mode .g{font-size:10px;color:var(--pink);text-transform:uppercase;letter-spacing:1px}
.mode p{margin:4px 0 8px;color:var(--dim);font-size:12px}
.frow{display:flex;justify-content:space-between;align-items:center;border-top:1px dotted #1a1a1a;padding:6px 0;font-size:12px}
.frow button{font-size:11px;padding:4px 8px}
pre{white-space:pre-wrap;word-break:break-word;background:#080808;border:1px solid var(--line);border-radius:6px;padding:10px;font-size:12px;max-height:60vh;overflow:auto}
#toast{position:fixed;left:0;right:0;bottom:0;padding:10px;background:var(--pink);color:#000;font-weight:700;transform:translateY(100%);transition:.2s}
#toast.on{transform:none}
.upload{border:1px dashed var(--pink);border-radius:4px;padding:8px;color:var(--pink);cursor:pointer}
CSS_EOF

	cat > "${OPT_DIR}/web/app.js" <<'JS_EOF'
const $ = (s) => document.querySelector(s);
const state = {
  host: localStorage.masdr_host || location.hostname || "",
  port: localStorage.masdr_port || location.port || "8765",
  token: localStorage.masdr_token || new URLSearchParams(location.search).get("token") || "",
  freq: 434.0, modes: [], tx: null, timer: null,
};

function toast(msg, ms = 2200) {
  const t = $("#toast"); t.textContent = msg; t.classList.add("on");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("on"), ms);
}
function base() { return `http://${state.host}:${state.port}`; }

async function api(method, path, body, raw) {
  const opt = { method, headers: { "Authorization": "Bearer " + state.token } };
  if (body !== undefined) { opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body); }
  if (raw) { opt.body = raw; }
  const r = await fetch(base() + path, opt);
  const txt = await r.text();
  let obj = {};
  try { obj = txt ? JSON.parse(txt) : {}; } catch (e) { obj = { raw: txt }; }
  if (!r.ok) throw new Error(obj.error || ("HTTP " + r.status));
  return obj;
}

function renderStatus(s) {
  const st = s.status || {};
  $("#dot").className = st.active ? (st.mode === "record" ? "rec" : "live") : "";
  $("#state").textContent = st.active
    ? `TX ${st.mode}${st.pid ? " pid " + st.pid : ""} ${st.elapsed ? st.elapsed + "s" : ""}`
    : "standby";
}

async function poll() {
  try {
    const s = await api("GET", "/api/v1/status");
    renderStatus(s);
    if (s.system && s.system.temp_c) $("#state").textContent += ` ${s.system.temp_c}C`;
  } catch (e) { $("#dot").className = ""; $("#state").textContent = "offline: " + e.message; }
}

async function loadModes() {
  const d = await api("GET", "/api/v1/modes");
  state.modes = d.modes;
  $("#freq").value = d.freq_mhz;
  const box = $("#modes"); box.innerHTML = "";
  const groups = {};
  d.modes.forEach(m => (groups[m.group] = groups[m.group] || []).push(m));
  for (const g of Object.keys(groups)) {
    const h = document.createElement("div");
    h.className = "g"; h.style.margin = "14px 0 6px"; h.textContent = g;
    box.appendChild(h);
    groups[g].forEach(m => box.appendChild(modeCard(m)));
  }
}

function modeCard(m) {
  const el = document.createElement("div");
  el.className = "mode";
  el.innerHTML = `<h3>${m.label}</h3><p>${m.help || ""}</p>`;
  const form = document.createElement("div");
  m.params.forEach(p => {
    if (p.type === "bool") {
      const l = document.createElement("label");
      l.innerHTML = `<input type="checkbox" data-p="${p.name}"> ${p.name}`;
      form.appendChild(l);
      return;
    }
    const l = document.createElement("label");
    l.textContent = p.name + (p.unit ? ` (${p.unit})` : "");
    let inp;
    if (p.type === "choice") {
      inp = document.createElement("select");
      p.choices.forEach(c => { const o = document.createElement("option"); o.value = o.textContent = c; inp.appendChild(o); });
      inp.value = p.default;
    } else if (p.type === "file") {
      inp = document.createElement("select");
      inp.dataset.file = p.kind;
      inp.dataset.exts = (p.exts || []).join(",");
      const o = document.createElement("option"); o.value = ""; o.textContent = "loading..."; inp.appendChild(o);
      api("GET", `/api/v1/files?kind=${p.kind}${p.exts ? "&ext=" + p.exts.join(",") : ""}`)
        .then(r => {
          inp.innerHTML = "";
          if (!r.files.length) inp.innerHTML = `<option value="">(no files in ${r.dir})</option>`;
          r.files.forEach(f => { const o = document.createElement("option"); o.value = f.name; o.textContent = f.name; inp.appendChild(o); });
        }).catch(e => { inp.innerHTML = `<option value="">${e.message}</option>`; });
    } else {
      inp = document.createElement("input");
      inp.type = p.type === "number" ? "number" : "text";
      if (p.type === "number") { inp.step = "any"; if (p.min != null) inp.min = p.min; if (p.max != null) inp.max = p.max; }
      inp.value = p.default == null ? "" : p.default;
    }
    inp.dataset.p = p.name;
    inp.dataset.type = p.type;
    l.appendChild(inp);
    form.appendChild(l);
  });
  const dur = document.createElement("label");
  dur.textContent = "duration in seconds (0 = until stopped)";
  dur.innerHTML += `<input type="number" value="0" data-dur>`;
  form.appendChild(dur);
  const go = document.createElement("button");
  go.className = "big"; go.textContent = "▶ TRANSMIT";
  go.onclick = () => {
    const params = {};
    form.querySelectorAll("[data-p]").forEach(i => {
      if (i.dataset.type === "bool") { if (i.checked) params[i.dataset.p] = true; return; }
      if (i.value !== "") params[i.dataset.p] = i.dataset.type === "number" ? Number(i.value) : i.value;
    });
    const duration = Number(form.querySelector("[data-dur]").value || 0);
    api("POST", "/api/v1/tx", { mode: m.id, params, duration, freq: Number($("#freq").value) })
      .then(r => toast("TX " + r.mode + " started"))
      .catch(e => toast("error: " + e.message, 4000));
  };
  form.appendChild(go);
  el.appendChild(form);
  return el;
}

async function loadFiles() {
  const kind = $("#kind").value;
  const r = await api("GET", `/api/v1/files?kind=${kind}`);
  const box = $("#files"); box.innerHTML = "";
  if (!r.files.length) { box.innerHTML = `<p class="dim">nothing in ${r.dir}</p>`; return; }
  r.files.forEach(f => {
    const d = document.createElement("div");
    d.className = "frow";
    d.innerHTML = `<span>${f.name} <span class="dim">${(f.size / 1024).toFixed(1)} kB</span></span>`;
    const acts = document.createElement("span");
    if (kind === "sub") {
      const t = document.createElement("button"); t.textContent = "replay";
      t.onclick = () => api("POST", "/api/v1/tx", { mode: "sub", params: { file: f.name, playback: "once", repeat: 3 } })
        .then(() => toast("replaying " + f.name)).catch(e => toast(e.message, 4000));
      acts.appendChild(t);
    }
    const dl = document.createElement("button"); dl.textContent = "get";
    dl.onclick = () => window.open(`${base()}/api/v1/file?kind=${kind}&name=${encodeURIComponent(f.name)}&token=${state.token}`);
    acts.appendChild(dl);
    const rm = document.createElement("button"); rm.textContent = "del";
    rm.onclick = () => api("DELETE", `/api/v1/file?kind=${kind}&name=${encodeURIComponent(f.name)}`)
      .then(loadFiles).catch(e => toast(e.message, 4000));
    acts.appendChild(rm);
    d.appendChild(acts);
    box.appendChild(d);
  });
}

async function loadLog() {
  const r = await api("GET", "/api/v1/log?lines=300");
  const el = $("#log"); el.textContent = r.lines.join("\n");
  el.scrollTop = el.scrollHeight;
}

async function loadSys() {
  const r = await api("GET", "/api/v1/system");
  $("#sys").textContent = JSON.stringify(r.system, null, 2);
}

$("#connect").onclick = async () => {
  state.host = $("#host").value.trim(); state.port = $("#port").value.trim(); state.token = $("#token").value.trim();
  localStorage.masdr_host = state.host; localStorage.masdr_port = state.port; localStorage.masdr_token = state.token;
  $("#connerr").textContent = "";
  try { await api("GET", "/api/v1/status"); toast("connected"); switchTab("modes"); loadModes(); }
  catch (e) { $("#connerr").textContent = "failed: " + e.message; }
};
$("#stop").onclick = () => api("POST", "/api/v1/stop").then(() => toast("stopped")).catch(e => toast(e.message, 4000));
$("#setfreq").onclick = () => api("POST", "/api/v1/freq", { mhz: Number($("#freq").value) }).then(() => toast("frequency set"));
$("#refresh").onclick = loadFiles;
$("#kind").onchange = loadFiles;
$("#logrefresh").onclick = loadLog;
$("#file").onchange = async (ev) => {
  const f = ev.target.files[0]; if (!f) return;
  const kind = $("#kind").value;
  const buf = await f.arrayBuffer();
  await fetch(`${base()}/api/v1/upload?kind=${kind}&name=${encodeURIComponent(f.name)}`, {
    method: "POST", headers: { "Authorization": "Bearer " + state.token }, body: buf });
  toast("uploaded " + f.name); loadFiles();
};

function switchTab(name) {
  document.querySelectorAll("nav button").forEach(b => b.classList.toggle("on", b.dataset.tab === name));
  ["modes", "files", "log", "sys", "conn"].forEach(t => $("#tab-" + t).classList.toggle("hide", t !== name));
  if (name === "files") loadFiles();
  if (name === "log") loadLog();
  if (name === "sys") loadSys();
}
document.querySelectorAll("nav button").forEach(b => b.onclick = () => switchTab(b.dataset.tab));

(async function init() {
  $("#host").value = state.host; $("#port").value = state.port; $("#token").value = state.token;
  if (!state.host || !state.token) { switchTab("conn"); return; }
  try { await api("GET", "/api/v1/status"); switchTab("modes"); loadModes(); poll(); setInterval(poll, 3000); }
  catch (e) { switchTab("conn"); $("#connerr").textContent = "failed: " + e.message; }
})();
JS_EOF

	cat > "${OPT_DIR}/web/manifest.webmanifest" <<'MAN_EOF'
{
  "name": "mostly-a-SDR remote",
  "short_name": "SDR remote",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#050505",
  "theme_color": "#050505",
  "icons": [{ "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml" }]
}
MAN_EOF

	cat > "${OPT_DIR}/web/icon.svg" <<'ICON_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108">
  <rect width="108" height="108" fill="#050505"/>
  <g fill="#39ff88">
    <rect x="18" y="62" width="12" height="12"/><rect x="36" y="50" width="12" height="24"/>
    <rect x="54" y="38" width="12" height="36"/><rect x="72" y="24" width="12" height="50"/>
  </g>
  <rect x="18" y="80" width="66" height="6" fill="#ff2fb0"/>
</svg>
ICON_EOF
	chmod 644 "${OPT_DIR}"/web/*
}

# -----------------------------------------------------------------------------
#  5. CLI client
# -----------------------------------------------------------------------------
write_cli() {
	say "writing sdrctl"
	cat > "${OPT_DIR}/sdrctl" <<'CLI_EOF'
#!/usr/bin/env python3
"""sdrctl - drive the mostly-a-SDR remote API from the Pi (or anywhere)."""
import json, os, sys, urllib.request, urllib.error

CFG = os.environ.get("MASDR_CONFIG", "/etc/mostly-a-sdr/api.json")
try:
    with open(CFG) as fh:
        _c = json.load(fh)
except OSError:
    _c = {}
BASE = os.environ.get("MASDR_URL") or "http://%s:%s" % (
    "127.0.0.1" if _c.get("bind") in ("0.0.0.0", "") else _c.get("bind", "127.0.0.1"),
    _c.get("port", 8765))
TOKEN = os.environ.get("MASDR_TOKEN") or _c.get("token", "")


def call(method, path, body=None, raw=None, ctype="application/json"):
    url = BASE + path
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    elif raw is not None:
        data = raw
    req = urllib.request.Request(url, data=data, method=method)
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    if data:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "error": "HTTP %s" % e.code}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def usage():
    print(__doc__)
    print("""commands:
  ping | status | system | modes | log [n] | stop | pair | url
  freq <mhz> | config [k=v ...]
  tx <mode> [k=v ...] [duration=SECONDS]      start a transmission
  ls <kind> | put <file> [kind] | get <name> [kind] | rm <name> [kind]
  raw "<shell command>"
  sdrtool <op> [cu8=...] [out=...]""")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        usage()
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd in ("ping", "status", "system", "modes", "stop", "config"):
        if cmd == "config" and args:
            body = {}
            for a in args:
                k, _, v = a.partition("=")
                body[k] = json.loads(v) if v[:1] in "0123456789tfn" else v
            print(json.dumps(call("POST", "/api/v1/config", body), indent=2))
        else:
            print(json.dumps(call("GET", "/api/v1/" + cmd), indent=2))
    elif cmd == "url":
        print(BASE)
    elif cmd == "pair":
        host = os.uname().nodename + ".local"
        print("web UI : %s/?token=%s" % (BASE.replace("127.0.0.1", host), TOKEN))
        print("token  : %s" % TOKEN)
        os.system("command -v qrencode >/dev/null && qrencode -t ANSIUTF8 '%s/?token=%s'"
                  % (BASE.replace("127.0.0.1", host), TOKEN))
    elif cmd == "log":
        r = call("GET", "/api/v1/log?lines=%s" % (args[0] if args else 200))
        print("\n".join(r.get("lines", [])))
    elif cmd == "freq":
        print(json.dumps(call("POST", "/api/v1/freq", {"mhz": float(args[0])}), indent=2))
    elif cmd == "tx":
        mode = args[0]
        params, extra = {}, {}
        for a in args[1:]:
            k, _, v = a.partition("=")
            if k in ("duration", "freq"):
                extra[k] = float(v)
            else:
                params[k] = v
        print(json.dumps(call("POST", "/api/v1/tx", {"mode": mode, "params": params, **extra}), indent=2))
    elif cmd == "ls":
        print(json.dumps(call("GET", "/api/v1/files?kind=%s" % (args[0] if args else "sub")), indent=2))
    elif cmd == "put":
        kind = args[1] if len(args) > 1 else "sub"
        name = os.path.basename(args[0])
        with open(args[0], "rb") as fh:
            print(json.dumps(call("POST", "/api/v1/upload?kind=%s&name=%s" % (kind, name),
                                  raw=fh.read(), ctype="application/octet-stream"), indent=2))
    elif cmd == "get":
        kind = args[1] if len(args) > 1 else "sub"
        req = urllib.request.Request("%s/api/v1/file?kind=%s&name=%s" % (BASE, kind, args[0]))
        if TOKEN:
            req.add_header("Authorization", "Bearer " + TOKEN)
        with urllib.request.urlopen(req) as r, open(args[0], "wb") as out:
            out.write(r.read())
        print("saved", args[0])
    elif cmd == "rm":
        kind = args[1] if len(args) > 1 else "sub"
        print(json.dumps(call("DELETE", "/api/v1/file?kind=%s&name=%s" % (kind, args[0])), indent=2))
    elif cmd == "raw":
        print(json.dumps(call("POST", "/api/v1/raw", {"cmd": args[0]}), indent=2))
    elif cmd == "sdrtool":
        body = {"op": args[0]}
        for a in args[1:]:
            k, _, v = a.partition("=")
            body[k] = v
        print(json.dumps(call("POST", "/api/v1/sdrtool", body), indent=2))
    else:
        usage()


if __name__ == "__main__":
    main()
CLI_EOF
	chmod 755 "${OPT_DIR}/sdrctl"
	$SUDO ln -sf "${OPT_DIR}/sdrctl" /usr/local/bin/sdrctl
}

# -----------------------------------------------------------------------------
#  6. systemd unit + avahi advertisement
# -----------------------------------------------------------------------------
write_service() {
	say "installing systemd service"
	$SUDO tee "$UNIT" >/dev/null <<UNIT_EOF
[Unit]
Description=mostly-a-SDR remote API (HTTP/JSON RF control)
Documentation=file://${OPT_DIR}/README.md
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${OPT_DIR}
Environment=MASDR_CONFIG=${CONF_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 ${OPT_DIR}/sdr_api.py --config ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
StandardOutput=append:${LOG_DIR}/api.log
StandardError=append:${LOG_DIR}/api.log
# rpitx pokes /dev/mem and needs realtime-ish scheduling
LimitMEMLOCK=infinity
Nice=-5

[Install]
WantedBy=multi-user.target
UNIT_EOF

	if command -v avahi-daemon >/dev/null 2>&1 || [ -d /etc/avahi/services ]; then
		$SUDO mkdir -p /etc/avahi/services
		$SUDO tee "$AVAHI_SVC" >/dev/null <<AVAHI_EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">mostly-a-SDR on %h</name>
  <service>
    <type>_masdr._tcp</type>
    <port>${PORT}</port>
    <txt-record>path=/</txt-record>
    <txt-record>version=${API_VERSION}</txt-record>
  </service>
</service-group>
AVAHI_EOF
		say "mDNS advertised as _masdr._tcp on port ${PORT}"
	fi

	$SUDO systemctl daemon-reload
	$SUDO systemctl enable "${APP_NAME}.service" >/dev/null 2>&1 || true
	$SUDO systemctl restart "${APP_NAME}.service" || warn "service failed to start - check: journalctl -u ${APP_NAME} -n 50"
	sleep 1
	if curl -fsS "http://127.0.0.1:${PORT}/api/v1/health" >/dev/null 2>&1; then
		say "API is live on port ${PORT}"
	else
		warn "API did not answer on 127.0.0.1:${PORT} - check journalctl -u ${APP_NAME} -n 50"
	fi
}

# -----------------------------------------------------------------------------
#  7. Android app source
# -----------------------------------------------------------------------------
write_android() {
	say "generating Android app source in ${OPT_DIR}/android"
	A="${OPT_DIR}/android"
	$SUDO mkdir -p "${A}/app/src/main/java/de/mostlyasdr/remote" \
		"${A}/app/src/main/res/values" "${A}/app/src/main/res/drawable" "${A}/gradle"

	$SUDO tee "${A}/settings.gradle.kts" >/dev/null <<'SET_EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "mostly-a-sdr-remote"
include(":app")
SET_EOF

	$SUDO tee "${A}/build.gradle.kts" >/dev/null <<'ROOT_EOF'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
ROOT_EOF

	$SUDO tee "${A}/gradle.properties" >/dev/null <<'PROP_EOF'
org.gradle.jvmargs=-Xmx2048m
android.useAndroidX=true
android.nonTransitiveRClass=true
kotlin.code.style=official
PROP_EOF

	$SUDO tee "${A}/app/build.gradle.kts" >/dev/null <<'APP_EOF'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "de.mostlyasdr.remote"
    compileSdk = 34
    defaultConfig {
        applicationId = "de.mostlyasdr.remote"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
APP_EOF

	$SUDO tee "${A}/app/src/main/AndroidManifest.xml" >/dev/null <<'MANIFEST_EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <application
        android:label="mostly-a-SDR"
        android:icon="@drawable/ic_launcher"
        android:usesCleartextTraffic="true"
        android:theme="@android:style/Theme.Material.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:label="mostly-a-SDR"
            android:configChanges="orientation|screenSize|keyboardHidden">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
MANIFEST_EOF

	$SUDO tee "${A}/app/src/main/res/values/strings.xml" >/dev/null <<'STR_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">mostly-a-SDR</string>
</resources>
STR_EOF

	$SUDO tee "${A}/app/src/main/res/drawable/ic_launcher.xml" >/dev/null <<'VEC_EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#050505" android:pathData="M0,0h108v108h-108z" />
    <path android:fillColor="#39FF88" android:pathData="M18,62h12v12h-12z M36,50h12v24h-12z M54,38h12v36h-12z M72,24h12v50h-12z" />
    <path android:fillColor="#FF2FB0" android:pathData="M18,80h66v6h-66z" />
</vector>
VEC_EOF

	$SUDO tee "${A}/app/src/main/java/de/mostlyasdr/remote/MainActivity.kt" >/dev/null <<'KT_EOF'
package de.mostlyasdr.remote

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.ArrayAdapter
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * mostly-a-SDR remote control.
 * Talks to /api/v1 on the Pi: mode catalogue is fetched dynamically, so the UI
 * grows with whatever the Pi's API supports.
 */
class MainActivity : Activity() {

    private lateinit var prefs: SharedPreferences
    private var host = ""
    private var port = 8765
    private var token = ""
    private var freq = 434.0

    private val io = Executors.newFixedThreadPool(4)
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var content: FrameLayout
    private lateinit var status: TextView
    private lateinit var freqField: EditText
    private var modes: JSONArray? = null
    private var webView: WebView? = null
    private var polling = false
    private var lastKind = "sub"
    private var pendingUploadKind = "sub"

    private val BG = Color.parseColor("#050505")
    private val FG = Color.parseColor("#39FF88")
    private val PINK = Color.parseColor("#FF2FB0")
    private val DIM = Color.parseColor("#777777")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = getSharedPreferences("masdr", MODE_PRIVATE)
        host = prefs.getString("host", "") ?: ""
        port = prefs.getInt("port", 8765)
        token = prefs.getString("token", "") ?: ""
        freq = prefs.getFloat("freq", 434.0f).toDouble()
        setContentView(buildRoot())
        if (host.isEmpty()) showConnect() else { switchTab("modes"); loadModes() }
        if (host.isNotEmpty()) startPoll()
    }

    // ---------------------------------------------------------------- ui kit
    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(),
        resources.displayMetrics).toInt()

    private fun tv(text: String, color: Int = FG, size: Float = 14f, bold: Boolean = false): TextView {
        val t = TextView(this)
        t.text = text; t.setTextColor(color); t.textSize = size
        if (bold) t.setTypeface(Typeface.MONOSPACE, Typeface.BOLD) else t.setTypeface(Typeface.MONOSPACE)
        t.setPadding(dp(4), dp(4), dp(4), dp(4))
        return t
    }

    private fun button(text: String, color: Int = FG, onClick: () -> Unit): Button {
        val b = Button(this)
        b.text = text; b.setTextColor(color); b.textSize = 13f
        b.background = resources.getDrawable(android.R.drawable.btn_default, null)
        b.setOnClickListener { onClick() }
        return b
    }

    private fun card(vararg views: View): LinearLayout {
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        l.setPadding(dp(10), dp(10), dp(10), dp(10))
        views.forEach { l.addView(it) }
        return l
    }

    private fun buildRoot(): View {
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(BG)

        val head = LinearLayout(this)
        head.orientation = LinearLayout.VERTICAL
        head.setPadding(dp(10), dp(10), dp(10), dp(6))
        head.addView(tv("▓▒░ mostly-a-SDR remote", PINK, 16f, true))
        status = tv("standby", DIM, 12f)
        head.addView(status)

        val controls = LinearLayout(this)
        controls.orientation = LinearLayout.HORIZONTAL
        controls.gravity = Gravity.CENTER_VERTICAL
        freqField = EditText(this)
        freqField.setText(freq.toString())
        freqField.inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        freqField.setTextColor(FG); freqField.textSize = 13f
        freqField.setBackgroundColor(Color.parseColor("#101010"))
        freqField.setPadding(dp(6), dp(4), dp(6), dp(4))
        val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        controls.addView(freqField, lp)
        controls.addView(tv("MHz", DIM, 12f))
        controls.addView(button("SET") {
            io.execute {
                val b = JSONObject().put("mhz", freqField.text.toString().toDoubleOrNull() ?: freq)
                api("POST", "/api/v1/freq", b) { }
            }
        })
        controls.addView(button("STOP", PINK) { api("POST", "/api/v1/stop", null) { toast("stopped") } })
        head.addView(controls)
        root.addView(head)

        content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val tabs = HorizontalScrollView(this)
        val tabRow = LinearLayout(this)
        tabRow.orientation = LinearLayout.HORIZONTAL
        listOf("modes" to "MODES", "files" to "FILES", "log" to "LOG",
               "web" to "WEB", "setup" to "SETUP").forEach { (id, label) ->
            tabRow.addView(button(label) { switchTab(id) })
        }
        tabs.addView(tabRow)
        root.addView(tabs)
        return root
    }

    private fun setScreen(v: View) {
        content.removeAllViews()
        content.addView(v, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun switchTab(id: String) {
        when (id) {
            "modes" -> setScreen(modesScreen())
            "files" -> setScreen(filesScreen())
            "log" -> setScreen(logScreen())
            "web" -> setScreen(webScreen())
            "setup" -> setScreen(connectScreen(true))
        }
    }

    private fun toast(m: String) = Toast.makeText(this, m, Toast.LENGTH_SHORT).show()

    // ---------------------------------------------------------------- network
    private fun api(method: String, path: String, body: JSONObject?, cb: (JSONObject) -> Unit) {
        io.execute {
            var result: JSONObject
            try {
                val c = URL("http://$host:$port$path").openConnection() as HttpURLConnection
                c.requestMethod = method
                c.connectTimeout = 5000
                c.readTimeout = 20000
                if (token.isNotEmpty()) c.setRequestProperty("Authorization", "Bearer $token")
                if (body != null) {
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.write(body.toString().toByteArray())
                }
                val code = c.responseCode
                val stream = if (code in 200..299) c.inputStream else c.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
                result = if (text.trimStart().startsWith("{")) JSONObject(text) else JSONObject()
                if (code !in 200..299) result = JSONObject().put("error", result.optString("error", "HTTP $code"))
            } catch (e: Exception) {
                result = JSONObject().put("error", e.message ?: "network error")
            }
            ui.post { cb(result) }
        }
    }

    private fun upload(uri: Uri, kind: String, cb: (String) -> Unit) {
        io.execute {
            try {
                val name = queryName(uri) ?: "upload.bin"
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                val c = URL("http://$host:$port/api/v1/upload?kind=$kind&name=" +
                        java.net.URLEncoder.encode(name, "UTF-8")).openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.doOutput = true
                c.setRequestProperty("Authorization", "Bearer $token")
                c.setRequestProperty("Content-Type", "application/octet-stream")
                c.outputStream.write(bytes ?: ByteArray(0))
                val code = c.responseCode
                ui.post { cb(if (code in 200..299) "uploaded $name" else "upload failed (HTTP $code)") }
            } catch (e: Exception) {
                ui.post { cb("upload failed: ${e.message}") }
            }
        }
    }

    private fun queryName(uri: Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cur ->
            if (cur.moveToFirst()) {
                val i = cur.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0) return cur.getString(i)
            }
        }
        return uri.lastPathSegment
    }

    private fun startPoll() {
        if (polling) return
        polling = true
        ui.post(object : Runnable {
            override fun run() {
                api("GET", "/api/v1/status", null) { r ->
                    val st = r.optJSONObject("status")
                    if (st == null) {
                        status.text = "offline: " + r.optString("error")
                        status.setTextColor(PINK)
                    } else {
                        val active = st.optBoolean("active")
                        status.text = if (active)
                            "TX ${st.optString("mode")} pid ${st.optInt("pid")} ${st.optDouble("elapsed")}s"
                        else "standby"
                        status.setTextColor(if (active) PINK else DIM)
                    }
                }
                ui.postDelayed(this, 3000)
            }
        })
    }

    // ---------------------------------------------------------------- screens
    private fun connectScreen(fromSetup: Boolean): View {
        val s = ScrollView(this)
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        l.setPadding(dp(12), dp(12), dp(12), dp(12))
        l.addView(tv("connect to the Pi", PINK, 15f, true))

        val h = EditText(this); h.hint = "192.168.1.50 or mostly-a-sdr.local"; h.setText(host)
        val p = EditText(this); p.hint = "8765"; p.setText(port.toString())
        p.inputType = InputType.TYPE_CLASS_NUMBER
        val t = EditText(this); t.hint = "api token"; t.setText(token)
        listOf("host" to h, "port" to p, "token" to t).forEach { (label, field) ->
            l.addView(tv(label, DIM, 12f)); l.addView(field)
        }
        l.addView(button("DISCOVER (mDNS)", PINK) { discover(h, p) })
        l.addView(button("CONNECT") {
            host = h.text.toString().trim()
            port = p.text.toString().toIntOrNull() ?: 8765
            token = t.text.toString().trim()
            prefs.edit().putString("host", host).putInt("port", port)
                .putString("token", token).apply()
            api("GET", "/api/v1/status", null) { r ->
                if (r.has("status")) { toast("connected"); switchTab("modes"); loadModes(); startPoll() }
                else toast("failed: " + r.optString("error"))
            }
        })
        l.addView(tv("Tip: the Pi also serves a web UI at http://\$host:\$port/?token=\$token — " +
                "the WEB tab loads it.", DIM, 11f))
        s.addView(l)
        return s
    }

    private fun discover(hostField: EditText, portField: EditText) {
        val nsd = getSystemService(NSD_SERVICE) as NsdManager
        nsd.discoverServices("_masdr._tcp", NsdManager.PROTOCOL_DNS_SD,
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(s: String) { toast("searching…") }
                override fun onServiceFound(info: NsdServiceInfo) {
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(i: NsdServiceInfo, e: Int) {}
                        override fun onServiceResolved(i: NsdServiceInfo) {
                            ui.post {
                                hostField.setText(i.host.hostAddress)
                                portField.setText(i.port.toString())
                                toast("found " + i.serviceName)
                            }
                        }
                    })
                }
                override fun onServiceLost(i: NsdServiceInfo) {}
                override fun onDiscoveryStopped(s: String) {}
                override fun onStartDiscoveryFailed(s: String, e: Int) {}
                override fun onStopDiscoveryFailed(s: String, e: Int) {}
            })
    }

    private fun showConnect() = setScreen(connectScreen(false))

    private fun modesScreen(): View {
        val s = ScrollView(this)
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        l.setPadding(dp(8), dp(8), dp(8), dp(8))
        val cached = modes
        if (cached == null) {
            l.addView(tv("loading modes…", DIM))
            api("GET", "/api/v1/modes", null) { r ->
                if (r.has("modes")) { modes = r.getJSONArray("modes"); setScreen(modesScreen()) }
                else l.addView(tv("error: " + r.optString("error"), PINK))
            }
        } else {
            var group = ""
            for (i in 0 until cached.length()) {
                val m = cached.getJSONObject(i)
                if (m.optString("group") != group) {
                    group = m.optString("group")
                    l.addView(tv("── $group", PINK, 12f, true))
                }
                l.addView(button(m.optString("label")) { modeDialog(m) })
            }
            l.addView(button("refresh catalogue", PINK) {
                api("GET", "/api/v1/modes", null) { r ->
                    if (r.has("modes")) modes = r.getJSONArray("modes")
                    setScreen(modesScreen())
                }
            })
        }
        s.addView(l)
        return s
    }

    private fun modeDialog(mode: JSONObject) {
        val id = mode.optString("id")
        val params = mode.optJSONArray("params") ?: JSONArray()
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(12), dp(12), dp(12), dp(12))
        val fields = ArrayList<Pair<String, View>>()
        val values = HashMap<String, JSONObject>()

        for (i in 0 until params.length()) {
            val p = params.getJSONObject(i)
            val name = p.optString("name")
            values[name] = p
            box.addView(tv(name + (p.optString("unit").let { if (it.isEmpty()) "" else " ($it)" }),
                DIM, 11f))
            val type = p.optString("type")
            val view: View = when (type) {
                "bool" -> CheckBox(this)
                "choice" -> Spinner(this).apply {
                    val choices = p.optJSONArray("choices")
                    val list = ArrayList<String>()
                    for (c in 0 until (choices?.length() ?: 0)) list.add(choices!!.getString(c))
                    adapter = ArrayAdapter(this@MainActivity,
                        android.R.layout.simple_spinner_dropdown_item, list)
                    val def = p.optString("default")
                    val idx = list.indexOf(def); if (idx >= 0) setSelection(idx)
                }
                "number" -> EditText(this).apply {
                    inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                    setText(p.opt("default")?.toString() ?: "")
                }
                else -> EditText(this).apply { setText(p.opt("default")?.toString() ?: "") }
            }
            box.addView(view)
            fields.add(name to view)
        }
        val durField = EditText(this)
        durField.inputType = InputType.TYPE_CLASS_NUMBER
        durField.setText("0")
        box.addView(tv("duration seconds (0 = until stopped)", DIM, 11f))
        box.addView(durField)

        AlertDialog.Builder(this)
            .setTitle(mode.optString("label"))
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("TRANSMIT") { _, _ ->
                val payload = JSONObject()
                val pj = JSONObject()
                for ((name, v) in fields) {
                    val spec = values[name]!!
                    when (spec.optString("type")) {
                        "bool" -> if ((v as CheckBox).isChecked) pj.put(name, true)
                        "choice" -> pj.put(name, (v as Spinner).selectedItem.toString())
                        "number" -> (v as EditText).text.toString().toDoubleOrNull()?.let { pj.put(name, it) }
                        else -> if ((v as EditText).text.isNotEmpty()) pj.put(name, v.text.toString())
                    }
                }
                payload.put("mode", id).put("params", pj)
                payload.put("duration", durField.text.toString().toDoubleOrNull() ?: 0.0)
                payload.put("freq", freqField.text.toString().toDoubleOrNull() ?: freq)
                api("POST", "/api/v1/tx", payload) { r ->
                    toast(if (r.optBoolean("ok")) "TX $id started" else "error: " + r.optString("error"))
                }
            }
            .setNegativeButton("cancel", null)
            .show()
    }

    private fun filesScreen(): View {
        val s = ScrollView(this)
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        l.setPadding(dp(8), dp(8), dp(8), dp(8))
        val kinds = arrayOf("sub", "media", "iq")
        l.addView(tv("file browser", PINK, 15f, true))
        val row = LinearLayout(this); row.orientation = LinearLayout.HORIZONTAL
        kinds.forEach { k ->
            row.addView(button(k.uppercase()) { lastKind = k; setScreen(filesScreen()) })
        }
        l.addView(row)
        l.addView(button("UPLOAD to $lastKind") {
            pendingUploadKind = lastKind
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            i.type = "*/*"; i.addCategory(Intent.CATEGORY_OPENABLE)
            startActivityForResult(i, 4711)
        })
        api("GET", "/api/v1/files?kind=$lastKind", null) { r ->
            val arr = r.optJSONArray("files")
            if (arr == null || arr.length() == 0) l.addView(tv("(empty)", DIM))
            else for (i in 0 until arr.length()) {
                val f = arr.getJSONObject(i)
                val name = f.optString("name")
                val line = LinearLayout(this); line.orientation = LinearLayout.HORIZONTAL
                line.gravity = Gravity.CENTER_VERTICAL
                val label = tv("$name  (${f.optLong("size") / 1024} kB)", FG, 12f)
                line.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                line.addView(button("TX") { txFile(name) })
                line.addView(button("DEL", PINK) {
                    api("DELETE", "/api/v1/file?kind=$lastKind&name=$name", null) {
                        setScreen(filesScreen())
                    }
                })
                l.addView(line)
            }
        }
        s.addView(l)
        return s
    }

    private fun txFile(name: String) {
        val choices = when {
            name.endsWith(".sub") -> arrayOf("sub replay")
            name.endsWith(".iq") -> arrayOf("iq replay")
            name.endsWith(".jpg") -> arrayOf("SSTV", "spectrum painting")
            else -> arrayOf("WFM", "NFM", "AM", "SSB")
        }
        AlertDialog.Builder(this).setTitle("transmit $name")
            .setItems(choices) { _, which ->
                val payload = JSONObject()
                val p = JSONObject().put("file", name)
                val mode = when (choices[which]) {
                    "sub replay" -> { p.put("playback", "once"); p.put("repeat", 3); "sub" }
                    "iq replay" -> { p.put("freq", freq); "play" }
                    "SSTV" -> "sstv"
                    "spectrum painting" -> "spectrum"
                    "WFM" -> { p.put("playback", "loop"); "wfm" }
                    "NFM" -> { p.put("playback", "loop"); "nfm" }
                    "AM" -> { p.put("playback", "loop"); "am" }
                    else -> { p.put("playback", "loop"); "ssb" }
                }
                payload.put("mode", mode).put("params", p)
                api("POST", "/api/v1/tx", payload) { r ->
                    toast(if (r.optBoolean("ok")) "TX $mode" else "error: " + r.optString("error"))
                }
            }.show()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 4711 && resultCode == RESULT_OK) {
            data?.data?.let { upload(it, pendingUploadKind) { msg -> toast(msg); setScreen(filesScreen()) } }
        }
    }

    private fun logScreen(): View {
        val s = ScrollView(this)
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        val out = tv("", FG, 11f)
        l.addView(button("refresh", PINK) {
            api("GET", "/api/v1/log?lines=300", null) { r ->
                val lines = r.optJSONArray("lines")
                val sb = StringBuilder()
                for (i in 0 until (lines?.length() ?: 0)) sb.append(lines!!.getString(i)).append("\n")
                out.text = sb.toString()
            }
        })
        l.addView(out)
        api("GET", "/api/v1/log?lines=300", null) { r ->
            val lines = r.optJSONArray("lines")
            val sb = StringBuilder()
            for (i in 0 until (lines?.length() ?: 0)) sb.append(lines!!.getString(i)).append("\n")
            out.text = sb.toString()
        }
        s.addView(l)
        return s
    }

    private fun webScreen(): View {
        val w = WebView(this)
        w.setBackgroundColor(BG)
        webView = w
        w.loadUrl("http://$host:$port/?token=$token")
        return w
    }
}
KT_EOF

	$SUDO tee "${A}/build-apk.sh" >/dev/null <<'BUILD_EOF'
#!/usr/bin/env bash
# Build the mostly-a-SDR remote APK. Needs JDK 17 + Android SDK (or Android Studio).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x ./gradlew ]; then GRADLE=./gradlew
elif command -v gradle >/dev/null; then GRADLE=gradle
else
  echo "no gradle found. Either install gradle, or open this folder in Android Studio."
  echo "Android SDK path goes into local.properties: sdk.dir=/path/to/Android/Sdk"
  exit 1
fi
if [ ! -x ./gradlew ] && command -v gradle >/dev/null; then gradle wrapper --gradle-version 8.7 || true; fi
$GRADLE assembleDebug
mkdir -p dist
cp -f app/build/outputs/apk/debug/app-debug.apk dist/mostly-a-sdr-remote.apk
echo "APK: $(pwd)/dist/mostly-a-sdr-remote.apk"
BUILD_EOF
	chmod 755 "${A}/build-apk.sh"
	$SUDO chown -R "$(id -un)":"$(id -gn)" "$A" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
#  8. docs
# -----------------------------------------------------------------------------
write_docs() {
	cat > "${OPT_DIR}/README.md" <<DOC_EOF
# mostly-a-SDR remote API

Installed by \`one-file-installer.sh\`. Version ${API_VERSION}.

* Service:  \`systemctl status ${APP_NAME}\`
* Config:   \`${CONF_FILE}\`
* Logs:     \`journalctl -u ${APP_NAME} -f\` or \`${LOG_DIR}/api.log\`
* Web UI:   \`http://<pi>:${PORT}/?token=<token>\`
* CLI:      \`sdrctl pair | status | modes | tx <mode> k=v | stop | ls sub\`
* mDNS:     \`_masdr._tcp\` on port ${PORT}

## API

All endpoints live under \`/api/v1\` and need \`Authorization: Bearer <token>\`
(except \`/health\` and \`/ping\`). \`GET /api/v1/\` lists everything.

\`\`\`bash
T=\$(python3 -c "import json;print(json.load(open('${CONF_FILE}'))['token'])")
curl -H "Authorization: Bearer \$T" http://localhost:${PORT}/api/v1/modes
curl -H "Authorization: Bearer \$T" -H 'Content-Type: application/json' \\
  -d '{"mode":"cw","params":{"message":"CQ DE TEST","wpm":12},"duration":30}' \\
  http://localhost:${PORT}/api/v1/tx
curl -H "Authorization: Bearer \$T" -X POST http://localhost:${PORT}/api/v1/stop
\`\`\`

The mode catalogue is generated from the same arguments the whiptail menus use,
so \`/api/v1/modes\` is the source of truth for the Android app and the web UI.

## Android

\`${OPT_DIR}/android\` is a complete Gradle project (Kotlin, no third-party deps).
Run \`./build-apk.sh\` on a machine with JDK 17 + Android SDK, or open it in
Android Studio. It auto-discovers the Pi over mDNS and mirrors the mode catalogue.
DOC_EOF
}

# -----------------------------------------------------------------------------
#  9. uninstall
# -----------------------------------------------------------------------------
do_uninstall() {
	say "uninstalling"
	$SUDO systemctl disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
	$SUDO rm -f "$UNIT" "$AVAHI_SVC" "$SUDOERS" /usr/local/bin/sdrctl
	$SUDO systemctl daemon-reload || true
	$SUDO systemctl restart avahi-daemon >/dev/null 2>&1 || true
	$SUDO rm -rf "$OPT_DIR"
	read -r -p "remove ${CONF_FILE} (token) and ${LOG_DIR}? [y/N] " a || true
	case "${a:-n}" in
		y|Y) $SUDO rm -rf "$CONF_DIR" "$LOG_DIR" "$WORK_DIR" ;;
		*) say "kept ${CONF_DIR} and ${LOG_DIR}" ;;
	esac
	say "done. the rpitx-ui tools and the git clone were left in place."
}

# -----------------------------------------------------------------------------
#  main
# -----------------------------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
	do_uninstall
	exit 0
fi

say "mostly-a-SDR remote API installer v${API_VERSION}"
[ "$DO_DEPS" -eq 1 ] && install_deps || say "skipping dependency install"
[ "$DO_DEPS" -eq 1 ] && install_upstream || say "skipping upstream rpitx-ui build"

prepare_dirs
write_config
write_server
write_web
write_cli
write_docs
[ "$DO_ANDROID" -eq 1 ] && write_android || true

if [ "$DO_SERVICE" -eq 1 ]; then
	write_service
fi

HOSTNAME_LOCAL="$(hostname).local"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
say "=============================================================="
say " mostly-a-SDR remote API is installed"
say "=============================================================="
printf '  web UI    : %shttp://%s:%s/?token=%s%s\n' "$C_G" "$IP" "$PORT" "$TOKEN" "$C_0"
printf '  local     : http://%s:%s/?token=%s\n' "$HOSTNAME_LOCAL" "$PORT" "$TOKEN"
printf '  token     : %s%s%s\n' "$C_P" "$TOKEN" "$C_0"
printf '  config    : %s\n' "$CONF_FILE"
printf '  android   : %s/android  (run ./build-apk.sh)\n' "$OPT_DIR"
printf '  cli       : sdrctl pair | sdrctl tx cw message="CQ" duration=30 | sdrctl stop\n'
echo
say "sanity check:"
command -v curl >/dev/null && curl -fsS "http://127.0.0.1:${PORT}/api/v1/ping" 2>/dev/null | head -c 200 && echo
echo
say "phone: install the app from ${OPT_DIR}/android, or just open the web UI"
say "       and use 'Add to home screen' - no build needed."
command -v qrencode >/dev/null && qrencode -t ANSIUTF8 "http://${IP}:${PORT}/?token=${TOKEN}"
warn "reboot once if the upstream installer touched /boot/firmware/config.txt (gpu_freq)."