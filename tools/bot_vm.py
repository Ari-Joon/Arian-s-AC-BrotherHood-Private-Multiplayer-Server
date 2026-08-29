#!/usr/bin/env python3
"""
A behaviour VM for Brotherhood multiplayer bots.

WHAT THIS IS
------------
Brotherhood's AI is compiled into ACBMP.exe and matches are peer-to-peer, so
nothing can be injected. A bot here is a *player*: its own account, its own
game instance, driven by synthetic input. That is the only honest way to put
another body in a lobby.

It also means a bot cannot cheat even if we wanted it to. There is no position
feed and no entity list. It knows what is on screen, which is exactly the
constraint asked for - bots go off the face and the direction of their target,
nothing else.

THE VM
------
Behaviour is a small instruction set, the way mission scripts drive a character
to a location:

    GOTO <waypoint>   walk to a named spot, correcting heading as it goes
    WANDER            drift plausibly, no destination
    LOOK <bearing>    turn to face something
    OBSERVE <ticks>   hold still and accumulate confidence about a contact
    STALK             close distance at walking pace, keeping crowd between
    PURSUE            commit, sprint, break blend
    KILL              execute when in range
    BLEND <ticks>     hide in a crowd and reset suspicion
    WAIT <ticks>      do nothing

A program is a dict of state -> instruction list. The tier decides which
program runs and how patient, how certain and how sloppy the bot is.

CONFIDENCE, NOT OMNISCIENCE
---------------------------
Perception returns Contacts carrying only what a human could read:

    bearing    where on screen, in degrees from centre
    distance   apparent, from silhouette height - not a real distance
    facing     which way they are pointing relative to the bot
    match      how well their appearance fits the persona being hunted

A contact starts ambiguous. Watching it raises or lowers confidence, and each
tier needs a different amount before committing. This is what produces the
running and chasing: a low tier commits on weak evidence and is often wrong,
a high tier waits for certainty and gets a silent kill.

WHAT IS VERIFIED AND WHAT IS NOT
--------------------------------
Everything above the perception boundary runs offline against a simulated
world (--simulate), so the state machine, the tiers, the navigation and the
tells are all testable without the game.

Perception itself is NOT solved. ScreenPerception needs the compass and target
indicator located in screen space at your resolution and HUD scale, and that
calibration has never been done. Until it is, the bots run against the
simulator only. See tools/acb-bot.ps1 for the input layer and the same caveat.
"""
import argparse
import json
import math
import os
import random
import sys

# --------------------------------------------------------------- personas ---
# The multiplayer roster. Bots pick from these; matching a face against one is
# the whole detection problem, so the name matters to the bot only as a target
# description.
PERSONAS = [
    "Barber", "Blacksmith", "Butcher", "Captain", "Courtesan", "Doctor",
    "Engineer", "Executioner", "Harlequin", "Marquis", "Mercenary", "Noble",
    "Officer", "Priest", "Prowler", "Smuggler", "Thief",
]


# ------------------------------------------------------------------ tiers ---
class Tier:
    """How careful a bot is. The three tiers differ only in these numbers."""

    def __init__(self, name, **kw):
        self.name = name
        self.__dict__.update(kw)

    def __repr__(self):
        return "<Tier %s>" % self.name


TIERS = {
    # Wants the silent kill. Waits for near-certainty, closes on foot, uses
    # blend, and will abandon a target rather than break cover by sprinting.
    "assassin": Tier(
        "assassin",
        commit_confidence=0.82,   # how sure before it acts
        observe_ticks=7,          # how long it studies a contact
        sprint_bias=0.08,         # willingness to run, which blows stealth
        blend_bias=0.65,          # willingness to hide and reset
        tell_rate=0.06,           # visible human error per tick
        lose_interest=26,
        approach_range=0.55,      # closes to here before committing
        kill_range=0.88),

    # Balanced. Commits on decent evidence, will chase if the target bolts.
    "hunter": Tier(
        "hunter",
        commit_confidence=0.62,
        observe_ticks=4,
        sprint_bias=0.34,
        blend_bias=0.30,
        tell_rate=0.14,
        lose_interest=18,
        approach_range=0.45,
        kill_range=0.85),

    # Impatient. Runs at weak evidence, chases anything that moves, and is
    # wrong often. This is the tier that creates most of the visible chasing.
    "brute": Tier(
        "brute",
        commit_confidence=0.38,
        observe_ticks=1,
        sprint_bias=0.78,
        blend_bias=0.05,
        tell_rate=0.28,
        lose_interest=11,
        approach_range=0.30,
        kill_range=0.80),
}


