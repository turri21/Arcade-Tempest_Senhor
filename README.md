# Tempest (Atari, 1981) for MiSTer FPGA

A MiSTer FPGA core for **Tempest**, Atari's 1981 color-vector tube shooter. There
is no Tempest core on MiSTer main; this one is built by grafting a new Tempest
game module onto the proven **Star Wars** color-vector chassis
([Videodr0me/Arcade-StarWars_MiSTer](https://github.com/Videodr0me/Arcade-StarWars_MiSTer)),
reusing its DDR3 vector framebuffer, display path, audio chain, and OSD.

> **Status:** boots, renders the attract, and is playable on real DE10-Nano
> hardware — spinner, fire, superzapper, coins, and audio all confirmed. The one
> open item has been display **flicker**; see [Vector presentation](#vector-presentation--the-flicker-fix)
> for the current state of the fix.

---

## Why "Star Wars chassis"?

Tempest and Star Wars run on closely related Atari Analog Vector Generator (AVG)
hardware. Rather than re-implement the hard parts — the DDR3 triple-buffered vector
framebuffer, the MISTER_FB scan-out, clock/CDC plumbing, the OSD — this core hosts
a Tempest **game module** inside Videodr0me's Star Wars project and routes its AVG
vector output into the same `vector_fb_ddram` rasterizer that ships in Star Wars.

One consequence: the Quartus project, the top-level entity, and the output bitstream
are still named `Arcade-StarWars` internally. What you flash is renamed to
**`Arcade-Tempest.rbf`**, and the MRA's `<rbf>Arcade-Tempest</rbf>` points at it.

## What's in this core (vs. the Star Wars chassis it sits on)

**New — the Tempest game module** (`rtl/tempest.vhd`, `rtl/avg/avg_tempest.vhd`,
`rtl/tempest_sw.sv`):

- **6502 (T65)** CPU with Tempest's memory map, transcribed from MAME's
  `atari/tempest.cpp` — program ROM/RAM, vector RAM (4K) + vector ROM (4K),
  the 16-entry color RAM at `$0800`, IN0/DSW decode, coin/flip latches, and the
  ~250 Hz IRQ.
- **Color AVG** (`avg_tempest.vhd`) — a Tempest variant of Jeroen Domburg's
  behavioral Black Widow AVG, with Tempest's color-RAM lookup and X/Y handling.
- **2× POKEY** audio, the **spinner** (read through POKEY 1's pot lines), the Atari
  **math box** (shared Battlezone/Red Baron/Tempest behavioral model), and the
  EAROM stub.
- A **coordinate map** (Tempest tube → the 980×700 framebuffer) with OSD-tunable
  orientation/scale, and a **list-aligned vector present-gate** (`rtl/present_gate.sv`)
  — see below.

**Reused, unchanged — Videodr0me's Star Wars chassis:** `vector_fb_ddram.sv` (the
DDR3 triple-buffer vector framebuffer), the MISTER_FB display path, the `sys/`
MiSTer framework, clock/CDC plumbing, and the OSD/DIP infrastructure.

## Vector presentation — the flicker fix

The chassis renders one *raster* frame at a time, but the Tempest AVG redraws its
*vector* display list continuously at ~245 Hz (the CPU kicks `vggo`/`$4800` once per
~250 Hz IRQ — one complete list every ~4 ms). The job of the present-gate is to hand
the framebuffer **exactly one complete list per displayed frame** — without cutting a
list mid-draw (which shows up as flicker) and without overrunning the DDR buffer-clear.

`rtl/present_gate.sv` does this by **list-aligned capture**: paced to a fixed rate
locked to the HDMI vblank (no beat against scan-out), it opens the beam on one `vggo`
and closes + swaps on the **next** `vggo`, so each displayed buffer holds one whole
list — no dropped tail (important when firing grows the list with projectiles) and no
smear. If `vggo` is ever unavailable it safely degrades to a plain time-window gate.

This replaced an earlier vblank time-window gate that cut the list at a drifting phase
and starved the buffer-clear, which flickered continuously. The list-aligned gate is
verified in simulation (ModelSim, `sim/fb/tb_gate2.sv`); the AVG cadence it relies on
is confirmed by a GHDL probe of the real ROMs.

## Install

1. Copy **`releases/Arcade-Tempest_<date>.rbf`** to your MiSTer's
   `_Arcade/cores/` and rename it to **`Arcade-Tempest.rbf`** (keep exactly one
   `Arcade-Tempest*.rbf` there).
2. Copy **`releases/Tempest.mra`** to `_Arcade/`.
3. Put the Tempest romset **`tempest.zip`** (MAME `tempest`, the Rev-3 parent set)
   in `games/mame/`. The MRA lists the exact ROM CRCs it expects.

Launch the MRA from the MiSTer arcade menu.

## Controls

| Input | Action |
|---|---|
| **Spinner** (or paddle) | Rotate around the tube |
| **Fire** | Fire |
| **Superzapper** | Superzapper (screen-clear, limited) |
| **Start 1P / 2P** | Start |
| **Coin** | Insert coin |

The MRA maps these to a standard pad as well (Fire / Superzapper / Start / Coin);
a real spinner gives the intended control.

## OSD options

Beyond the standard MiSTer video/scaler options, this core exposes hardware
bring-up knobs for the vector presentation:

- **Frame Gate (bypass)** — bypasses the present-gate for native AVG pass-through
  (diagnostic; normal play leaves the gate on).
- **Rotate / Flip** — orientation relative to the built-in baseline, for portrait
  cabinet monitors.
- **Vector Scale** — image scale within the framebuffer.

## Known limitations

- **Hi-score persistence** is not implemented (the EAROM is stubbed), so scores
  reset on power cycle.
- Internal project/bitstream identity is `Arcade-StarWars` (see
  [above](#why-star-wars-chassis)).

## Building

Quartus Prime 17.0 (Cyclone V / DE10-Nano):

```
quartus_sh --flow compile Arcade-StarWars
# -> output_files/Arcade-StarWars.rbf  ->  rename to Arcade-Tempest_<date>.rbf
```

Simulation lives in `sim/` (ModelSim ASE present-gate/framebuffer tests) and the
GHDL boot/cadence testbench. See the in-tree handoff notes for the sim recipes.

## Credits & license

This core stands on a lot of prior work:

- **Videodr0me** — the Star Wars MiSTer port and the `vector_fb_ddram` DDR3 vector
  framebuffer chassis this core is built on.
- **Jeroen Domburg (Sprite_tm)** — the behavioral Black Widow AVG that
  `avg_tempest` is derived from.
- **Dave Wood / fpgaarcade / alanswx** and the broader MiSTer/MAME communities —
  the Atari vector hardware lineage, T65, POKEY, math box, and reference models.
- **MAME** — the authoritative Tempest memory map and hardware behavior.

Original code is **GPLv3** (see `COPYING`); third-party modules retain their own
licenses (see file headers and `LICENSES`). This is a non-commercial,
preservation-oriented project and is not affiliated with Atari.
