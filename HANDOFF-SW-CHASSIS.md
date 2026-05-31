# Tempest 1.1 — re-host on the Star Wars DDR chassis

**Status (2026-05-30):** builds clean + timing met; **HW bring-up round 1 done, two fixes in
build `_20260530`.** First cab test (the `_20260529` build): boots, audio + game logic run,
ROMs/MRA correct — but the video was mis-mapped: 90deg rotation + "flashing" (one almost-game-
scale frame, then two dots, then a good frame only every ~15-20 s). Two root causes, BOTH FIXED:
  1. **Orientation/scale** — was a hardcoded X<->Y swap with no scaling. The geometry itself is
     CORRECT (that occasional full frame proves the coord map + AVG are right). Replaced with
     OSD-tunable **Rotate (0/90/180/270) / Mirror / Vector Scale (Half/3-4/Full)**, centred +
     auto-scaled (status[6:5]/[7]/[9:8]). Default Half/centred = guaranteed fully on-screen; dial live.
  2. **Frame cadence** (the "flashing" — same root cause as the BW trails): Tempest redraws its
     list ~245 Hz (every ~4 ms), but the SW full-buffer clear takes ~7 ms, so the clear never
     finishes between swaps. Fix = a **60 Hz present-gate** in `tempest_sw.sv` (FSM: wait tick ->
     wait next vggo -> pass ONE complete frame's draws + its FRAME_DONE -> close; inter-frame
     redraws dropped) so the clear gets a 16.6 ms window. The SW rasterizer + clear are
     **UNMODIFIED** — "match Tempest to SW", not the reverse (the rasterizer's `USE_BURST_CLEAR`
     fast-clear path is a known-black dead end needing SignalTap; left OFF).
**Remaining: confirm on HW + dial the OSD knobs.** FB format/plumbing is the pristine shipped SW
config (32bpp RGB, palette unused) — healthy, untouched.