# ------------------------------------------------------------ perception ---
class Contact:
    """Everything a bot is allowed to know about another body on screen."""

    __slots__ = ("bearing", "distance", "facing", "match", "moving")

    def __init__(self, bearing, distance, facing, match, moving=False):
        self.bearing = bearing      # degrees from screen centre, -180..180
        self.distance = distance    # 0..1 apparent closeness, 1 = arm's reach
        self.facing = facing        # degrees; 0 = looking straight at the bot
        self.match = match          # 0..1 appearance match to the target
        self.moving = moving

    def __repr__(self):
        return ("contact(bearing=%+.0f dist=%.2f facing=%+.0f match=%.2f%s)"
                % (self.bearing, self.distance, self.facing, self.match,
                   " moving" if self.moving else ""))


class Perception:
    """Interface. Returns what the bot can see this tick."""

    def sense(self):
        raise NotImplementedError


class ScreenPerception(Perception):
    """Read contacts from the game window.

    NOT IMPLEMENTED. The compass and target indicator sit at fixed screen
    positions that depend on resolution and HUD scale, and that calibration has
    not been done. Returning nothing is deliberate: a bot that hallucinates
    contacts is worse than a bot that stands still, and pretending this works
    would make every downstream result meaningless.
    """

    def __init__(self, region=None):
        self.region = region

    def sense(self):
        return []


class SimPerception(Perception):
    """A fake world, so the behaviour above can be tested without the game.

    Bodies drift around the bot. One of them is the real target; the rest are
    civilians who occasionally resemble it, which is what makes the tiers
    behave differently.
    """

    def __init__(self, rng, target_persona, crowd=6):
        self.rng = rng
        self.target_persona = target_persona
        self.bodies = []
        for i in range(crowd):
            self.bodies.append({
                "bearing": rng.uniform(-180, 180),
                "distance": rng.uniform(0.05, 0.5),
                "facing": rng.uniform(-180, 180),
                "is_target": i == 0,
            })

    def step(self, bot_turn=0.0, bot_advance=0.0):
        for b in self.bodies:
            b["bearing"] = wrap(b["bearing"] - bot_turn + self.rng.uniform(-6, 6))
            if abs(b["bearing"]) < 60:
                b["distance"] += bot_advance * self.rng.uniform(0.5, 1.0)
            b["distance"] = clamp(b["distance"] + self.rng.uniform(-0.03, 0.03), 0.02, 1.0)
            b["facing"] = wrap(b["facing"] + self.rng.uniform(-25, 25))

    def sense(self):
        out = []
        for b in self.bodies:
            if abs(b["bearing"]) > 55:          # off screen, not visible
                continue
            # Appearance match degrades with distance, the way a real face does.
            clarity = clamp(b["distance"] * 1.6, 0.0, 1.0)
            if b["is_target"]:
                m = 0.5 + 0.5 * clarity
            else:
                m = self.rng.uniform(0.0, 0.45 + 0.25 * (1 - clarity))
            out.append(Contact(b["bearing"], b["distance"], b["facing"],
                               clamp(m + self.rng.uniform(-0.05, 0.05), 0, 1),
                               moving=True))
        return out


# -------------------------------------------------------------- actuators ---
class Actuator:
    def turn(self, deg): pass
    def advance(self, ms, sprint=False): pass
    def attack(self): pass
    def blend(self): pass
    def idle(self, ms): pass


class TraceActuator(Actuator):
    """Records intent instead of moving anything. Used by --simulate."""

    def __init__(self):
        self.log = []
        self.turned = 0.0
        self.advanced = 0.0

    def turn(self, deg):
        self.turned += deg
        self.log.append(("turn", round(deg, 1)))

    def advance(self, ms, sprint=False):
        self.advanced += (0.06 if sprint else 0.03) * (ms / 400.0)
        self.log.append(("sprint" if sprint else "walk", ms))

    def attack(self): self.log.append(("attack", None))
    def blend(self): self.log.append(("blend", None))
    def idle(self, ms): self.log.append(("idle", ms))


# ---------------------------------------------------------------- helpers ---
def wrap(deg):
    while deg > 180:
        deg -= 360
    while deg < -180:
        deg += 360
    return deg


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


