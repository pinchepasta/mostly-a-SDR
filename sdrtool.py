#!/usr/bin/env python3
"""
sdrtool.py - helper for rtlmenu.sh (mostly-a-SDR), pure Python 3, no dependencies.

Works on the I/Q captures rtl_433 saves with -S (.cu8: unsigned 8 bit, interleaved I/Q).

  info    FILE.cu8                     one-line rtl_433 summary of the capture
  freq    FILE.cu8                     centre frequency in MHz (from the file name)
  sub     FILE.cu8 OUT.sub [--mode ook|fsk]   export as Flipper Zero SubGHz RAW file
  analyze FILE.cu8 OUT.pkt.json        slice an OOK capture into an editable packet model
  fields  PKT                          list the editable fields (name|value)
  set     PKT NAME VALUE               change a field (checksum is recalculated)
  hex     PKT / sethex PKT HEX         show / replace the raw data bits
  addfield PKT "name off len signed div bias"   define a custom field
  checksum PKT [SPEC]                  show / set checksum rule
  render  PKT OUT.cu8 [--sub OUT.sub]  re-encode the (edited) packet as I/Q (+ .sub)

Editor scope: OOK/ASK signals that use pulse-position (PPM) or pulse-width (PWM)
coding - that covers most 433 MHz weather stations (Nexus/Prologue, LaCrosse, ...).
Manchester / FSK signals can still be exported as .sub and replayed, just not edited.

Field layout of a value: value = (raw - bias) / div   (raw is signed if signed=1)
Checksum spec:  "KIND FIRST_BYTE END_BYTE TARGET_BYTE"
                KIND = sum8 | xor8 | crc8:POLY:INIT (hex)      e.g. "crc8:31:00 0 4 4"

Extra device layouts can be added in profiles.json next to this script:
  { "LaCrosse-example": { "match": ["LaCrosse-TX141"], "bits": 40,
      "checksum": "crc8:31:00 0 4 4",
      "fields": [ {"name":"id","off":0,"len":8,"signed":0,"div":1,"bias":0},
                  {"name":"temperature_C","off":12,"len":12,"signed":0,"div":10,"bias":500},
                  {"name":"humidity","off":24,"len":8,"signed":0,"div":1,"bias":0} ] } }
(the layout above is only an example - check it against rtl_433's src/devices/*.c)
"""
import argparse
import collections
import functools
import json
import math
import os
import random
import re
import subprocess
import sys

DEFAULT_RATE = 250000
MIN_BITS = 8            # shorter runs of symbols are not treated as data
GAP_CAP_US = 100000     # cap idle gaps in exported / rendered files


class ToolError(Exception):
    pass


# ---------------------------------------------------------------- file names
def freq_from_name(path, default=433.92e6):
    m = re.search(r'_(\d+(?:\.\d+)?)M_', os.path.basename(path))
    return int(round(float(m.group(1)) * 1e6)) if m else int(default)


def rate_from_name(path):
    m = re.search(r'_(\d+)k(?=[_.])', os.path.basename(path))
    return int(m.group(1)) * 1000 if m else DEFAULT_RATE


