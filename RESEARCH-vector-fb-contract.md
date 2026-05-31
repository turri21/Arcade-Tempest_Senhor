# Deep research: Tempest vs Star Wars vector→framebuffer paths (2026-05-30)

Goal: understand exactly what the Star Wars `vector_fb_ddram` framebuffer expects, what the
real Star Wars core feeds it, and what our Tempest graft feeds it — to explain the garbled
display (radial "holocaust" lines + wrong glyphs) without more blind HW rebuilds.

Method: three parallel quote-backed RTL analyses (SW reference path, Tempest feed, framebuffer
contract). All claims below are grounded in cited file:line.

## TL;DR — ROOT CAUSE + FIX

`tempest_sw.sv` gated the beam on **colour** (`|tmp_rgb`) instead of **intensity** (`|tmp_z`).
Tempest sets intensity = 0 on blanked **moves** (repositions) and >0 on lit draws, but the
colour register stays non-zero across moves. Tempest draws each object by CENTER-ing the beam
(jump to screen centre) then doing a **blanked move** out to the object, then lit draws — so
with beam=`|rgb`, every centre→object move got **drawn as a line** = the radial holocaust, and
those lines slashing through glyphs = the "wrong text". The real intensity (`tmp_z`) was wired
but **unused**; `Z_VECTOR` was hardwired to full.

**Fix (one line):** `rast_beam = (|tmp_z) && in_bounds;` — exactly how Star Wars gates BEAM_ON
(`|avg_z`). Built as `Arcade-Tempest_20260530d.rbf`.

## Part 1 — The framebuffer CONTRACT (`vector_fb_ddram.sv`)

- **Per-pixel input, NO internal line-draw.** Each FIFO entry → exactly one DDRAM pixel write
  (decode L505-522, single-pixel write L546-554). The Bresenham "drawer" is UPSTREAM in the AVG.
- **`BEAM_ON` is the ONLY write gate.** `push_pix = BEAM_ON && (X≠last_x || Y≠last_y ||
  !last_beam_on)` (L235). RGB is NOT required non-zero (a black pixel still pushes).
- **`BEAM_ENA` is DECLARED BUT UNUSED** (port L56, no other reference). **`START_FRAME` is
  DECLARED BUT UNUSED** (port L87, no other reference). Frame boundaries are driven entirely by
  **`FRAME_DONE`**, rising-edge detected → EOF sentinel `28'hFFFFFFF` → buffer swap (L234, L479-501).
- **Coords:** unsigned `[9:0]`; `addr = Y*4096 + X*4` (L513). Visible window **X∈[0,979],
  Y∈[0,699]**; out-of-range is **dropped** (L511), no clamp/wrap. A signed/negative value on the
  10-bit bus reads as huge unsigned → dropped.