# --------------------------------------------------------------- programs ---
# state -> instructions. GOTO drives the bot to a named waypoint the same way a
# mission script walks a character to a location.
PROGRAMS = {
    "patrol":   [("GOTO", "next"), ("WANDER", None)],
    "suspect":  [("LOOK", "contact"), ("OBSERVE", "tier")],
    "stalk":    [("STALK", None)],
    "pursue":   [("PURSUE", None)],
    "strike":   [("KILL", None)],
    "recover":  [("BLEND", 6), ("WANDER", None)],
}


class Bot:
    def __init__(self, name, persona, target, tier, perception, actuator,
                 waypoints, rng):
        self.name = name
        self.persona = persona
        self.target = target
        self.tier = tier
        self.eyes = perception
        self.act = actuator
        self.waypoints = waypoints
        self.rng = rng
        self.state = "patrol"
        self.confidence = 0.0
        self.locked = None
        self.observed = 0
        self.idle_ticks = 0
        self.wp = 0
        self.kills = 0
        self.mistakes = 0
        self.events = []

    # -- perception -> belief ------------------------------------------------
    def evaluate(self, contacts):
        """Pick the most target-like contact and update confidence about it.

        Only bearing, apparent distance, facing and appearance match are used.
        Nothing here knows which body is really the target.
        """
        if not contacts:
            self.confidence = max(0.0, self.confidence - 0.12)
            return None
        best = max(contacts, key=lambda c: c.match * (0.5 + 0.5 * c.distance))
        # A face read head-on is worth more than one seen from behind.
        head_on = 1.0 - (abs(best.facing) / 180.0) * 0.45
        evidence = best.match * head_on * (0.55 + 0.45 * best.distance)
        # Confidence moves toward the evidence, faster the longer it is watched.
        rate = 0.25 + 0.05 * self.observed
        self.confidence += (evidence - self.confidence) * min(rate, 0.8)
        self.confidence = clamp(self.confidence, 0.0, 1.0)
        return best

    # -- human imperfection --------------------------------------------------
    def tell(self):
        """Bots must not be perfect. Each tell is something a human does."""
        if self.rng.random() >= self.tier.tell_rate:
            return None
        kind = self.rng.choice(
            ["overshoot", "hesitate", "wrong-way", "double-back", "stare"])
        if kind == "overshoot":
            self.act.turn(self.rng.uniform(-45, 45))
        elif kind == "hesitate":
            self.act.idle(self.rng.randint(250, 900))
        elif kind == "wrong-way":
            self.act.turn(self.rng.uniform(-160, 160))
            self.act.advance(self.rng.randint(300, 700))
        elif kind == "double-back":
            self.act.turn(180)
            self.act.advance(self.rng.randint(200, 600))
        else:
            self.act.idle(self.rng.randint(400, 1200))
        return kind

    # -- instructions --------------------------------------------------------
    def run(self, instr, contact):
        op, arg = instr
        if op == "GOTO":
            wp = self.waypoints[self.wp % len(self.waypoints)]
            bearing = wrap(wp["bearing"] - self.act.turned)
            # Steer in steps rather than snapping - a snap reads as a bot.
            self.act.turn(clamp(bearing, -35, 35) + self.rng.uniform(-4, 4))
            self.act.advance(self.rng.randint(500, 1100))
            if self.rng.random() < 0.22:
                self.wp += 1
        elif op == "WANDER":
            self.act.turn(self.rng.uniform(-50, 50))
            self.act.advance(self.rng.randint(300, 900))
        elif op == "LOOK":
            if contact:
                self.act.turn(clamp(contact.bearing, -40, 40))
        elif op == "OBSERVE":
            self.observed += 1
            self.act.idle(self.rng.randint(300, 800))
        elif op == "STALK":
            if contact:
                self.act.turn(clamp(contact.bearing, -25, 25))
            self.act.advance(self.rng.randint(400, 800))
        elif op == "PURSUE":
            if contact:
                self.act.turn(clamp(contact.bearing, -60, 60))
            sprint = self.rng.random() < self.tier.sprint_bias
            self.act.advance(self.rng.randint(500, 900), sprint=sprint)
        elif op == "KILL":
            self.act.attack()
        elif op == "BLEND":
            self.act.blend()
            self.act.idle(self.rng.randint(600, 1400))
        elif op == "WAIT":
            self.act.idle(400)

    # -- one tick ------------------------------------------------------------
    def tick(self):
        contacts = self.eyes.sense()
        contact = self.evaluate(contacts)
        t = self.tier
        prev = self.state

        if contact is None:
            self.idle_ticks += 1
            if self.idle_ticks > t.lose_interest:
                self.state, self.observed, self.locked = "patrol", 0, None
            elif self.state not in ("patrol", "recover"):
                self.state = "patrol"
        else:
            self.idle_ticks = 0
            if self.confidence >= t.commit_confidence:
                if contact.distance >= t.kill_range:
                    self.state = "strike"
                elif contact.distance >= t.approach_range:
                    self.state = "pursue"
                else:
                    # A patient tier closes quietly; an impatient one runs.
                    self.state = ("pursue"
                                  if self.rng.random() < t.sprint_bias
                                  else "stalk")
            elif self.confidence > t.commit_confidence * 0.45:
                self.state = "suspect"
            else:
                self.state = "patrol"

        for instr in PROGRAMS[self.state]:
            self.run(instr, contact)
        told = self.tell()

        if self.state == "strike":
            # Committing on a civilian is exactly the mistake a human makes.
            if contact and contact.match > 0.6:
                self.kills += 1
                self.events.append("kill")
            else:
                self.mistakes += 1
                self.events.append("wrong target")
            self.confidence, self.observed = 0.0, 0
            self.state = "recover"

        return {
            "state": prev if prev == self.state else "%s->%s" % (prev, self.state),
            "confidence": round(self.confidence, 2),
            "contact": contact,
            "tell": told,
        }


