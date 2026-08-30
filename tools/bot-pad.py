r"""
Drive a bot client with a virtual gamepad, without stealing the player's focus.

WHY A GAMEPAD AND NOT KEYSTROKES. warm-body.ps1 injects keyboard scancodes, and
SendInput goes to whatever window is in FRONT. Driving a bot that way takes the
keyboard away from the player, so bots and playing are mutually exclusive.
XInput is polled by the process rather than delivered to a focused window, so a
virtual pad reaches a background client and the player keeps their own window.

WHY THIS IS NEEDED AT ALL. XInput is also GLOBAL: two clients on one machine
both read pad 0 by default, so the second character mirrors the first. Move your
controller and the "bot" climbs and runs with you, which looks convincingly like
behaviour and is nothing of the sort. Launch the bot with -UserIndex 1 (the
launcher's switch for /userindex) so it reads this pad instead of yours.

    python bot-pad.py --check                 # which XInput slots are in use
    python bot-pad.py --idle --seconds 300    # hold a pad, send NOTHING
    python bot-pad.py --wander --seconds 300  # walk about at random

--idle exists for a specific experiment. A bot has never actually been idle in a
match: it was always mirroring the player, so "does an untouched bot get kicked"
has never been tested. Holding a pad that sends nothing is what makes that
question answerable.

WHAT THIS IS NOT. It has no perception - it cannot see the screen, find a target
or react. It moves. That is enough for presence, which is what ability
challenges need. bot_vm.py is where actual behaviour would go, and its
perception layer is still unimplemented.
"""
import argparse
import math
import random
import sys
import time


def check():
    """Report which XInput slots are occupied, so an index can be chosen."""
    try:
        import ctypes
        from ctypes import wintypes
    except Exception as e:
        print(f"  cannot load ctypes: {e}")
        return 1

    class XINPUT_GAMEPAD(ctypes.Structure):
        _fields_ = [("wButtons", wintypes.WORD), ("bLeftTrigger", ctypes.c_ubyte),
                    ("bRightTrigger", ctypes.c_ubyte), ("sThumbLX", ctypes.c_short),
                    ("sThumbLY", ctypes.c_short), ("sThumbRX", ctypes.c_short),
                    ("sThumbRY", ctypes.c_short)]

    class XINPUT_STATE(ctypes.Structure):
        _fields_ = [("dwPacketNumber", wintypes.DWORD), ("Gamepad", XINPUT_GAMEPAD)]

    dll = None
    for name in ("xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll"):
        try:
            dll = ctypes.WinDLL(name)
            break
        except OSError:
            continue
    if dll is None:
        print("  no XInput DLL found")
        return 1
    print(f"  using {name}")
    for i in range(4):
        st = XINPUT_STATE()
        # 0 == ERROR_SUCCESS, 1167 == ERROR_DEVICE_NOT_CONNECTED
        rc = dll.XInputGetState(i, ctypes.byref(st))
        print(f"   slot {i}: {'CONNECTED' if rc == 0 else 'empty'}")
    return 0


def run(mode, seconds, seed):
    try:
        import vgamepad as vg
    except ImportError:
        print("  vgamepad is not installed:  python -m pip install vgamepad")
        return 1

    rng = random.Random(seed)
    pad = vg.VX360Gamepad()
    # Creating the pad is what claims an XInput slot; it must stay alive for the
    # whole run, which is why this holds the object rather than firing and
    # exiting.
    print(f"  virtual pad created ({mode}) - run --check in another shell to see its slot")
    print("  Ctrl+C to stop")

    end = time.time() + seconds
    heading = rng.uniform(0, 2 * math.pi)
    next_turn = 0.0
    try:
        while time.time() < end:
            now = time.time()
            if mode == 'idle':
                # Deliberately nothing. The pad exists so the client has an input
                # device of its own and stops sharing the player's.
                time.sleep(0.5)
                continue

            if now >= next_turn:
                heading += rng.uniform(-1.4, 1.4)
                next_turn = now + rng.uniform(1.5, 4.0)
                # Occasional sprint. A is held rather than tapped - in this game
                # high profile is a hold, not a toggle.
                if rng.random() < 0.25:
                    pad.press_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
                else:
                    pad.release_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_A)

            x = max(-1.0, min(1.0, math.cos(heading)))
            y = max(-1.0, min(1.0, math.sin(heading)))
            pad.left_joystick_float(x_value_float=x, y_value_float=y)
            pad.update()
            time.sleep(0.05)
    except KeyboardInterrupt:
        print("\n  stopped")
    finally:
        pad.reset()
        pad.update()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--idle', action='store_true')
    ap.add_argument('--wander', action='store_true')
    ap.add_argument('--seconds', type=int, default=300)
    ap.add_argument('--seed', type=int, default=None)
    a = ap.parse_args()

    if a.check:
        return check()
    if a.idle:
        return run('idle', a.seconds, a.seed)
    if a.wander:
        return run('wander', a.seconds, a.seed)
    ap.print_help()
    return 0


if __name__ == '__main__':
    sys.exit(main())
