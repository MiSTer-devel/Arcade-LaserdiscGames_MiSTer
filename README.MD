<p align="center">
  <img src="Useful Information/DragonsLair.png" width="800">
  <img src="Useful Information/SpaceAce.png" width="800">
</p>

<h1 align="center">Laserdisc Games FPGA Core</h1>

<p align="center">
  Arcade hardware implementation for MiSTer FPGA
</p>

---

## Overview

FPGA implementation of **Dragon's Lair (1983)** and **Space Ace (1983)**, originally developed and released by Cinematronics.

This core targets MiSTer FPGA and aims for accurate gameplay behavior, video timing, and sound reproduction.

---

## Core Information

| Field        | Value |
|--------------|--------|
| Core Name    | LaserdiscGames |
| Year         | 1983 |
| Developer    | Cinematronics |
| Genre        | LaserDisc |
| Players      | 1–2 alternating |

---

## Controls

Default MiSTer gamepad mapping:

| Dragon's Lair |
| Input | Action |
|-------|--------|
| D-Pad / Joystick | Move |
| A | Sword |
| B | Not Used |
| X | Not Used |
| Y | Not Used |
| Select | Insert Coin |
| Start | 1 Player Start |
| Right Shoulder | 2 Player Start |
| Left Shoulder | Pause |

| Space Ace |
| Input | Action |
|-------|--------|
| D-Pad / Joystick | Move |
| A | Fire / Energize |
| B | Cadet Level Select |
| X | Captian Level Select |
| Y | Space Ace Level Select |
| Select | Insert Coin |
| Start | 1 Player Start |
| Right Shoulder | 2 Player Start |
| Left Shoulder | Pause |

---

## Features

- Arcade-accurate CPU timing
- LaserDisc Simulated, but not fully accurate
- MiSTer-compatible .mra provided
- Verified ROM definitions with checksums

---

## ROM Requirements

ROM files are **not included**.

To use this arcade core, you must provide legally obtained ROM files.

To simplify setup:

- `.mra` files are provided in the **Releases** section.
- The `.mra` specifies all required ROM files along with checksums.
- The ROM `.zip` filename corresponds to the naming convention used by the MAME project.

For setup instructions and environment configuration, refer to:

MiSTer Arcade ROM guide:  
https://github.com/MiSTer-devel/Main_MiSTer/wiki/Arcade-Roms

---

## Installation

1. Copy the core `.rbf` file to your MiSTer `/_Arcade/cores` folder.
2. Copy the '.mra' file to your MiSTer '/_Arcade' folder.
3. Place the appropriate ROM `.zip` files in your `/games/mame` directory.
4. Place the appropriate DLV files in your /games/LaserdiscGames directory.
5. Launch the core from the MiSTer Arcade menu.

---

## Legal Notice

This project contains **no copyrighted game data**.

Users are responsible for obtaining and using ROM files in accordance with applicable laws.

Do not request ROM files in issues or discussions.

---

## Credits

FPGA core development: RodimusFVC 
Original arcade game © Cinematronics

---