# ------------------------------------------------------------------- main ---
def default_waypoints(rng, n=6):
    return [{"name": "wp%d" % i, "bearing": rng.uniform(-180, 180)}
            for i in range(n)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--simulate", action="store_true",
                    help="run against the built-in fake world and print a trace")
    ap.add_argument("--ticks", type=int, default=40)
    ap.add_argument("--bots", type=int, default=3)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--tiers", default="assassin,hunter,brute",
                    help="one tier per bot, in order")
    ap.add_argument("--quiet", action="store_true", help="summary only")
    a = ap.parse_args()

    rng = random.Random(a.seed)
    tiers = [t.strip() for t in a.tiers.split(",") if t.strip()]
    for t in tiers:
        if t not in TIERS:
            sys.exit("unknown tier %r (have: %s)" % (t, ", ".join(TIERS)))

    # Three distinct personas, never the same one twice.
    chosen = rng.sample(PERSONAS, min(a.bots, len(PERSONAS)))
    bots = []
    for i in range(a.bots):
        persona = chosen[i % len(chosen)]
        target = rng.choice([p for p in PERSONAS if p != persona])
        tier = TIERS[tiers[i % len(tiers)]]
        eyes = (SimPerception(rng, target) if a.simulate else ScreenPerception())
        bots.append(Bot("bot%d" % (i + 1), persona, target, tier, eyes,
                        TraceActuator(), default_waypoints(rng), rng))

    print("")
    for b in bots:
        print("  %-6s %-11s tier=%-9s hunting %s"
              % (b.name, b.persona, b.tier.name, b.target))
    print("")

    if not a.simulate:
        print("  ScreenPerception returns nothing until the HUD is calibrated,")
        print("  so the bots would stand still. Run with --simulate to exercise")
        print("  the behaviour, or calibrate perception first.")
        return

    for tick in range(a.ticks):
        for b in bots:
            r = b.tick()
            if isinstance(b.eyes, SimPerception):
                b.eyes.step(bot_turn=b.act.turned, bot_advance=b.act.advanced)
                b.act.turned = b.act.advanced = 0.0
            if not a.quiet and ("->" in r["state"] or r["tell"] or b.events):
                ev = (" !" + b.events.pop()) if b.events else ""
                tl = ("  tell:" + r["tell"]) if r["tell"] else ""
                print("  t%-3d %-6s %-18s conf %.2f%s%s"
                      % (tick, b.name, r["state"], r["confidence"], tl, ev))

    print("")
    print("  %-6s %-9s %-8s %-9s %s" % ("bot", "tier", "kills", "mistakes", "accuracy"))
    for b in bots:
        tot = b.kills + b.mistakes
        acc = ("%.0f%%" % (100.0 * b.kills / tot)) if tot else "-"
        print("  %-6s %-9s %-8d %-9d %s" % (b.name, b.tier.name, b.kills, b.mistakes, acc))
    print("")


if __name__ == "__main__":
    main()
