#!/usr/bin/env python3
"""
dlv_games.py -- the ONE table of known laserdisc games, shared by pack_dlv.py,
browse_dlv.py and browse_m2v.py so they can never disagree.

  disc rate  = the rate the GAME counts disc frames at (Daphne game/<game>.cpp m_disc_fps).
               It is NOT the m2v's own rate: Dragon's Lair II counts 29.97 over 23.976 files.
  game_id    = the GAME-ID byte the core's MRA sends (<rom index="1"> byte 0).
               0xFF = no board in the core yet; the core never warns about it.
  detect     = lower-case framefile / m2v stems that identify the game automatically.

Add a game here, nowhere else.
"""
import os
from fractions import Fraction

R23976 = (24000, 1001)
R2997  = (30000, 1001)
R25    = (25, 1)

# Rates the core can play. 25 exists only for --game laireuro and is NOT in this set:
# a 25 fps .dlv packs but the core has no PAL path yet, so it will not play correctly.
CORE_RATES = {"23.976": R23976, "29.97": R2997}

GAME_UNKNOWN = 0xFF

#            key          title                          rate     id     detect stems
GAMES = [
    ("lair",         "Dragon's Lair",                R23976, 0x00, ("lair", "dlair")),
    ("ace",          "Space Ace",                    R23976, 0x01, ("ace", "sace")),
    ("thayers",      "Thayer's Quest",               R2997,  0x02, ("thayersquest", "tq", "thayers")),
    ("cliff",        "Cliff Hanger",                 R2997,  0x03, ("ch", "cliff")),
    ("lair2",        "Dragon's Lair II: Time Warp",  R2997,  0x04, ("dl2-framefile", "dl2-00001", "lair2")),
    ("gtg",          "Goal To Go",                   R2997,  0x05, ("gtg",)),
    ("superd",       "Super Don Quix-ote",           R2997,  0x06, ("sdq", "superd")),
    ("mach3",        "M.A.C.H. 3",                   R2997,  0x07, ("mach3",)),
    ("cobram3",      "Cobra Command (M.A.C.H. 3)",   R2997,  0x08, ("cobra", "cobram3")),
    ("uvt",          "Us vs Them",                   R2997,  0x09, ("uvt", "uvt-170606")),
    ("gpworld",      "GP World",                     R2997,  0x0A, ("gpworld",)),
    ("astron",       "Astron Belt",                  R2997,  GAME_UNKNOWN, ("astron",)),
    ("badlands",     "Badlands",                     R2997,  GAME_UNKNOWN, ("badlands",)),
    ("bega",         "Bega's Battle",                R2997,  GAME_UNKNOWN, ("bega",)),
    ("esh",          "Esh's Aurunmilla",             R2997,  GAME_UNKNOWN, ("esh",)),
    ("firefox",      "Firefox",                      R2997,  GAME_UNKNOWN, ("firefox",)),
    ("galaxy",       "Galaxy Ranger",                R2997,  GAME_UNKNOWN, ("galaxy",)),
    ("interstellar", "Interstellar",                 R2997,  GAME_UNKNOWN, ("interstellar",)),
    ("roadblaster",  "Road Blaster",                 R2997,  GAME_UNKNOWN, ("rb", "roadblaster")),
    ("blazer",       "Star Blazers",                 R2997,  GAME_UNKNOWN, ("starblazers", "blazer")),
    # PAL. --game only, never auto-detected, and the core cannot play it yet.
    ("laireuro",     "Dragon's Lair (Euro, PAL)",    R25,    GAME_UNKNOWN, ()),
]

BY_KEY = {g[0]: g for g in GAMES}
BY_ID  = {g[3]: g for g in GAMES if g[3] != GAME_UNKNOWN}


def rate_str(rate):
    """(30000, 1001) -> '29.97'."""
    f = Fraction(*rate)
    for name, r in CORE_RATES.items():
        if Fraction(*r) == f:
            return name
    return f"{float(f):g}"


def detect(framefile, m2v_names=()):
    """-> game tuple from the framefile name and the m2v names it lists, or None.

    Every stem that matches must agree; two different games matching is treated as unknown."""
    stems = {os.path.splitext(os.path.basename(framefile))[0].lower()}
    stems |= {os.path.splitext(os.path.basename(n))[0].lower() for n in m2v_names}
    hits = {g[0] for g in GAMES if stems & set(g[4])}
    return BY_KEY[hits.pop()] if len(hits) == 1 else None


def game_name(game_id):
    g = BY_ID.get(game_id)
    return g[1] if g else ("unknown" if game_id == GAME_UNKNOWN else f"id 0x{game_id:02X}?")
