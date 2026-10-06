#!/usr/bin/env python3
"""Compare device traces with the S24 Ultra first when present

Usage:
  python3 tools/compare_traces.py frontend/out/<capture dir>
  python3 tools/compare_traces.py a.log b.log

"""

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

LINE = re.compile(r"\((\s*\d+)\):\s*miuchio\.trace\|(\d+)\|t=(\d+)\|([^|\s]+)(?:\|dur=(\d+))?(.*)$")
FIELD = re.compile(r"(\w+)=(\S+)")
HEADER = re.compile(r"#\s*miuchio\.capture\s+(.*)")

# Attribute frame timings to the most recent screen marker
PHASES = [
    ("app.main", "startup"),
    ("onboarding.load.start", "onboarding"),
    ("onboarding.clip", "sign in"),
    ("coldstart.identity.start", "shelf"),
    ("sync.albumKeys.start", "shelf"),
    ("album.open", "album"),
    ("media.fullImageToFrame.start", "photo"),
    ("upload.item.start", "upload"),
]
PHASE_OF = dict(PHASES)
PHASE_ORDER = list(dict.fromkeys(p for _, p in PHASES))


class Capture:
    def __init__(self, path):
        self.path = path
        self.meta = {}
        self.spans = defaultdict(list)
        self.fails = defaultdict(int)
        self.events = defaultdict(list)
        self.frames = defaultdict(list)
        self.runs = 0
        self._parse()

    @property
    def label(self):
        return self.meta.get("model") or self.path.stem

    def _parse(self):
        phase = "startup"
        last_pid = None
        for raw in self.path.read_text(errors="replace").splitlines():
            h = HEADER.match(raw)
            if h:
                self.meta.update(FIELD.findall(h.group(1)))
                continue
            m = LINE.search(raw)
            if not m:
                continue
            pid, _seq, _t, name, dur, rest = m.groups()
            fields = dict(FIELD.findall(rest))
            if pid != last_pid:
                last_pid = pid
                self.runs += 1
                phase = "startup"
            phase = PHASE_OF.get(name, phase)
            if name.endswith(".end") and dur is not None:
                self.spans[self._key(name[:-4], fields)].append(int(dur))
            elif name.endswith(".fail"):
                self.fails[self._key(name[:-5], fields)] += 1
            elif name == "frames":
                self.frames[phase].append(fields)
            elif not name.endswith(".start"):
                self.events[name].append(fields)

    @staticmethod
    def _key(name, fields):
        if name == "api.request" and "route" in fields:
            route = re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "{id}", fields["route"])
            route = re.sub(r"/\d+(?=/|$)", "/{n}", route)
            return f"api {fields.get('method', '')} {route}"
        return name


def med(xs):
    return statistics.median(xs) if xs else None


def p90(xs):
    if not xs:
        return None
    s = sorted(xs)
    return s[round((len(s) - 1) * 0.9)]


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.0f}" if v >= 10 else f"{v:.1f}"


def table(head, rows):
    widths = [max(len(str(r[i])) for r in [head] + rows) for i in range(len(head))]
    line = lambda r: "  ".join(str(c).ljust(widths[i]) if i == 0 else str(c).rjust(widths[i]) for i, c in enumerate(r))
    print(line(head))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(line(r))


def section(title):
    print(f"\n== {title} ==")


def show_events(caps, name, keys):
    rows = []
    for c in caps:
        for e in c.events.get(name, []) or [{}]:
            rows.append([c.label] + [e.get(k, "-") for k in keys])
    table(["phone"] + keys, rows)


def main(args):
    paths = []
    for a in args:
        p = Path(a)
        paths += sorted(p.glob("*.log")) if p.is_dir() else [p]
    if len(paths) < 2:
        sys.exit(f"need at least two phone logs, found {len(paths)}: {[str(p) for p in paths]}")
    caps = [Capture(p) for p in paths]
    caps.sort(key=lambda c: not c.label.startswith("SM-S928"))
    for other in caps[1:]:
        report(caps[0], other)


def report(a, b):
    caps = [a, b]

    section("Phones")
    table(["phone", "android", "app launches"],
          [[c.label, c.meta.get("android", "-"), c.runs] for c in caps])
    print()
    show_events(caps, "device", ["cores", "hz", "dpr", "px"])
    print()
    show_events(caps, "keystore.probe", ["level", "bytes", "entries", "load_ms", "error"])

    section("Onboarding camera (speed 1.00 = plays at its intended pace)")
    show_events(caps, "onboarding.tier", ["tier", "probe", "budget"])
    print()
    show_events(caps, "onboarding.clip",
                ["tier", "speed", "intended_ms", "wall_ms", "shown", "skipped", "starved",
                 "settled", "decode50", "decode90", "decodeMax", "depth", "w"])
    print(f"\nload to first frame (ms): {a.label} {fmt(med(a.spans.get('onboarding.load', [])))}"
          f" | {b.label} {fmt(med(b.spans.get('onboarding.load', [])))}")

    section(f"Frame timing by screen (ms; late = missed the refresh deadline)")
    rows = []
    for phase in PHASE_ORDER:
        for c in caps:
            ws = c.frames.get(phase)
            if not ws:
                continue
            n = sum(int(w["n"]) for w in ws)
            late = sum(int(w["late"]) for w in ws)
            val = lambda k: [float(w[k]) for w in ws if k in w]
            rows.append([phase, c.label, n, f"{100 * late / n:.0f}%" if n else "-",
                         fmt(med(val("build50"))), fmt(med(val("build90"))),
                         fmt(med(val("raster50"))), fmt(med(val("raster90"))),
                         fmt(max(val("total90"), default=None))])
    table(["screen", "phone", "frames", "late", "build50", "build90", "raster50", "raster90", "worst total90"], rows)

    section(f"Every timed step, biggest extra time on {b.label} first (ms)")
    names = set(a.spans) | set(b.spans)
    rows = []
    for n in names:
        xa, xb = a.spans.get(n, []), b.spans.get(n, [])
        ma, mb = med(xa), med(xb)
        extra = (mb - ma) if ma is not None and mb is not None else None
        ratio = f"{mb / ma:.1f}x" if ma and mb is not None else "-"
        rows.append((extra if extra is not None else -1e9, [
            n, len(xa), fmt(ma), fmt(p90(xa)), len(xb), fmt(mb), fmt(p90(xb)), ratio, fmt(extra)]))
    rows.sort(key=lambda r: r[0], reverse=True)
    head = ["step", f"n {a.label}", "median", "p90", f"n {b.label}", "median", "p90", "slower by", "extra"]
    table(head, [r for _, r in rows])

    fails = set(a.fails) | set(b.fails)
    if fails:
        section("Failures")
        table(["step", a.label, b.label], [[f, a.fails.get(f, 0), b.fails.get(f, 0)] for f in sorted(fails)])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