- **Pixel value:** 32bpp RGBA (FB_FORMAT 5'b00110, L97). `chan = {Z[4:0],Z[4:2]}` (L514);
  `RGB[2]`→R, `[1]`→G, `[0]`→B each = chan or 0 (L518-521). `ADD_MODE=1` → overlapping beams
  saturate-add (brighten) (L287-308).
- **Clear:** 358400 single-word zero writes (`USE_BURST_CLEAR=0`, L348; loop L440-446) ≈ ~7 ms.
  Triggered on EOF swap; display promoted ready→display on FB_VBL edge (L395-398).

## Part 2 — Star Wars REFERENCE feed (`starwars.sv` + `avg.vhd`)  [reference only; not compiled in this build]

- FB instantiated in `starwars.sv` (L1002-1044): `.BEAM_ENA(1'b1)` (dead), `.BEAM_ON(rast_beam)`,
  `.START_FRAME(avg_go)`, `.FRAME_DONE(avg_halted)`.
- **`rast_beam = |avg_z && beam_in_bounds`** (starwars.sv L998) — beam follows **intensity**,
  where `avg_z` is the drawer's per-pixel intensity, itself 0 on out-of-range/invalid steps
  (`avg.vhd` L271-272 gates `zout` by the drawer's `pixel_valid`).
- AVG coords are **11-bit SIGNED, centred at screen centre** (avg.vhd L84-85; drawer L375-380).
  `starwars.sv` converts to the 0-based FB: scale ×1.75 X / ×1.25 Y, `+490` / `349−y` (Y invert),
  low 10 bits, beam-off when out of bounds (L968-991).
- **Per-pixel** (Bresenham WALK inside the SW drawer, vector_drawer L305-346). Framebuffer just
  writes the walked stream.
- Z = `(int_latch>>1)*intensity>>3`, ×3 boost, clamp to 5-bit (avg.vhd L258 / starwars.sv L953-956).

## Part 3 — Tempest feed AS-BUILT (`tempest_sw.sv` + `avg_tempest.vhd` + `vector_drawer.vhd`)

- avg_tempest emits **per-pixel** walked points via `vector_drawer` (the OLD Black-Widow drawer:
  10-bit `xout/yout`, no `pixel_valid`, approximate timing — avg_tempest matches THIS drawer's
  ports, so it compiles; the SW `avg.vhd` would NOT match it). Position centred at 0 via a CENTER
  (`zero`) reset + signed relative walk (vector_drawer L66-118).
- avg_tempest `zout` (intensity, 8-bit): `intensity` when `intens_mod="001"`, else
  `intens_mod&"00000"` (avg_tempest L320-321) → **0 for moves (`intens_mod=000`), >0 for draws.**
- avg_tempest `rgbout`: `"000"` only when `state=ISHALTED`, else the resolved colour (L328-332) —
  i.e. **NOT blanked on moves**, only at frame end.
- The drawer has **no beam/blank output** ("ToDo: blank when not actively moving", vector_drawer
  header). tempest.vhd's `BEAM_ENA = ena_1_5M` is just a **clock enable**, not a beam.
- `tempest_sw.sv` feed: `.BEAM_ENA(1'b1)` (dead), `.BEAM_ON(gated_beam)`,
  `rast_beam = (|tmp_rgb) && in_bounds` ⟵ **THE BUG**, `rast_z = 5'd31` (const),
  `tmp_z`/`tmp_beam_ena` **dangling/unused**.

## Part 4 — The mismatch (why it garbles)

The framebuffer + drawer are both per-pixel — that part is fine. The break is the **beam-gate
signal**. SW gates on **intensity** (0 on moves); we gated on **colour** (non-zero across moves).
Tempest's draw pattern (CENTER → blanked move to object → lit strokes) means the move legs all
emanate from screen centre → drawn as the **radial holocaust**, and move legs between glyph
strokes garble the text. Per-frame the moves vary → it "flashes".

## Part 5 — The fix

```verilog
wire rast_beam = (|tmp_z) && in_bounds;   // was (|tmp_rgb)
```
`tmp_z` (= avg_tempest `zout`) is 0 on moves, >0 on draws → blanks moves exactly like SW's
`|avg_z`. `Z_VECTOR` left at full (5'd31) for now (solid bright lines; isolates the change).

## Part 6 — Secondary findings / deferred (after the holocaust is confirmed fixed)

1. **Brightness:** drive `rast_z` from `tmp_z` (SW-style boost+clamp) for true intensity, once
   geometry is confirmed (risk: dim/invisible faint vectors — verify on HW first).
2. **Orientation:** the upside-down/mirrored look is the OSD job — Rotate/Mirror knobs (already in).
   Not a bug.
3. **Present-gate (cadence):** still needed — Tempest redraws ~245 Hz vs the ~7 ms clear; the
   60 Hz edge-FSM gate throttles swaps. Some of the "flashing" was the holocaust varying per
   frame; if any cadence flashing remains after the beam fix, revisit the gate. Bypass = Frame
   Gate→Off.
4. **`START_FRAME` is unused by the FB** → our `gated_start` is harmless dead logic. Frame sync is
   FRAME_DONE-only.
5. **Stale `vector_drawer.vhd`:** the copy in `rtl/avg/` is the old BW drawer (no `pixel_valid`).
   It WORKS for Tempest (proven on the BW core), but it's not the SW 11-bit drawer. Leave as-is;
   just don't ever try to compile SW `avg.vhd` against it.

## Evidence index (key cites)
- FB contract: `vector_fb_ddram.sv` L55-56, 87, 234-237, 505-523, 546-554, 479-501, 440-446.
- SW feed: `starwars.sv` L998, 1002-1044, 968-991, 953-956; `avg.vhd` L84-85, 258, 271-272.
- Tempest feed: `tempest_sw.sv` L162-163, 224-227; `avg_tempest.vhd` L320-321, 328-332;
  `tempest.vhd` L418 (BEAM_ENA=ena_1_5M); `vector_drawer.vhd` L39-51, 101-118.
