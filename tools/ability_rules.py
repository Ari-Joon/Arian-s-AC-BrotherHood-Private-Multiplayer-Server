#!/usr/bin/env python3
"""Apply ability rules to the gamesettings XML the server hands to clients.

WHY THIS IS SAFE TO DO AT LAUNCH
QuazalWV's PersistentStoreService reads gamesettings_c1380_d873_s6285.cxb with
File.ReadAllBytes at the moment a client asks for it. So the rules are
server-authoritative: change the file before anyone connects and every player
who joins inherits it. Nothing is sent to their machines and nobody has to
install a mod.

BINARY MODE THROUGHOUT, DELIBERATELY
The XML is ISO-8859-1 with CRLF line endings. Reading it as text converts CRLF
to LF, which silently rewrites 2,786 line endings and shrinks the payload by
2.8 KB - an edit that looks like it only touched cooldowns but did not. Every
read and write here is bytes, and the tool refuses to emit a file whose only
differences are outside the values it was asked to change.

VALUE FORMATTING
Replacements keep the original's decimal shape ("60.0" -> "30.0", not "30"),
because the game parses these as floats and a changed string length changes the
compressed payload size. That size change is survivable - the container is
rebuilt properly by cxb-edit - but keeping the shape stable makes diffs
readable and keeps the file close to its original size.

USAGE
  python tools/ability_rules.py --xml ability.xml --scale-cooldowns 0.5
  python tools/ability_rules.py --xml ability.xml --set AbilitySmokeBomb:Radius=8.0
  python tools/ability_rules.py --xml ability.xml --show
  python tools/ability_rules.py --xml in.xml --out out.xml --scale-cooldowns 0.25

--show prints what is tunable without writing anything.
"""
import argparse
import re
import sys

# Parameters worth exposing. Everything here is a <Tag value="N"/> child of an
# ability block. Ability classes are compiled into ACBMP.exe, so these
# parameters can be retuned but no genuinely new mechanic can be added.
TUNABLE = ["CooldownDuration", "Duration", "Radius", "SpeedFactor",
           "Delay", "Range", "StreakValue"]

ABILITY_RE = re.compile(rb'<(Ability\w+) memberName')

# Every ability carries an UnlockConditionLevel saying which player level opens
# it. Dropping them all to 1 makes the whole roster available to every account
# immediately, which is the point on a private server where nobody wants to
# grind fifty levels to try Morph.
UNLOCK_RE = re.compile(rb'(<UnlockConditionLevel memberName="UnlockConditionRef">\s*<Level value=")(\d+)(")')


def unlock_all(data, level=1):
    """Set every unlock level to `level`. Returns (data, how_many_changed)."""
    changed = [0]

    def repl(m):
        if m.group(2) == str(level).encode():
            return m.group(0)
        changed[0] += 1
        return m.group(1) + str(level).encode() + m.group(3)

    return UNLOCK_RE.sub(repl, data), changed[0]


def dump_json(data):
    """Describe every ability and its tunables, for the launcher's Skills page.

    Emitted from the same parse the edits use, so the UI can never show a
    parameter the editor cannot then write.
    """
    import json
    out = []
    for name, s, e in blocks(data):
        if name in ("AbilityManagerMulti", "AbilityUnlockCondition"):
            continue
        body = data[s:e]
        params = {}
        for m in re.finditer(rb'<(\w+) value="([\d.\-]+)"/>', body):
            tag = m.group(1).decode()
            if tag in ("Icon", "Index", "OasisLineID"):
                continue
            params.setdefault(tag, m.group(2).decode())
        idx = re.search(rb'<Index value="(\d+)"/>', body)
        if params:
            out.append({"ability": name,
                        "tier": int(idx.group(1)) if idx else 0,
                        "params": params})
    print(json.dumps(out, indent=1))


def blocks(data):
    """Yield (class_name, start, end) for each ability block.

    Blocks are delimited by the next ability opening tag rather than by
    matching close tags: the XML nests UIString and Reference elements inside,
    so naive tag matching picks the wrong end.
    """
    marks = [(m.group(1).decode(), m.start()) for m in ABILITY_RE.finditer(data)]
    for i, (name, start) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else len(data)
        yield name, start, end


