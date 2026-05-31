# SPEC — Halation (bloom Phase 3b): the visible glow

**Status:** ⏸️ **PAUSED 2026-05-29** — the whole sharp-core halation gates on DDR
burst writes (§4), and **burst writes BRICK this f2sdram when malformed and can't be
debugged without JTAG** (see §4 RESULT). User's DE10 is in a SuperStation 1 (no
accessible JTAG → needs an external USB-Blaster + 10-pin cable, ~$15). Decision:
**ship Phase 2 + 3a as the milestone, pause the glow until a Blaster is in hand.**
Resume recipe is in §4. Companion to `SPEC-bloom-esb.md` (look-lock §0.5/§5).

## 0. Where this sits

- **Phase 2 (built, on branch `bloom/phase2-rgb-fb`):** 32bpp RGBA8888 FB at
  parity, RMW writer. Invisible. The substrate.
- **Phase 3a (ready, not applied):** flip the RMW merge to saturating-ADD →
  crossings mix/brighten. **Subtle** (hw dedups, content barely overlaps). Needs
  the RMW path working on hardware (BE-overwrite fallback can't accumulate).
- **Phase 3b (THIS doc): halation** — the wide colored bloom + veil + white-hot
  core. **This is the visible payoff.**
- Phase 3c: AA drawer (the Tempest dotted-rasterizer fix). 3d: OSD toggles.

## 1. Goal (from the look-lock, user-signed-off on the logo)

Per-pixel additive accumulation alone does NOT glow on this content. The glow is
a **spatial spread**, composed source-res so it scales persistently (§5.2):

```
display = white_hot( core  +  s_bloom * spread_wide(core)  +  s_veil * spread_veiL(core) )
```
- `core` = the sharp 32bpp FB (thin beams).
- `spread_wide` = ½-res area-average → blur → bilinear up (the lush blue halo).
- `spread_veil` = ¼-res, very wide, faint (CRT veiling glare / ambient floor).
- `white_hot` = over-driven cores desaturate to white: `out = clip(ch) + 0.45*Σ max(0,ch-255)`.
- Calibrated levels (logo): bloom ~½-res ×5-pass, veil ~⅛-res, overdrive ~×4,
  spill 0.45 (`SPEC §0.5` table). Authentic hue-shift (cyan core→blue halo) wants
  **per-channel widths** (B spread wider than R/G) — a refinement over a single
  beam-color blur.
- **Forbidden** (the BW "acid trip"): ¼-res *point-sample + nearest-upscale*. Use
  area-average down + bilinear up (finding #6).

## 2. Architecture — multi-channel DDR + a bloom engine

Phase 2 kept the writer single-channel in-place. Halation needs **multiple DDR
clients** (the writer + the bloom passes reading/writing buffers), so now we
introduce the multi-channel path the spec always intended:

- **Port BW's `rtl/ddram.v`** (3-channel arbiter, already read). Channels:
  - `ch1` = pixel writer — convert Phase-2's raw-DDRAM RMW to issue ch1 read/write
    (the ddram.v ready/dout interface). Highest priority (latency-sensitive).
  - `ch2` = **bloom_engine** (new module) — the downsample/blur/composite passes.
  - `ch0` = reserved for the future phosphor decay walker (§4.3-B), unused now.
- **bloom_engine** writes a **composite buffer**; **ascal's `FB_BASE` points at the
  composite** (exactly BW's structure: main FB → bloom bufs → composite → ascal).
  ascal already scans out one DDR buffer source-res, then upscales — so the glow
  rides the scaler (§5.2).
- Tone-map (white-hot) happens **in the composite pass** (ascal reads plain RGB),
  not in ascal.

## 3. Pass pipeline (bloom_engine, per frame, on the just-finished FB)

1. **Downsample** main FB (full-res) → ½-res buffer, 2×2 **area average** (clean).
2. **Blur** ½-res H then V (5-tap `[1,4,6,4,1]`, repeated for width). Per-channel:
   B uses more passes / wider than R/G for the hue-shift (refinement).
3. **Veil**: downsample the ½-res → ¼-res, blur very wide, faint.
4. **Composite** (full-res): for each pixel, `core + s_bloom*bilinear(½-res blur) +
   s_veil*bilinear(¼-res veil)`, then **white-hot tone-map**, write → composite buf.
5. ascal displays the composite buf.

Triple-buffer interplay: bloom processes `ready_buf` (just completed) while the
writer fills a different `draw_buf`; composite is its own buffer ascal reads.
Sequencing/latency (which frame the composite reflects) is a design item — budget
one extra frame of latency for the glow (fine; glow is slow-changing).

## 4. ⚠️ #1 RISK + #1 TASK: DDR bandwidth → **bursts**

The full-frame passes are the cost. Rough budget: 60 Hz @ clk_sys 50 MHz =
~833k cycles/frame. Full FB 980×700 32bpp = 343k 64-bit words. The composite pass
alone reads core (343k) + writes composite (343k) ≈ **686k word-accesses**.
BW-style **single-word** DDR (`burst=1`, latency-bound ~10-20 cyc/access) sustains
only **~40-80k accesses/frame** → composite would take ~10-15 frames. **Infeasible
single-word.**

**But bursts are the unlock, and they work here:** `ascal.vhd` reads the FB via
**256-byte bursts** (`N_BURST=256` → 16-word bursts on the 128-bit path) every
frame — proof the HPS DDR3 on this board sustains full-res burst bandwidth. BW's
bloom used single-word and its `BURSTCNT=4` attempt scrambled (v3.7) — but ascal's
working bursts on the *same DDR3* mean **BW's burst failure was a protocol bug in
BW's ddram.v, not a hardware limit.**

⇒ **Phase-3b task #1 is a DDR-burst spike:** get burst read/write working on the
emu's DDRAM port (model on ascal's burst master, fix BW's v3.7 mistake). Bursts
(~8-16×) bring the composite into ~1-2 frames = feasible. *Everything downstream
depends on this — do it first and MEASURE before building the passes.*

### 4.RESULT (2026-05-29) — 🔴 burst spike FAILED twice on hw; PAUSED, needs JTAG

Two burst-clear attempts (`USE_BURST_CLEAR=1`: v1 `140794f`, v2 `1c32b85`) both
**blacked out SW on hardware** (OSD survived = core alive, only the FB path died).
Reverted to single-word; working build = **`ec84094`, `USE_BURST_CLEAR=0`**.

**Root cause = a controller BRICK, not a logic miss.** `sys/f2sdram_safe_terminator.sv`
header: *"terminating a burst write mid-stream causes an illegal state to the f2sdram
interface; the only way to reset it is to reset the whole SDRAM Controller Subsystem"*
(can't be done while Linux runs). A malformed burst (wrong beat count by one) hangs the
**shared** SDRAM controller → ascal's FB read stalls (black) while OSD on its own path
lives. Exactly the observed symptom, both times.

**The protocol I implemented matches on paper** (that terminator's FSM is the spec:
WE held high the whole burst; beat valid on `write && !waitrequest`; addr+burstcount
latched at burst start and held; burst ends at `burstcounter == burstcount-1`). v2 does
all of this. The remaining bug is in the **live handshake** and is **unobservable** here:
can't sim the SystemVerilog FB module (GHDL won't take it), and there is **no proven
burst-WRITE reference for the 64-bit `DDRAM_*` emu port** to copy verbatim — `ddr_svc.sv`
and gnw `ddram.v` only write single-word (burst=1); ascal burst-writes but on a *different*
port (`vbuf_*` 128-bit @ clk_100m vs emu `ram_*` 64-bit @ ram_clk).

**RESUME RECIPE (when a USB-Blaster + 10-pin JTAG cable is available):**
1. Connect the Blaster to the SuperStation's DE10 JTAG header; confirm Quartus Programmer sees the device.
2. Re-enable the burst path: `rtl/vector_fb_ddram.sv` `USE_BURST_CLEAR → 1'b1` (v2 FSM is intact, gated off).
3. Add a SignalTap instance (clock = the FB writer's clk) probing: `DDRAM_BUSY`/waitrequest, `DDRAM_WE`, `DDRAM_BURSTCNT`, `DDRAM_ADDR`, `clear_beat`, `clear_setup`, `clearing`. Trigger on `clearing` rising.
4. Capture one clear. Compare the live WE/!BUSY beat sequence against the terminator FSM (§4): is exactly `burstcount` beats delivered? does WE stay high across a mid-burst `BUSY`? does addr/burstcount stay stable? The discrepancy is the bug — fix once, not blind.
5. Then build the multi-channel ddram + bloom_engine passes (§2-§3) on the proven burst primitive.

**No-JTAG fallback NOT taken (user chose pause):** splat-in-writer — each beam px →
a small additive single-word-RMW kernel; safe (degrades to flicker, never bricks),
bandwidth-marginal (~3-5× current RMW load), tight glow ceiling. Available if the
glow is wanted before a Blaster arrives.

**Fallbacks if bursts prove stubborn:**
- **½-res composite** (BW-style): feasible at lower access counts, but softens the
  cores ~2× (ascal upscales a ½-res composite). The look-lock wanted thin sharp
  cores — this trades that away. Acceptable interim to *see* a glow.
- **Reduced-rate glow** (update bloom every N frames). Cores still need a per-frame
  full-res buffer, so this helps less than it seems with one display buffer.
- Keep the cores sharp by compositing only the *glow add* and accepting whatever
  res the bandwidth allows for the spread (the spread is low-res anyway).

## 5. Buffer layout (DDR, byte addrs; extends Phase-2 map)

- Main FB triple-buffer: 0x30000000 / 0x302BC000 / 0x30578000 (2.87 MB each).
- bloom ½-res (490×350×4): ~0.69 MB. veil ¼-res: ~0.17 MB. composite full-res:
  2.87 MB (or triple if tear shows).
- Total ~12-15 MB. **Confirm the HPS FB reservation covers it; widen the
  `safe_address` clamp** (same caveat as Phase 2).

## 5.5 Finding (2026-05-29) — thin cores blur faint → CRANK strength (not AA)

The RTL `bloom_engine` **blurs the FB** (post-rasterization; no per-line
"independent component" like the Phase-1 sim). Blurring **thin** cores gives low
bloom amplitude, so **crank the bloom STRENGTH** (OSD/param knob) for the lush glow.

**UPDATE (user, 2026-05-29): the SW rasterizer is PERFECT (solid clean lines) —
the "dottiness" I saw was a SIM artifact (gappy decoder-stroke data in
`logo_thincore`), NOT the real drawer.** So **Phase 3c (AA drawer port) is
DROPPED** — no rasterizer surgery. A solid thin rasterizer is exactly the "thin
sharp cores" half of the signed-off look; the bloom engine adds the wide glow.
Handle §5.5 thinness via bloom STRENGTH, not by thickening cores. The only
residual is finding #7 (diagonals may bloom slightly weaker than H/V on 1px
Bresenham) — judge on hardware once the glow is in; a tweak if visible, not a port.

The fixed-point pipeline + constants are pinned in `sim/bloom_engine_model.py`
(the RTL golden reference): `area_avg2 (a+b+c+d+2)>>2`, `blur5
(x0+4x1+6x2+4x3+x4+8)>>4`, composite `(k*v)>>8`, white-hot `clip(ch)+(SPILL*Σover>>8)`;
starting constants OD=512 S_BLOOM=768 S_VEIL=256 SPILL=115, 4 passes each (these
become OSD knobs — tune on hardware).

## 6. Staging (incremental, measure each)

1. **Burst spike** — burst read+write on the emu DDR port; measure sustained
   accesses/frame. Go/no-go for full-res.
2. **Multi-channel** — drop in BW's `ddram.v`; move the Phase-2 writer to ch1;
   confirm parity still renders (now via the arbiter). `quartus_map` datapoint.
3. **One wide blur → composite** (single scale, beam-color, no veil/white-hot yet):
   first glow on hardware. Tune `s_bloom`, width.
4. **Veil + white-hot tone-map.** 5. **Per-channel widths** (cyan→blue hue-shift).
6. **OSD**: bloom Off/Subtle/Standard/Heavy + width, white-hot on/off (§5.1).

## 7. Port vs build

- **Port from BW (plumbing):** `ddram.v` arbiter; the H/V/composite pass *FSM
  shape* + buffer-address arithmetic (`Arcade-BlackWidow.sv:839-1191`).
- **Build new (clean method):** area-average downsample + bilinear upsample (NOT
  BW's stride-4 point + nearest); **additive** composite (NOT BW's energy-
  preserving max); **burst** DDR (NOT BW's single-word); white-hot tone-map;
  per-channel widths.

## 8. Dependencies / gates

- Phase 2 RMW must render at parity on hardware (additive needs the read path).
- Phase 3a (sat-ADD) is independent of halation and can land first (substrate).
- Phase 3c AA drawer = the **Tempest dotted-rasterizer fix** (solid lines in →
  clean glow out); pull when starting 3c.
- User runs full Quartus compiles; Claude does GHDL/quartus_map diagnostics + sim.

*Plan only. The burst spike (task #1) is the real unknown and the gate for the
whole sharp-core halation; measure it before building the pass pipeline.*
