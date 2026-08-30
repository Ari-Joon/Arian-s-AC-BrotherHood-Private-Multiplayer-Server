r"""
Capture a bot client's own screen. The first half of perception.

WHY THIS IS THE BLOCKER. bot_vm.py decides well and sees nothing:
ScreenPerception returns no contacts because locating the HUD in screen space
was never solved, so the tiers have no input and the bots stand still. This is
the layer that fixes that, built bottom-up: capture first, then find the HUD in
the capture, then turn HUD state into contacts.

CAPTURED FROM THE BACKGROUND, DELIBERATELY. A bot's window is never in front -
the player is using theirs - so BitBlt off the screen is useless: it would grab
whatever is covering it. PrintWindow asks the window to render itself into a
bitmap whether or not it is visible, which is the only approach that works
while someone else is playing.

    python perception.py --list
    python perception.py --account Bot1 --capture frame.png
    python perception.py --account Bot1 --capture frame.png --grid

--grid draws labelled 10% gridlines over the shot. HUD elements have to be
located by eye once before anything can read them automatically, and a bare
screenshot makes that guesswork.
"""
import argparse
import ctypes
import sys
from ctypes import wintypes

user32 = ctypes.WinDLL('user32', use_last_error=True)
gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)

# PrintWindow(hwnd, hdc, flags). 2 == PW_RENDERFULLCONTENT, which is what makes
# it work for windows that render through DirectX rather than plain GDI.
PW_RENDERFULLCONTENT = 2
SRCCOPY = 0x00CC0020


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
                ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
                ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def clients():
    """Every ACBMP window, with the account it was launched under."""
    import subprocess
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Get-CimInstance Win32_Process -Filter \"Name='ACBMP.exe'\" | "
         r"ForEach-Object { $a='?'; if ($_.CommandLine -match '/onlineUser:(\S+)') "
         "{ $a=$matches[1] }; \"$($_.ProcessId) $a\" }"],
        capture_output=True, text=True)
    found = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            found.append((int(parts[0]), parts[1]))
    # Map pid -> hwnd. A process can own several windows; the one with a title
    # and a sane size is the game.
    result = []
    for pid, account in found:
        hwnds = []

        @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def cb(hwnd, _):
            p = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
            if p.value == pid and user32.IsWindowVisible(hwnd):
                r = wintypes.RECT()
                user32.GetClientRect(hwnd, ctypes.byref(r))
                if r.right > 200 and r.bottom > 200:
                    hwnds.append((hwnd, r.right, r.bottom))
            return True

        user32.EnumWindows(cb, 0)
        if hwnds:
            hwnd, w, h = max(hwnds, key=lambda t: t[1] * t[2])
            result.append((pid, account, hwnd, w, h))
    return result


def grab(hwnd, w, h):
    """Render the window into a bitmap and return raw BGRA bytes."""
    hdc = user32.GetWindowDC(hwnd)
    mem = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mem, bmp)
    ok = user32.PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT)
    if not ok:
        # Some renderers ignore PrintWindow; a straight blit of the window DC is
        # the fallback, and it only works if nothing covers the window.
        gdi32.BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h          # negative: top-down rows
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bi), 0)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(hwnd, hdc)
    return bytes(buf)


def save(raw, w, h, path, grid=False):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("  Pillow is needed to write the image:  python -m pip install pillow")
        return 1
    img = Image.frombuffer("RGBA", (w, h), raw, "raw", "BGRA", 0, 1).convert("RGB")
    if grid:
        d = ImageDraw.Draw(img)
        for i in range(1, 10):
            x, y = w * i // 10, h * i // 10
            d.line([(x, 0), (x, h)], fill=(255, 0, 0), width=1)
            d.line([(0, y), (w, y)], fill=(255, 0, 0), width=1)
            d.text((x + 3, 3), f"{i*10}%", fill=(255, 0, 0))
            d.text((3, y + 3), f"{i*10}%", fill=(255, 0, 0))
    img.save(path)
    print(f"  wrote {path}  ({w}x{h})")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--account', default='Bot1')
    ap.add_argument('--capture')
    ap.add_argument('--grid', action='store_true')
    a = ap.parse_args()

    found = clients()
    if a.list or not a.capture:
        if not found:
            print("  no ACBMP windows found")
            return 1
        for pid, acct, hwnd, w, h in found:
            print(f"   pid {pid:<7} {acct:<12} hwnd 0x{hwnd:X}  client {w}x{h}")
        return 0

    match = [f for f in found if f[1].lower() == a.account.lower()]
    if not match:
        print(f"  no window for account {a.account!r} "
              f"(have: {', '.join(f[1] for f in found) or 'none'})")
        return 1
    pid, acct, hwnd, w, h = match[0]
    print(f"  capturing {acct} (pid {pid}, {w}x{h})")
    return save(grab(hwnd, w, h), w, h, a.capture, a.grid)


if __name__ == '__main__':
    sys.exit(main())