# ---------------------------------------------------------------- rtl_433
def rtl433_events(path, rate):
    try:
        r = subprocess.run(["rtl_433", "-r", path, "-s", str(rate), "-F", "json"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    events = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    return events


def summarize(events):
    if events is None:
        return "(rtl_433 not installed)"
    if not events:
        return "(not decoded)"
    e = events[0]
    s = [str(e.get("model", "?"))]
    if "id" in e:
        s.append("id=%s" % e["id"])
    if "channel" in e:
        s.append("ch=%s" % e["channel"])
    for k, u in (("temperature_C", "C"), ("temperature_F", "F")):
        if k in e:
            s.append("%.1f%s" % (e[k], u))
    if "humidity" in e:
        s.append("%s%%" % e["humidity"])
    return " ".join(s)


# ---------------------------------------------------------------- demodulation
def load_cu8(path):
    data = open(path, "rb").read()
    n = len(data) // 2
    if n < 1000:
        raise ToolError("Capture file is empty or too short.")
    return data[0:2 * n:2], data[1:2 * n:2]


def pct(sorted_vals, p):
    return sorted_vals[min(len(sorted_vals) - 1, int(p * (len(sorted_vals) - 1)))]


def smooth(v, n):
    if n <= 1:
        return v
    c = [0.0]
    for x in v:
        c.append(c[-1] + x)
    h, N = n // 2, len(v)
    out = []
    for i in range(N):
        a, b = max(0, i - h), min(N, i + h + 1)
        out.append((c[b] - c[a]) / (b - a))
    return out


def envelope(i, q):
    return smooth([math.hypot(a - 127.5, b - 127.5) for a, b in zip(i, q)], 3)


def ook_levels(i, q):
    env = envelope(i, q)
    s = sorted(env)
    lo, hi = pct(s, 0.10), pct(s, 0.995)
    if hi - lo < 8:
        raise ToolError("No signal found in this capture (too weak or flat).")
    thr = lo + 0.5 * (hi - lo)
    return [1 if x > thr else 0 for x in env]


def fsk_levels(i, q):
    env = envelope(i, q)
    s = sorted(env)
    lo, hi = pct(s, 0.10), pct(s, 0.995)
    if hi - lo < 8:
        raise ToolError("No signal found in this capture (too weak or flat).")
    active = [e > lo + 0.3 * (hi - lo) for e in env]
    pi, pq = i[0] - 127.5, q[0] - 127.5
    fr = [0.0]
    for a, b in zip(i[1:], q[1:]):
        x, y = a - 127.5, b - 127.5
        fr.append(math.atan2(y * pi - x * pq, x * pi + y * pq))
        pi, pq = x, y
    fr = smooth(fr, 5)
    vals = sorted(f for f, a in zip(fr, active) if a)
    if len(vals) < 50:
        raise ToolError("No signal found in this capture.")
    mid = (pct(vals, 0.05) + pct(vals, 0.95)) / 2
    return [1 if (a and f > mid) else 0 for f, a in zip(fr, active)]


def levels_to_runs(levels, rate, min_us=30):
    """0/1 sample levels -> [(level, microseconds)], starting and ending with a 1."""
    minn = max(1, int(round(min_us * rate / 1e6)))
    runs = []
    for l in levels:
        if runs and runs[-1][0] == l:
            runs[-1][1] += 1
        else:
            runs.append([l, 1])
    out = []
    for l, n in runs:                      # swallow glitches shorter than min_us
        if out and n < minn:
            out[-1][1] += n
        elif out and out[-1][0] == l:
            out[-1][1] += n
        else:
            out.append([l, n])
    while out and (out[0][0] == 0 or out[0][1] < minn):
        out.pop(0)
    while out and (out[-1][0] == 0 or out[-1][1] < minn):
        out.pop()
    if not out:
        raise ToolError("No pulses found in this capture.")
    us = 1e6 / rate
    return [(l, max(1, int(round(n * us)))) for l, n in out]


def runs_to_signed(runs):
    return [d if l else -min(d, GAP_CAP_US) for l, d in runs]


def write_sub(path, signed, freq_hz, preset):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        f.write("Filetype: Flipper SubGhz RAW File\nVersion: 1\n")
        f.write("Frequency: %d\nPreset: %s\nProtocol: RAW\n" % (freq_hz, preset))
        for k in range(0, len(signed), 500):
            f.write("RAW_Data: " + " ".join(str(x) for x in signed[k:k + 500]) + "\n")


# ---------------------------------------------------------------- packet model
def cluster(values, tol=0.25):
    cl = []
    for v in sorted(values):
        if cl and abs(v - cl[-1][0] / cl[-1][1]) <= tol * v:
            cl[-1][0] += v
            cl[-1][1] += 1
        else:
            cl.append([float(v), 1])
    return [(s / n, n) for s, n in cl]


def significant(cl, total):
    return [c for c in cl if c[1] >= max(3, 0.08 * total)]


def top2(cl):
    best = sorted(cl, key=lambda c: -c[1])[:2]
    return [c for c, _ in sorted(best)]


def near(v, c, tol=0.35):
    return abs(v - c) <= tol * c


def match(v, centers, tol=0.3):
    best, bd = None, 1e9
    for k, c in enumerate(centers):
        d = abs(v - c) / c
        if d <= tol and d < bd:
            best, bd = k, d
    return best


def pairs_from_runs(runs):
    pairs = []
    for k in range(0, len(runs), 2):
        p = runs[k][1]
        g = runs[k + 1][1] if k + 1 < len(runs) else 20000
        pairs.append((p, g))
    return pairs


def build_model(pairs):
    n = len(pairs)
    pc = significant(cluster([p for p, _ in pairs]), n)
    gc = significant(cluster([g for _, g in pairs]), n)
    if len(pc) == 1 and len(gc) >= 2:
        mode, sym, fixed = "ppm", top2(gc), pc[0][0]
    elif len(gc) == 1 and len(pc) >= 2:
        mode, sym, fixed = "pwm", top2(pc), gc[0][0]
    elif len(pc) >= 2 and len(gc) >= 2:
        raise ToolError("Both pulse and gap widths vary - this looks like Manchester or another "
                        "coding the editor can't handle.\nYou can still export it as .sub or replay it.")
    else:
        raise ToolError("Couldn't find two distinct bit widths in this capture. It may be FSK, "
                        "too noisy, or not a simple PPM/PWM signal.")

    items, cur = [], []

    def flush(tail=None):
        nonlocal cur
        if len(cur) >= MIN_BITS:
            items.append({"t": "row", "bits": "".join(str(b) for b, _, _ in cur), "tail": tail})
        else:
            for _, p, g in cur:
                items.append({"t": "lit", "p": p, "g": g})
        cur = []

    for p, g in pairs:
        if mode == "ppm":
            b = match(g, sym) if near(p, fixed) else None
            if b is None:
                flush()
                items.append({"t": "lit", "p": p, "g": g})
            else:
                cur.append((b, p, g))
        else:
            b = match(p, sym)
            if b is None:
                flush()
                items.append({"t": "lit", "p": p, "g": g})
            else:
                cur.append((b, p, g))
                if not near(g, fixed):      # long gap closes the row
                    flush(tail=g)
    flush()

    rows = [it for it in items if it["t"] == "row"]
    if not rows:
        raise ToolError("No rows of data bits found (need at least %d bits in a row)." % MIN_BITS)
    modal = collections.Counter(len(r["bits"]) for r in rows).most_common(1)[0][0]
    master = collections.Counter(r["bits"] for r in rows if len(r["bits"]) == modal).most_common(1)[0][0]
    keep = []
    for it in items:
        if it["t"] == "row":
            if len(it["bits"]) != modal:
                continue
            it = {"t": "row", "tail": it["tail"]}
        keep.append(it)
    return {"mode": mode, "sym": [round(x) for x in sym], "fixed": round(fixed),
            "items": keep, "master": master}


def model_pairs(m):
    out = []
    for it in m["items"]:
        if it["t"] == "lit":
            out.append((it["p"], it["g"]))
            continue
        bits = m["master"]
        for k, ch in enumerate(bits):
            b = int(ch)
            if m["mode"] == "ppm":
                out.append((m["fixed"], m["sym"][b]))
            else:
                last = k == len(bits) - 1
                out.append((m["sym"][b], it["tail"] if (last and it.get("tail")) else m["fixed"]))
    return out


def render_cu8(pairs, rate, path):
    rng = random.Random(1)
    per_us = rate / 1e6
    buf = bytearray()

    def emit(us, high):
        for _ in range(max(1, int(round(us * per_us)))):
            if high:
                buf.append(228 + rng.randint(-2, 2))
                buf.append(128 + rng.randint(-2, 2))
            else:
                buf.append(128 + rng.randint(-1, 1))
                buf.append(128 + rng.randint(-1, 1))

    emit(20000, False)
    for p, g in pairs:
        emit(p, True)
        emit(min(g, GAP_CAP_US), False)
    emit(20000, False)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(buf)


# ---------------------------------------------------------------- fields / checksum
BUILTIN_PROFILES = {
    # Nexus / Prologue style temperature+humidity sensors (36 bits, no checksum)
    "nexus": {
        "match": ["nexus", "prologue"], "bits": 36, "checksum": None,
        "fields": [
            {"name": "id", "off": 0, "len": 8, "signed": 0, "div": 1, "bias": 0},
            {"name": "battery_ok", "off": 8, "len": 1, "signed": 0, "div": 1, "bias": 0},
            {"name": "channel", "off": 10, "len": 2, "signed": 0, "div": 1, "bias": -1},
            {"name": "temperature_C", "off": 12, "len": 12, "signed": 1, "div": 10, "bias": 0},
            {"name": "humidity", "off": 28, "len": 8, "signed": 0, "div": 1, "bias": 0},
        ],
    }
}


def load_user_profiles():
    path = os.environ.get("SDR_PROFILES") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "profiles.json")
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


def pick_profile(model, bits):
    profs = dict(BUILTIN_PROFILES)
    profs.update(load_user_profiles())
    name = (model or "").lower()
    for pn, p in profs.items():
        keys = [k.lower() for k in p.get("match", [pn])]
        if name and any(name.startswith(k) for k in keys) and p.get("bits", len(bits)) == len(bits):
            return pn, p
    if len(bits) == 36 and bits[24:28] == "1111":       # Nexus layout fingerprint
        return "nexus", BUILTIN_PROFILES["nexus"]
    return None, None


def field_get(bits, f):
    raw = int(bits[f["off"]:f["off"] + f["len"]], 2)
    if f["signed"] and raw >= 1 << (f["len"] - 1):
        raw -= 1 << f["len"]
    return (raw - f["bias"]) / f["div"]


def field_str(bits, f):
    v = field_get(bits, f)
    if f["div"] == 1:
        return "%d" % v
    return "%.*f" % (len(str(int(f["div"]))) - 1, v)


def field_set(bits, f, val):
    ln = f["len"]
    raw = int(round(val * f["div"])) + f["bias"]
    lo, hi = (-(1 << (ln - 1)), (1 << (ln - 1)) - 1) if f["signed"] else (0, (1 << ln) - 1)
    if not lo <= raw <= hi:
        raise ToolError("%s doesn't fit: raw value %d is outside %d..%d (%d bits)." % (val, raw, lo, hi, ln))
    return bits[:f["off"]] + format(raw & ((1 << ln) - 1), "0%db" % ln) + bits[f["off"] + ln:]


def bits_to_bytes(bits):
    pad = bits + "0" * (-len(bits) % 8)
    return [int(pad[k:k + 8], 2) for k in range(0, len(pad), 8)]


def crc8(data, poly, init):
    crc = init
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def apply_checksum(bits, spec):
    if not spec or spec.strip().lower() == "none":
        return bits
    try:
        kind, a, b, t = spec.split()
        a, b, t = int(a), int(b), int(t)
        parts = kind.lower().split(":")
    except ValueError:
        raise ToolError("Bad checksum spec. Use: KIND FIRST END TARGET, e.g.  crc8:31:00 0 4 4")
    bs = bits_to_bytes(bits)
    if not (0 <= a < b <= len(bs)) or not 0 <= t < len(bs):
        raise ToolError("Checksum byte range is outside the %d data bytes." % len(bs))
    data = bs[a:b]
    if parts[0] == "sum8":
        v = sum(data) & 0xFF
    elif parts[0] == "xor8":
        v = functools.reduce(lambda x, y: x ^ y, data, 0)
    elif parts[0] == "crc8" and len(parts) == 3:
        v = crc8(data, int(parts[1], 16), int(parts[2], 16))
    else:
        raise ToolError("Unknown checksum kind '%s' (sum8, xor8, crc8:POLY:INIT)." % kind)
    bs[t] = v
    return "".join(format(x, "08b") for x in bs)[:len(bits)]


def bits_hex(bits):
    pad = bits + "0" * (-len(bits) % 4)
    return format(int(pad, 2), "0%dx" % (len(pad) // 4)).upper()


# ---------------------------------------------------------------- commands
def load_pkt(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        raise ToolError("Packet file %s is missing or damaged - run 'Edit values' again." % path)


def save_pkt(path, m):
    json.dump(m, open(path, "w"), indent=1)


def find_field(m, name):
    for f in m["fields"]:
        if f["name"] == name:
            return f
    raise ToolError("No field called '%s'." % name)


def cmd_info(a):
    print(summarize(rtl433_events(a.cu8, rate_from_name(a.cu8))))


def cmd_freq(a):
    print("%g" % (freq_from_name(a.cu8) / 1e6))


def cmd_sub(a):
    i, q = load_cu8(a.cu8)
    rate = rate_from_name(a.cu8)
    freq = a.freq or freq_from_name(a.cu8)
    levels = ook_levels(i, q) if a.mode == "ook" else fsk_levels(i, q)
    signed = runs_to_signed(levels_to_runs(levels, rate))
    preset = ("FuriHalSubGhzPresetOok650Async" if a.mode == "ook"
              else "FuriHalSubGhzPreset2FSKDev476Async")
    write_sub(a.out, signed, freq, preset)
    print("Saved %s\n%d pulses/gaps, %g MHz, %s\n\nCopy it to the Flipper's SD card (subghz folder)\n"
          "and open it with Sub-GHz > Saved." % (a.out, len(signed), freq / 1e6, a.mode.upper()))


def cmd_analyze(a):
    i, q = load_cu8(a.cu8)
    rate = rate_from_name(a.cu8)
    pairs = pairs_from_runs(levels_to_runs(ook_levels(i, q), rate))
    if len(pairs) < MIN_BITS:
        raise ToolError("Too few pulses in this capture.")
    m = build_model(pairs)
    events = rtl433_events(a.cu8, rate)
    model = events[0].get("model") if events else None
    pname, prof = pick_profile(model, m["master"])
    m.update({"source": os.path.basename(a.cu8), "freq": a.freq or freq_from_name(a.cu8), "rate": rate,
              "model": model, "profile": pname,
              "fields": [dict(f) for f in prof["fields"]] if prof else [],
              "checksum": prof.get("checksum") if prof else None})
    save_pkt(a.pkt, m)
    rows = sum(1 for it in m["items"] if it["t"] == "row")
    print("OOK %s coding: %d data bits x %d repeated rows.\nDecoder: %s\n" %
          (m["mode"].upper(), len(m["master"]), rows, model or "unknown"))
    if prof:
        print("Using field layout '%s'." % pname)
    else:
        print("No field layout known for this signal.\nUse 'Define / add a custom field' (bit layout: see\n"
              "rtl_433 src/devices/<model>.c) or edit the raw hex directly.")


def cmd_fields(a):
    m = load_pkt(a.pkt)
    for f in m["fields"]:
        print("%s|%s" % (f["name"], field_str(m["master"], f)))


def cmd_set(a):
    m = load_pkt(a.pkt)
    f = find_field(m, a.name)
    try:
        val = float(a.value.replace(",", "."))
    except ValueError:
        raise ToolError("'%s' is not a number." % a.value)
    m["master"] = apply_checksum(field_set(m["master"], f, val), m.get("checksum"))
    save_pkt(a.pkt, m)
    print("%s = %s" % (a.name, field_str(m["master"], f)))


def cmd_hex(a):
    print(bits_hex(load_pkt(a.pkt)["master"]))


def cmd_sethex(a):
    m = load_pkt(a.pkt)
    h = re.sub(r"[^0-9a-fA-F]", "", a.hex)
    n = len(m["master"])
    if len(h) != (n + 3) // 4:
        raise ToolError("Need exactly %d hex digits (%d bits), got %d." % ((n + 3) // 4, n, len(h)))
    m["master"] = format(int(h, 16), "0%db" % (len(h) * 4))[:n]
    save_pkt(a.pkt, m)
    print(bits_hex(m["master"]))


def cmd_addfield(a):
    m = load_pkt(a.pkt)
    try:
        name, off, ln, sg, div, bias = a.spec.split()
        f = {"name": name, "off": int(off), "len": int(ln), "signed": int(sg), "div": float(div), "bias": int(bias)}
        if f["div"] == int(f["div"]):
            f["div"] = int(f["div"])
    except ValueError:
        raise ToolError("Use: name offset length signed(0/1) divisor bias\n  e.g. temperature_C 12 12 1 10 0")
    if f["len"] < 1 or f["off"] < 0 or f["off"] + f["len"] > len(m["master"]):
        raise ToolError("Field lies outside the %d data bits." % len(m["master"]))
    m["fields"] = [x for x in m["fields"] if x["name"] != name] + [f]
    save_pkt(a.pkt, m)
    print("Field '%s' = %s" % (name, field_str(m["master"], f)))


def cmd_checksum(a):
    m = load_pkt(a.pkt)
    if a.spec is None:
        print(m.get("checksum") or "none")
        return
    spec = None if a.spec.strip().lower() == "none" else a.spec.strip()
    m["master"] = apply_checksum(m["master"], spec)
    m["checksum"] = spec
    save_pkt(a.pkt, m)
    print(spec or "none")


def cmd_render(a):
    m = load_pkt(a.pkt)
    pairs = model_pairs(m)
    render_cu8(pairs, m["rate"], a.out)
    msg = "Rendered %s\n%d pulses at %g MHz" % (a.out, len(pairs), m["freq"] / 1e6)
    if a.sub:
        signed = [x for p, g in pairs for x in (int(p), -int(min(g, GAP_CAP_US)))]
        write_sub(a.sub, signed, m["freq"], "FuriHalSubGhzPresetOok650Async")
        msg += "\nFlipper file: %s" % a.sub
    print(msg)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *args, **opts):
        p = sp.add_parser(name)
        for x in args:
            p.add_argument(x)
        p.set_defaults(fn=fn)
        return p

    add("info", cmd_info, "cu8")
    add("freq", cmd_freq, "cu8")
    p = add("sub", cmd_sub, "cu8", "out")
    p.add_argument("--mode", choices=["ook", "fsk"], default="ook")
    p.add_argument("--freq", type=int)
    p = add("analyze", cmd_analyze, "cu8", "pkt")
    p.add_argument("--freq", type=int)
    add("fields", cmd_fields, "pkt")
    add("set", cmd_set, "pkt", "name", "value")
    add("hex", cmd_hex, "pkt")
    add("sethex", cmd_sethex, "pkt", "hex")
    add("addfield", cmd_addfield, "pkt", "spec")
    p = add("checksum", cmd_checksum, "pkt")
    p.add_argument("spec", nargs="?")
    p = add("render", cmd_render, "pkt", "out")
    p.add_argument("--sub")

    a = ap.parse_args()
    try:
        a.fn(a)
    except ToolError as e:
        print(e)
        sys.exit(1)


if __name__ == "__main__":
    main()