This is the pivot off the Black Widow DDR (which was never shipped with a
working framebuffer — partial byte-enable writes dropped, RMW read-back stalled → trails that
couldn't be cleared in time). The Star Wars `vector_fb_ddram` DDR triple-buffer is rock-solid
(shipped in SW + ESB), so Tempest now rides on it.

## What this core is

`D:\deck\fpga\tempest\Arcade-Tempest-SW\` — a copy of the proven **Star Wars** MiSTer core
with the SW game module replaced by **Tempest**, feeding the SAME `vector_fb_ddram` rasterizer
that SW/ESB ship with. The SW chassis has **no `arcade_video` pipeline** — it supplies only
VGA sync + the FB config, and ascal scans the DDR framebuffer directly (`MISTER_FB=1`).

Project files still carry the `Arcade-StarWars` name internally (qpf/qsf/sv) — the compile
output `Arcade-StarWars.rbf` gets renamed to `Arcade-Tempest*.rbf` for shipping (see below).

## The graft (key files)

- **`rtl/tempest_sw.sv`** (NEW) — the wrapper that replaces `starwars.sv`. Hosts
  `tempest tempest_game(...)` (T65 6502 + memory map + `avg_tempest` + 2× POKEY + mathbox),
  maps its AVG vector output into `vector_fb_ddram rasterizer(...)`, supplies the 980×700
  sync lifted verbatim from `starwars.sv`, and routes mono Tempest audio to both channels.
- **`files.qip`** (REWRITTEN) — Tempest deps only (pkg_bwidow, dpram2k, pokey, earom,
  avg/vector_drawer, avg/avg_tempest, t65/*, mathbox, tempest.vhd) + `vector_fb_ddram.sv` +
  `dpram.vhd` (SW DDR) + `tempest_sw.sv` + top + sdc.
- **`Arcade-StarWars.qsf`** — removed the inline SW direct-file block (it was pulling in
  `avg.vhd`/`starwars.sv`/`slapstic`/`TMS5220`/`mc6809`/`reticon` ON TOP of `files.qip` and
  the SW `avg.vhd` clashed with Tempest's `vector_drawer.vhd` port list). Now only
  `source files.qip` drives the file list. `MISTER_FB=1` is set.
- **`Arcade-StarWars.sv`** (top, entity `emu`) — 4 edits:
  1. CONF_STR → Tempest (`Tempest;;`, aspect, `DIP;`, J1 = Fire,Superzapper,FireDn,FireUp,
     Start1,Start2,Coin,Pause).
  2. Input logic → Tempest: MRA DIPs into `sw[0..2]`, analog-spinner **rate-proportional
     NCO** (full throw = max spin, feather = fine, ~10% deadzone; D-pad L/R fixed-rate
     fallback) → 4-bit `t_spin`, buttons, coins, and `tempest_in0/in1/in2`.
  3. Module swap `starwars starwars_core` → `tempest_sw tempest_core`.
  4. NVRAM SW outputs tied off (`nvram_dout_ext=0`, `nvram_write_pulse=0`) — Tempest hiscore
     is stubbed (EAROM = 0xFF), so the upload scaffolding just pushes zeros (harmless;
     ioctl_upload_req is also gated off since the SW autosave/save/clear status bits aren't in
     the Tempest CONF_STR).
- **`releases/Tempest.mra`** (NEW) — `<rbf>Arcade-Tempest</rbf>`, same ROM order as the proven
  BW Tempest MRA (identical `tempest.vhd`), BW mod-selector (index 1) + NVRAM tag dropped.

## Input mapping (POKEY pots — matches tempest.vhd / MAME tempest)

```
sw[0] = DSW1 ($0D00)   sw[1] = DSW2 ($0E00)   sw[2] = difficulty[1:0]/rating[2]/cabinet[4]
tempest_in0 = ~{2'b00,3'b000, t_coin, 1'b0, 1'b0}        ; COIN1 = bit2, active low
tempest_in1 = {3'b111, sw[2][4]/*cabinet*/, t_spin[3:0]} ; IN1_DSW0 -> POKEY1
tempest_in2 = {1, ~t_start2, ~t_start1, t_fire, t_zap, sw[2][2], sw[2][1:0]} ; fire/zap ACTIVE-HIGH
```
Fire/zap active-high is the verified-correct polarity (MAME `tempest_buttons_r` is
IP_ACTIVE_HIGH — this is the auto-fire fix the user already confirmed on the BW core).

## ⚠️ HW-TUNABLE knobs (the next step — needs the user + hardware)

All in **`rtl/tempest_sw.sv`**, the coordinate-mapping block (~lines 117-135). First-pass guess
only — must be A/B'd on hardware:

1. **Orientation / swap / flip** — currently:
   `cx={~tmp_x[9],tmp_x[8:0]}`, `cy={~tmp_y[9],tmp_y[8:0]}` (bit-9 centre),
   `fx={1'b0,cy}`, `fy={1'b0,cx}` (swap X↔Y to run the tall tube along the 980 axis).
   If the picture is rotated/mirrored wrong, flip the bit-9 invert and/or the fx/fy swap.
2. **Scale / fill** — `in_bounds = (fx<980)&&(fy<700)`. Tempest's 10-bit coords (0–1023) may
   over/under-fill 980×700. If clipped at an edge or floating small, add a scale (shift) on
   cx/cy before the swap. SW scaled its own coords to fit — Tempest's range likely differs.
3. **Intensity** — `rast_z = 5'd31` (full). Could derive from `tmp_z` for true vector
   brightness modulation once geometry is right.
4. **Aspect** — 980×700 sync is SW's. Tempest is a portrait tube; the CONF_STR aspect options
   + MiSTer rotation may need setting. (MRA is `rotation=horizontal` since the FB is landscape.)

Never clamp out-of-range coords — gate the beam off (`rast_beam = (|tmp_rgb) && in_bounds`),
same as SW, or off-screen lines slide along the edge.

## Build / stage

```
cd D:\deck\fpga\tempest\Arcade-Tempest-SW
"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map.exe" Arcade-StarWars      # A&S (~1 min)
"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe" --flow compile Arcade-StarWars  # full (~25 min)
# output: output_files\Arcade-StarWars.rbf  ->  rename to Arcade-Tempest_YYYYMMDD.rbf
```

## Remaining to ship 1.1

1. ⏳ Full compile → RBF (running).
2. ☐ Rename output `Arcade-StarWars.rbf` → `Arcade-Tempest_20260529.rbf`; stage to SD
   `_Arcade/cores/` + `releases/Tempest.mra` → `_Arcade/`. (Optional: rename the whole
   project qpf/qsf/sv/sdc → `Arcade-Tempest.*` for the GitHub repo, then re-verify A&S.)
3. ☐ **HW bring-up** — tune the orientation/scale/Z knobs above. NEEDS THE USER.
4. ☐ GitHub release (Tempest 1.1).
