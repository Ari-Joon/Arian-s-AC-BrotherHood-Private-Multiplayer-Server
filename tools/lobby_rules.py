"""
Read and rewrite the player-count gates on a game mode.

WHY THIS EXISTS. A private lobby refuses to launch with "There are not
enough members in your group to play this mode in a PRIVATE session" and
LAUNCH stays grey. That gate is DATA, not code: every mode carries a
PrivateMinPlayers, and it ships as 2 to 4 depending on the mode.

That matters because the gamesettings .cxb is server-authoritative - the
server hands it to every client on connect. So the gate can be lifted
without patching ACBMP.exe and without anyone installing anything. A long
detour through the server's notification layer was spent trying to fake a
full lobby instead; none of it was needed, and none of it worked, because
the client's roster is local state.

  MinPlayers         how many are needed to start via public matchmaking
  PrivateMinPlayers  how many are needed to start a PRIVATE lobby
  MaxPlayers         ceiling, left alone

Operates on one section's XML as extracted by cxb-edit.
"""
import argparse
import codecs
import re
import sys

# MinPlayers is a substring of PrivateMinPlayers and of NeedsMinPlayersReady.
# The lookbehind excludes the first; requiring digits excludes the second,
# whose value is "true".
RE_MIN = re.compile(r'(?<!Private)\bMinPlayers="(\d+)"')
RE_PRIV = re.compile(r'\bPrivateMinPlayers="(\d+)"')
RE_MAX = re.compile(r'\bMaxPlayers="(\d+)"')
RE_NAME = re.compile(r'<GameMode\s+Name="([^"]*)"')


def read(path):
    """Return (text, bom, encoding) without altering a single byte we rewrite.

    Two ways this file has already been corrupted silently, both of which the
    container repacks happily and cxb-edit's own verify accepts, and both of
    which make the game drop its connection at the loading screen:

      newline=''   without it, universal-newline translation rewrites every
                   CRLF as LF and the section loses a byte per line - 94 on a
                   change that swaps single digits for single digits.
      utf-8-sig    tolerant on read, but on WRITE it always prepends a BOM.
                   These sections ship without one, so writing added 3 bytes.

    So: detect the BOM, strip it for editing, and put back exactly what was
    there.
    """
    raw = open(path, 'rb').read()
    bom = b''
    if raw.startswith(codecs.BOM_UTF8):
        bom, raw = raw[:3], raw[3:]
    return raw.decode('utf-8'), bom


def write(path, text, bom):
    with open(path, 'wb') as fh:
        fh.write(bom + text.encode('utf-8'))


def report(text):
    name = RE_NAME.search(text)
    mn, pv, mx = RE_MIN.search(text), RE_PRIV.search(text), RE_MAX.search(text)
    return {
        'name': name.group(1) if name else '?',
        'min': int(mn.group(1)) if mn else None,
        'private_min': int(pv.group(1)) if pv else None,
        'max': int(mx.group(1)) if mx else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xml', required=True)
    ap.add_argument('--private-min', type=int)
    ap.add_argument('--min', type=int)
    ap.add_argument('--show', action='store_true')
    a = ap.parse_args()

    text, bom = read(a.xml)
    before = report(text)

    if a.show or (a.private_min is None and a.min is None):
        print(f"  {before['name']:<16} min={before['min']} "
              f"private_min={before['private_min']} max={before['max']}")
        return 0

    # A mode with no PrivateMinPlayers attribute is not a mode this can gate;
    # writing the file anyway would silently report success on a no-op.
    if a.private_min is not None and before['private_min'] is None:
        print(f"  {a.xml}: no PrivateMinPlayers attribute - not changed", file=sys.stderr)
        return 1

    if a.private_min is not None:
        text = RE_PRIV.sub(f'PrivateMinPlayers="{a.private_min}"', text)
    if a.min is not None:
        text = RE_MIN.sub(f'MinPlayers="{a.min}"', text)

    after = report(text)
    if after == before:
        print(f"  {before['name']:<16} already at those values")
        return 0

    write(a.xml, text, bom)
    print(f"  {before['name']:<16} min {before['min']}->{after['min']}  "
          f"private_min {before['private_min']}->{after['private_min']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