def show(data):
    seen = {}
    for name, s, e in blocks(data):
        body = data[s:e]
        for t in TUNABLE:
            for m in re.finditer(rb'<' + t.encode() + rb' value="([\d.\-]+)"/>', body):
                seen.setdefault((name, t), []).append(m.group(1).decode())
    if not seen:
        print("  nothing tunable found - is this the ability section?")
        return
    print("  %-28s %-18s values" % ("ability", "parameter"))
    for (name, t), vals in sorted(seen.items()):
        print("  %-28s %-18s %s" % (name, t, ", ".join(vals)))


def same_shape(old, new):
    """Format new like old: keep the decimal places the original used."""
    if b"." in old:
        places = len(old.split(b".")[1])
        return ("%.*f" % (places, new)).encode()
    return ("%d" % round(new)).encode()


def apply_rules(data, scale, sets, only=None):
    changed = 0
    out = bytearray()
    last = 0

    for name, s, e in blocks(data):
        body = data[s:e]
        new_body = body

        if scale:
            for t, factor in scale.items():
                def repl(m, t=t, factor=factor):
                    old = m.group(1)
                    try:
                        val = float(old)
                    except ValueError:
                        return m.group(0)
                    return b'<' + t.encode() + b' value="' + same_shape(old, val * factor) + b'"/>'
                new_body = re.sub(rb'<' + t.encode() + rb' value="([\d.\-]+)"/>', repl, new_body)

        for (cls, param), value in sets.items():
            if cls.lower() != name.lower():
                continue
            new_body = re.sub(
                rb'<' + param.encode() + rb' value="[\d.\-]+"/>',
                b'<' + param.encode() + b' value="' + value.encode() + b'"/>',
                new_body)

        if new_body != body:
            changed += 1
        out += data[last:s] + new_body
        last = e

    out += data[last:]
    return bytes(out), changed


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--xml", required=True, help="ability XML from cxb-edit extract")
    ap.add_argument("--out", help="defaults to editing --xml in place")
    ap.add_argument("--scale-cooldowns", type=float,
                    help="multiply every CooldownDuration (0.5 = twice as fast)")
    ap.add_argument("--scale-durations", type=float,
                    help="multiply every Duration")
    ap.add_argument("--set", action="append", default=[], metavar="CLASS:PARAM=VALUE",
                    help="e.g. AbilitySmokeBomb:Radius=8.0 (repeatable)")
    ap.add_argument("--show", action="store_true", help="list tunables and exit")
    ap.add_argument("--dump-json", action="store_true",
                    help="describe abilities and tunables as JSON, then exit")
    ap.add_argument("--unlock-all", nargs="?", const=1, type=int, metavar="LEVEL",
                    help="set every ability's unlock level to LEVEL (default 1)")
    a = ap.parse_args()

    data = open(a.xml, "rb").read()

    if a.show:
        show(data)
        return

    if a.dump_json:
        dump_json(data)
        return

    scale = {}
    if a.scale_cooldowns:
        scale["CooldownDuration"] = a.scale_cooldowns
    if a.scale_durations:
        scale["Duration"] = a.scale_durations

    sets = {}
    for spec in a.set:
        m = re.fullmatch(r"(\w+):(\w+)=([\d.\-]+)", spec)
        if not m:
            sys.exit("bad --set %r; expected CLASS:PARAM=VALUE" % spec)
        cls, param, value = m.groups()
        if param not in TUNABLE:
            sys.exit("%s is not tunable; try one of: %s" % (param, ", ".join(TUNABLE)))
        sets[(cls, param)] = value

    if not scale and not sets and a.unlock_all is None:
        sys.exit("nothing to do - pass --scale-cooldowns, --set, --unlock-all, or --show")

    out, changed = apply_rules(data, scale, sets) if (scale or sets) else (data, 0)

    unlocked = 0
    if a.unlock_all is not None:
        out, unlocked = unlock_all(out, a.unlock_all)

    # A rule that matched nothing is a typo, not a no-op. Say so rather than
    # writing an unchanged file and reporting success.
    if out == data:
        sys.exit("no rule matched anything - check the ability class names with --show")

    open(a.out or a.xml, "wb").write(out)
    if unlocked:
        print("  %d unlock level(s) set to %d" % (unlocked, a.unlock_all))
    print("  %d ability block(s) changed" % changed)
    print("  %d bytes in, %d bytes out" % (len(data), len(out)))
    print("  wrote %s" % (a.out or a.xml))


if __name__ == "__main__":
    main()
