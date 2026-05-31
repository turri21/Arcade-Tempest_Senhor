# SPEC — Bloom for Star Wars / Empire Strikes Back (additive vector beam glow)

**Status:** spec, ready to implement. Companion to [`VIS_PLAN.md`](./VIS_PLAN.md),
but **supersedes its bloom step** (VIS-3 / "reuse the BW bloom" — see §0.2).
**Written:** 2026-05-29, *after* `esb-v1.0` shipped (gameplay confirmed on
hardware → the project's "razor-sharp → clock-correct → **pretty third**" gate
is now OPEN).
**Target core:** `D:\deck\fpga\starwars\sw\starwars-videodr0me\` (branch `esb-port`).
**Audience:** a fresh Claude instance picking this up cold. Read §0 first.

---

## 0. TL;DR — four facts that shape everything

1. **vis_warp's bloom design does NOT apply to ESB.** vis_warp bloom
   (`Template_MiSTer-VIS/EFFECTS-BACKLOG.md`, op 111) is a *source-resolution,
   SITE-C, M9K-line-buffer* effect. **ESB is a DDR framebuffer core** (verified
   §3: `MISTER_FB=1`, `video_r/g/b=3'b000`, `vector_fb_ddram.sv` is the source).
   A SITE-C tap sees nothing here — the exact trap that made vis_warp render
   vanilla on rotated Galaga. **Do not port vis_warp into ESB.**

2. **The Black Widow VIS-4 "bloom" is a VISUAL FAILURE — do NOT reuse it.**
   It was tried on hardware and rejected. User verdict, verbatim:
   > "AWFUL, did nothing toward the goal." · "looked like a dithered pixelated
   > acid trip." · "on paper sounds like bloom but it isn't."

   That approach was a **¼-res-downsampled 5-tap Gaussian + RGB565
   energy-preserving composite**. The failure modes to avoid are baked into that
   recipe: a ¼-res blur upscaled = **blocky / dithered** edges on thin bright
   vector strokes; RGB565 + composite math = **channel banding / wrong "acid"
   colors**. `VIS_PLAN.md` still recommends reusing it — **that recommendation is
   dead.** Reuse the BW *plumbing*, never its bloom pass (§2, §4).

3. **The effect we actually want is ADDITIVE — and that IS the bloom.** Per the
   user, bloom here means an additive effect in **two** senses, both required:
   - **(a) additive color intensity** — beams deposit light *additively* and
     saturate toward white (bright/overlapping strokes get hotter), and
   - **(b) vector-intersection / overlap brightening** — where strokes cross or
     vertices converge, light *sums* into bright nodes, and different colors mix
     additively (red+blue → magenta), clamped.

   This is not a blur overlay. It is **saturating additive accumulation in the
   framebuffer.** It models how a real vector beam deposits energy.

4. **The framebuffer is the right substrate for this.** Additive accumulation =
   read-modify-write per painted pixel, which the DDR-FB architecture already
   supports. ESB is the same architecture class as the BW pipeline, so the FB +
   RMW *plumbing* ports cleanly — we just change the merge op and fix the bit
   depth.

---

## 0.5 ✅ PHASE 1 LOOK-LOCK — DONE IN SIM (2026-05-29)

The mandatory sim-first gate (§6 Phase 1) is **complete**. Tooling lives in
`sim/render_bloom.py` (+ `crop_compare.py`, `halo_ladder.py`, `halo_res_test.py`);
PNG artifacts in `sim/bloom_out/`. Everything below is backed by a rendered,
pixel-level-verified artifact — no eyeballing-only claims.

**👍 USER SIGN-OFF (2026-05-29):** look approved on `bloom_high_score_sheet.png`
panel 3 (ADD-888 + full-res halo **s=0.7**) — "this looks great." That panel shows
both effects live: clean beam halos with no blockiness AND the additive color-mix
(red×blue crossing → magenta node, green×blue → cyan). The glow default is
therefore pinned at **s≈0.7** (between the ladder's Subtle and Standard).

**Headline correction to this spec (load-bearing):** §4.2's claim that
*"saturating-ADD alone IS the bloom"* is **half right**. On the real captured SW
content, per-pixel saturating-ADD is **necessary but not sufficient for the
glow**. It delivers exactly two things — additive color-mix at crossings, and a
z-intensity tonal range — but **the visible beam glow comes from the §4.4
full-res additive halo, which is therefore PROMOTED from "optional stretch" to
load-bearing.** Plan the RTL accordingly (the merge-op flip is necessary but does
not, by itself, glow on this content).

**Headline correction #2 (also load-bearing) — the bloom must be fed by an
ANTI-ALIASED vector drawer, NOT the current 1px Bresenham.** Same root cause as
#1: bloom must reflect the *beam* (vector geometry), not the rasterized pixels.
The current drawer is 1px Bresenham, so a 45° stroke gets ~1/√2 the lit-pixel
density per unit *true* length of an H/V stroke ⇒ **a diagonal blooms at only ~70%
of an H/V line, and staircases.** Verified (`render_bloom_vec.py`): aliased
energy/length H=1.00 / 22.5°=0.92 / **45°=0.70**; AA holds it **flat (~1.0) at
every angle**. This is exactly the "it's blooming raster lines, not vectors;
a diagonal should be as strong as H/V; AA would help" critique. The fix is the
**BW Wu AA drawer (VIS-1, already on hardware)** feeding the additive FB —
porting the BW VIS pipeline brings it for free. (Sim proxy: a perpendicular-
distance coverage kernel == Wu coverage.)

### The six findings (each falsifiable, each verified)

1. **The faithful accumulation model is DEDUP, not raw — proven from RTL.**
   `rtl/vector_fb_ddram.sv:230-232`: the FIFO `push_pix` only fires when the FB
   pixel coordinate *changes*, so the hardware **already collapses
   consecutive-identical writes** before the RMW writer ever sees them. The ~6x
   repetition in the tb_drawer log is the drawer holding output across clk_12
   cycles; `push_pix` discards it. => The additive writer accumulates **one write
   per distinct beam visit**. (Raw clock-by-clock dwell-accumulation is *not*
   what hardware does — `render_bloom.py` shows it as a labeled contrast only.)

2. **Saturating-ADD color-mix works — verified at the pixel level.** At the
   high_score crossings, SHARP (overwrite/last-write-wins) shows one primary;
   ADD sums correctly: blue+green->`(0,229,229)` cyan, blue+red->`(229,0,229)`
   magenta, red+yellow->`(255,229,0)` orange, blue+yellow->`(229,229,255)`
   near-white. The mechanism is exactly §0.3(b).

3. **…but color-mix is nearly absent in this captured data.** Pixels receiving
   >=2 distinct colors: **high_score 10, logo 0, intro 1, instr 6.** These are
   single-frame snapshots of mostly single-color wireframe/text. The color-mix
   is correct-where-it-happens but is a ~10-pixel effect here, **not** a
   showcase. (Gameplay — cockpit wireframe + colored enemies + lasers crossing —
   would exercise it far more, but we have no such capture.)

4. **Dedup overlap is sparse => additive-alone ~ sharp + a z tonal range.**
   Dedup writes/px: logo/intro ~99% single-visit (max 3); high_score/instr a
   small tail (max 4-6). So saturating-ADD's *visible* win on this content is the
   **z-intensity weighting** (logo/intro carry real per-stroke intensity, z=11..168)
   giving the wireframe a depth-cued brightness gradient SHARP can't show. The
   "hot vertices from beam dwell" mechanism is defeated by finding #1 (hw dedups
   dwell) — so the glow must be *spread spatially*, see #5.

5. **The glow = full-res additive halo, and it is CLEAN at every strength.**
   `halo_ladder_logo.png`: Off / Subtle(0.4) / Standard(0.9) / Heavy(1.8) — a soft
   beam halo, lines stay sharp-cored, **no blockiness, no dithering**. Brighter
   (high-z) strokes get bigger halos (physically correct). This is the §4.4
   spread, done right, and it is what actually makes the picture glow.

6. **The Black Widow failure was the SAMPLING METHOD, not the 1/4-resolution.**
   `halo_res_logo.png`, glow held constant: full-res ~ **1/2-res(area+bilinear)** ~
   1/4-res(area+bilinear) are all clean; only **1/4-res(stride-4 point-sample +
   nearest-upscale) = the BW recipe** shows the blocky 4x4 smear ("dithered
   pixelated acid trip"). => The §7 "1/4-res blur is the suspect" framing is refined:
   **point-sample + nearest-upscale is the culprit.** 1/2-res area+bilinear is the
   bandwidth/quality sweet spot and de-risks §7's DDR budget — full-res is not
   required.

7. **Bloom is angle-dependent on aliased raster; ANTI-ALIASING fixes it.**
   `render_bloom_vec.py` blooms from the AVG decoder's vector strokes two ways —
   aliased 1px (== current drawer) and AA coverage-kernel — then halos both.
   - `aa_star.png` (equal-length spokes at 8 angles): aliased H/V spokes are
     solid+bright, off-axis spokes staircase and bloom weaker/lumpier; AA spokes
     are uniform at every angle.
   - `vec_logo.png` (real wireframe): aliased diagonals are dotted staircases
     with broken glow; AA diagonals are continuous beams, glow = the H/V edges.
   - Quantified energy/length: aliased H=1.00 / 22.5°=0.92 / **45°=0.70**;
     AA flat ~1.0. ⇒ The additive FB **must** be fed by an AA drawer (BW Wu AA
     drawer, VIS-1). The merge-op + halo on a 1px-Bresenham source still
     under-blooms diagonals.

8. **Real vector games were BRIGHT -- overdrive + white-hot core saturation.**
   (`intensity_ladder.py`, user direction "don't skimp on intensity.") Per-channel
   clip, however bright, leaves cores as flat primaries. The authentic look is an
   over-driven beam whose CORE desaturates toward white while the halo keeps its
   color. Model: accumulate uncapped energy, overdrive xN, then tone-map --
   `over = max(0, ch-255); out = clip(ch) + spill*sum(over)` (spill ~ 0.45). At ~x4
   the line/digit cores go white-hot with colored halos (`intensity_<scene>.png`:
   x4 -> 55% of bright px white-cored; clip -> 0% at any brightness). Two bonuses:
   it **offsets the AA softening** (over-driven AA cores clip to a solid bright
   core + thin soft edge) and it **recovers "hot vertices"** (a crossing sums ->
   over-drives -> whitens into a bright white node -- the 0.3 goal that hw-dedup
   had defeated). Overdrive level = the OSD "intensity" knob; default bright.

### The locked look (defaults the RTL phases inherit)

| Knob | Locked value | Why (evidence) |
|---|---|---|
| Line rasterization | **ANTI-ALIASED** (Wu / coverage), fed from vector geometry | finding #7: aliased 45° blooms at 70% of H/V; AA flat |
| Accumulation | **saturating-ADD, dedup (one RMW / distinct pixel)** | finding #1 (hw push_pix) |
| Bit depth | **RGB888** | glow falloff keeps 78-127 levels/ch vs 565's 9-28 (steps up to 17/255 ~ 7% -> contouring) |
| Single-visit gain | **~0.9 x full-scale** base, then overdrive (next row) | lines bright + readable; headroom for mix/halo |
| Beam intensity | **OVERDRIVE ~x4 (bright), default bright** = OSD "intensity" knob | finding #8; "vector games were bright, don't skimp" |
| Core saturation | **white-hot: `out = clip(ch) + 0.45*sum(max(0,ch-255))`** | finding #8: over-driven cores go white, colored halo; recovers hot crossings |
| z-weighting | **ON** | the real visible win on logo/intro (finding #4) |
| Glow halo | **REQUIRED**, full-res additive, **1/2-res area+bilinear acceptable** | findings #5, #6 |
| Glow STRENGTH (OSD) | Off / Subtle / Standard / Heavy; **default s≈0.7 (user-approved)** | `halo_ladder` + sign-off |
| Glow WIDTH (OSD) | Narrow / Standard / **Wide / Ultrawide**; wide=cheap at ½–¼-res | `presets.py` width ladder; "go wide" (user) |
| Toggles (OSD §5.1) | **orthogonal**: AA, Beam-overlap, White-hot each on/off; presets Off / Glow(non-vector) / Vector | `presets.py`; user direction |
| Forbidden | **stride-4 point-sample + nearest-upscale**, RGB565 for the falloff | finding #6, banding numbers |

### Caveats the RTL phase must carry forward
- **Single-frame data only** => §4.3 clear-vs-decay (phosphor persistence) is
  **not evaluable here** — needs a multi-frame capture. Within-frame = per-frame
  clear (Option A) is what's modeled.
- **Pitch BUG-1 bites the look:** ~60% of high_score writes map off-screen, so
  on-screen content is sparse. Additive accumulation amplifies whatever's in the
  FB (§ Phase 0) — fixing BUG-1 will materially change density before the look is
  final on hardware.
- The halo is a real **extra DDR pass** (read FB -> downsample -> blur -> bilinear
  up -> additive composite). 1/2-res keeps it affordable; budget it against the
  writer (+decay walker if §4.3-B). This is the corner BW cut wrong, not a corner
  to skip.
- **The AA drawer is now a Phase-2 dependency, not a nicety.** The additive FB
  must be fed AA coverage (finding #7). Cleanest path: port the BW VIS pipeline
  whole (Wu AA drawer VIS-1 + multi-channel FB) so AA arrives with the FB. The
  current MAME-faithful AVG (stroke *generation*) stays; only the *rasterizer*
  changes from 1px Bresenham to Wu. Reconcile with the in-flight drawer burndown
  — AA is a render-quality layer on correct geometry, not a competing geometry.
  (No conflict with "razor-sharp first": AA removes jaggies; user explicitly
  asked for it in the pretty pass.)

---

## 1. What "bloom" means here (the target look)

Not a soft blurry overlay. The look is **beam energy adding up**:
- Bright wireframe strokes are hotter than dim ones; the brightest read as
  near-white.
- **Vertices and crossings are the hottest points** — the defining feature of a
  real vector display (every cockpit-wireframe corner on a real Star Wars
  cabinet blooms at the node).
- Crossing beams of different colors **mix additively** (the current 8bpp
  indexed FB literally cannot do this — another reason for the RGB migration, §4.1).
- Clean color, no dithering, no low-res blocks. If any *soft halo* around lines
  is added later, it is a **secondary, optional** layer and must be high-quality
  additive spread — never the ¼-res Gaussian that failed (§4.4, §9).

Visual references: real vector-CRT photos; `mamedev/mame/hlsl/` (use as a *look*
reference, not an implementation to copy at ¼-res).

---

## 2. Prior art inventory (what to reuse, what to avoid)

### 2a. ❌ BW VIS-4 bloom pass — REJECTED (cautionary baseline)
`D:\deck\fpga\vis\workdir-bw\` ch2 bloom = ¼-res 5-tap stride-4 Gaussian H/V +
energy-preserving composite `out = sharp + α·max(0, blurred − sharp)`. Marked
"verified" in its README, but **the user rejected it on look** (§0.2). It is "bloom
on paper" only. **Do not port the ch2 bloom pass.** Keep it documented solely as
the thing not to repeat.

### 2b. ✅ BW VIS plumbing — REUSE THIS
What is genuinely valuable in `workdir-bw`:
- **Multi-channel DDR framebuffer + arbiter** (RGB substrate, channels for
  writer / decay / etc.).
- **`rtl/fb_writer.sv`** — the **read-modify-write** pixel writer. It currently
  **OR-merges** the new pixel into the FB word; **change OR → per-channel
  saturating-ADD** and that single change delivers §0.3(a)+(b) — additive
  intensity *and* intersection overlap. This is the heart of the effect.

### 2c. vis_warp bloom — spec-only, inapplicable
`Template_MiSTer-VIS/EFFECTS-BACKLOG.md` op 111. Never built; SITE-C/line-buffer
substrate is wrong for ESB. Background reading only.

### 2d. ESB itself — no bloom yet
Current FB = 8bpp indexed triple-buffer (`rtl/vector_fb_ddram.sv`). Overwrite/OR
paint, no additive accumulation, no color-mix.

---

## 3. The integration target — ESB video architecture (verified 2026-05-29)

Confirmed against current RTL (not assumed). **Supersedes the stale
`project_starwars_vis.md` lesson #4** ("MISTER_FB commented out / video_rgb dpram
is live") — the core migrated to a DDR framebuffer before the ship.

| Aspect | Finding | Source |
|---|---|---|
| Video model | **DDR framebuffer** (AVG → Bresenham drawer → rasterize to DDR), *not* live raster | `rtl/vector_fb_ddram.sv` |
| Live emu RGB | **Hardwired to 0** | `rtl/starwars.sv:1046-1048` (`video_r/g/b = 3'b000`) |
| FB enable | `MISTER_FB=1` **active**, `MISTER_FB_PALETTE=1` | `Arcade-StarWars.qsf:53,56` |
| FB geometry | **980×700, 8bpp indexed**, triple-buffered in DDR (`0x30000000`, `0x300B0000`, `0x30160000`) | `rtl/vector_fb_ddram.sv:96-99,122-134` |
| Scanout | **ascal reads the DDR framebuffer**, not live `i_r/i_g/i_b` | `sys/sys_top.v` (FB path) |
| Clock domains | AVG/drawer **12 MHz** → FB write **50 MHz** (`clk_sys`) → video **109 MHz** (ce_pix ~54.5 MHz @60 Hz) | `Arcade-StarWars.sv` PLL; `rtl/starwars.sv:1052-1055` |
| FPGA BRAM used | **328/553 M9K (59%)**, 2.56/5.66 Mbit (45%) → ~225 blocks free | `output_files/Arcade-StarWars.fit.summary` |
| FB CDC | Gray-coded async FIFO, 12→50 MHz | `rtl/vector_fb_ddram.sv:18-19` |

**Why SITE-C is dead here (and that's fine):** the live RGB a framework module
would tap is zero; the picture lives in DDR. Additive bloom operates **in the FB
domain**, exactly where the reusable RMW writer lives.

---

## 4. The design — additive accumulation (the spec)

### 4.1 Prerequisite — RGB framebuffer, adequate bit depth
The current FB is **8bpp indexed**, which cannot do additive intensity or color
mixing (you can't add palette indices). So:
- Move to an **RGB** framebuffer (port the BW VIS RGB multi-channel FB to replace
  `vector_fb_ddram.sv`; switch `MISTER_FB` off indexed; drop the palette path;
  feed AVG `{color, intensity}` → RGB).
- **Bit depth is a first-class decision, not an afterthought.** RGB565 is the
  prime suspect for the BW "acid trip" banding under additive/saturating math.
  **Strongly prefer RGB888** (or accumulate at higher internal precision and
  dither-free truncate to the FB format). The whole point is clean additive
  saturation; 5–6 bits/channel will band as soon as you start summing light.

### 4.2 Core mechanism — saturating additive write (delivers §0.3 a + b)
In the RMW pixel writer (BW `fb_writer.sv`, port and modify):
```
fb_pixel <= sat_add( fb_pixel, beam_contribution )      // per RGB channel, clamp at max
```
where `beam_contribution = color × intensity` of the stroke pixel.
- **(a) Additive intensity:** repeated/bright strokes accumulate → brighter,
  clamping toward white. A bright vector reads hotter than a dim one.
- **(b) Intersection / overlap:** two strokes over the same pixel sum → bright
  node; different colors sum → additive color mix, clamped. Vertices where many
  strokes converge are the brightest pixels in the frame.
- Tune a global **intensity/gain** so a single stroke is at a sensible level and
  overlaps drive toward white without the whole frame clipping. This is the
  primary tunable.

This alone is the bloom the user described. It is full-resolution, clean, and
color-correct — none of the ¼-res/RGB565 failure modes.

### 4.3 Accumulation lifetime — how light clears
Additive accumulation needs a defined clear/decay model or it saturates to a
white frame:
- **Option A (per-frame):** clear (or swap to a fresh) buffer each frame; one
  frame's strokes accumulate, then reset. Simplest; matches the current
  triple-buffer swap.
- **Option B (decay walker, from BW VIS-3):** a persistence model — light decays
  over ~tens of ms instead of hard-clearing, giving phosphor-trail behavior *and*
  a natural place for accumulation to live. This is the `VIS_PLAN.md` walker
  model and subsumes the ESB flicker/accumulation question.
Pick per the look wanted (A is the minimal bloom; B couples bloom with phosphor
persistence — likely the richer vector look). **Decide in sim (§6).**

### 4.4 Optional secondary — soft halo (only if needed, and only done right)
Pure additive accumulation gives hot intersections + intensity but **not**
necessarily a soft halo around an *isolated* line. If, after §4.2, a gentle glow
spread is still wanted:
- Do it as a **clean additive spread at full (or near-full) resolution** with
  adequate bit depth — e.g. a small additive neighbor-spread, not a ¼-res
  downsample-Gaussian-upsample.
- **Forbidden:** the BW ¼-res Gaussian recipe (that is exactly what dithered and
  acid-tripped). If a separable blur is used at all, keep it high-res and additive
  into the FB, and validate it shows **no** blockiness on a single thin stroke in
  sim *before* hardware.
- Treat this as a *stretch* layer. The required deliverable is §4.2.

---

## 5. OSD exposure — ESB's advantage over vis_warp

Bloom here lives **inside the core's own emu** (`Arcade-StarWars.sv` /
`rtl/starwars.sv` / the FB RTL), **not** in the `sys_top` framework. So its
parameters can be ordinary per-core **`CONF_STR` / `status[]` OSD options — no
Main_MiSTer userland needed** (the opposite of vis_warp, which is blocked on
Main_MiSTer because `sys_top` can't read `status[]`). Add e.g. `Bloom intensity:
Off / Subtle / Standard / Heavy` (+ decay/trail length if doing §4.3-B) to the
existing `CONF_STR`. Fully self-contained in the `.rbf`.

### 5.1 Toggle / preset architecture (decided 2026-05-29, user direction)

**The effect must decompose into ORTHOGONAL toggles, not one monolithic "vector
mode."** Some users want a plain glow over the normal game image; AA and beam-
overlap (color-mix / white-hot) are the opinionated vector-faithful extras that
not everyone wants. Validated in sim (`presets.py` -> `presets_<scene>.png`): the
stages compose independently and each preset renders distinct + correct.

| Toggle | OFF | ON (vector-faithful) | Vector-specific? | RTL cost |
|---|---|---|---|---|
| **AA lines** | 1px Bresenham (crisp original) | Wu coverage (angle-independent, finding #7) | YES | drawer mode — the one non-trivial toggle (see below) |
| **Beam overlap** | overwrite — original colors, no mixing | sat-ADD — crossings sum + color-mix (finding #2) | YES | cheap: a merge mux in fb_writer |
| **White-hot core** | flat primaries | over-driven cores → white (finding #8) | YES | cheap: tone-map mux |
| **Glow / halo** | — *universal "bloom" — everyone who turns bloom on gets it* — | NO | the halo DDR pass |
| **Glow strength** | Off / Subtle / Standard 0.7 / Heavy | (s≈0.7 default) | NO | runtime scalar |
| **Glow WIDTH** | Narrow / Standard / **Wide / Ultrawide** | "go wide" (user) — radius via passes×downsample | NO | runtime; WIDE is *cheaper* at ½–¼-res (finding #6) |
| **Intensity** | normal | overdrive ~×4 (finding #8) | NO (general) | runtime multiply |

Toggles are **orthogonal** (AA = drawer, overlap = FB merge, glow/white-hot =
composite) so any combination is valid. Two **glow knobs** now: **strength** (how
bright the glow) and **WIDTH** (how far it spreads) — wide glows go cheap at ½–¼-res
because finding #6 proved area+bilinear lo-res is clean, and a wide smooth glow
hides low res even better.

**Presets (the simple OSD knob), each just a bundle of the toggles:**
- **Off** — sharp 1px, overwrite, no glow. The core's normal output.
- **Glow** *(non-vector)* — 1px + clean halo, original colors, no AA / no overlap /
  no white-hot. A generic bloom for people who don't want the vector treatment.
- **Vector** — AA + overlap + white-hot + overdrive×4 + glow. The authentic look.
- **Advanced** (optional submenu) — expose the individual toggles + strength/width/
  intensity so tweakers can build any combination (e.g. AA + glow but no overlap).

**RTL note — AA is the one toggle with real cost.** Overlap/white-hot/strength/
width/intensity are all cheap runtime muxes/scalars on the composite or FB merge.
AA on/off means two rasterization behaviors: either keep both drawers selectable
(more logic) or run the Wu drawer always and approximate "AA off" by forcing a
hard 1px coverage threshold (one drawer, a mode bit). Decide in Phase 2; the
"Glow (non-vector)" preset specifically does NOT need AA, so a build that ships
glow-only first is viable without the Wu port.

### 5.2 Bloom is SOURCE-resolution, pre-scaler — resolution/scale independent (decided 2026-05-29)

**Define and apply the entire bloom in the 980×700 DDR framebuffer, BEFORE ascal
/ the integer scaler, in SOURCE-pixel units. Never in output/display pixels.**
The player picks an integer scale to fill a 1080p/4K panel (and runs anything from
a 10" screen to a 40" TV); if bloom width were a display-pixel value it would be a
per-setup knob and look different on every rig. Putting it pre-scaler means ascal
enlarges the whole bloomed image uniformly, so:
- a `W` source-px bloom shows as `W×scale` display px — it **tracks the picture**;
- it is the same **fraction of the image** (~1.7% of height for a 12px radius) on
  every panel/scale → **persistent**, like a real tube where the glow IS the picture;
- the integer scale carries **no** bloom width — one bloom, baked in the source.

This is already the architecture (§3: ascal reads the DDR FB) and the same reason
vis_warp went at SITE C (source res, pre-ascal — `design_vis_warp_constraints`).

**Consequences:**
- **Tune in SOURCE px, not display/photo px.** The real-tube close-up shows a glow
  ~76 *photo* px wide — that is display scale. At source res it is a **modest
  ~12–15px** halation that the scaler (≈5–6× to reach 4K) widens to the wide
  display glow, and **bilinear-smooths for free** — so the long outward tail costs
  little at source res (cheap ½–¼-res halation, finding #6).
- **OSD "width" = source-px radius** (Narrow/Std/Wide presets), never a display value.
- Don't over-author falloff detail finer than source res can carry; ascal's
  interpolation supplies the smoothness on the way up.

**Proven (`scale_invariance.py` -> `scale_invariance.png`):** the source-res bloom
is **5.0% of the picture at every integer scale** (x2/x4/x6 look identical at a
common screen size); a fixed 7-display-px bloom shrinks **1.3% -> 0.7% -> 0.4%**
across the same scales. Source-res = persistent; display-px = breaks per rig.

**Calibrated source-res line profile** (from `sample_ref.py` on the real-tube
close-up; reproduced by `scale_invariance.py`). The bloom is PER-CHANNEL (real
phosphor: blue halates widest) -> a CYAN core fading to a wide deep-blue tail:

| component | color (peak) | radius (SOURCE px) | role |
|---|---|---|---|
| R | ~111 | 2.5 | core only (cyan) |
| G | ~214 | 4.5 | near-core cyan |
| B core | ~150 | 3.5 | bright blue core |
| B tail | ~(20,18,98) | **13** (=5% of frame, ~78px @ x6) | the outward bloom |
| veil | ~(14,12,60) | 24 | faint CRT veiling glare |

Core ~`(111,214,236)` CYAN, **not white** (white-out was the "too hot"). Hue
verified: core `57:96:100` -> tail `21:19:100` == sampled ref `21:20:100`. The
near-flat ~40% ambient floor seen in the photo is a SCENE effect (all lines'
overlapping tails + veil), not one line's halation — emerges on a full frame, do
not over-fit a single line to it.

**Core-line width and bloom width are INDEPENDENT knobs (user, 2026-05-29: "keep
the bloom width but narrow the perceived beam line").** Three orthogonal widths
now: (1) **beam-line width** (the bright perceived line) = THIN, ~1 source px;
(2) **bloom width** = wide; (3) intensity = peak. Do NOT derive the bloom by
blurring the core — that ties glow strength to core thinness (a thin core gives a
faint blurred halo). Model the bloom as **independent components**: thin bright
CORE + wide BLOOM (bluer than core) + faint very-wide VEIL, each with its own
width + strength, summed, then white-hot tone-map. Verified composing the full SW
logo (`logo_scene.py` / `logo_thincore.png`): thin cyan-white beams in a wide
lush blue glow + green crawl text — matches the real-tube look. Logo params: core
AA 0.8px, bloom ½-res ×5-pass strength 2.0, veil ⅛-res strength 0.7, intensity
360, spill 0.42, cyan-blue beam `(0.35,0.62,1.0)`. (Single-line viewed at source
scale looks tighter than the display-scale ref photo — that is §5.2 working; the
scaler widens it. Judge bloom width on the full frame, not a zoomed line.)

---

## 6. Implementation plan (sim-first)

**Phase 0 — prereq sanity.** Confirm the shipped FB renders correctly. **Additive
accumulation amplifies whatever's in the FB** — any residual drawer issues (old
burn-down: pixel-pitch BUG-1, FB-accumulation BUG-3) will get *brighter*. Decide
tolerate vs. fix-first. Keep the indexed FB on a branch as fallback.

**Phase 1 — sim-first, LOCK THE LOOK (no Quartus).** Extend `sim/render_*.py` to
model AVG→RGB + **saturating additive accumulation** on the captured MAME scenes
(`high_score`, `logo`, `intro`, `instr`). **A/B against a reference of the BW
¼-res Gaussian so the contrast is explicit**, and tune: bit depth (565 vs 888),
global gain, clear-vs-decay (§4.3), and whether any §4.4 halo is even wanted.
Output PNGs are the acceptance gate — *the look is decided here, before any
hardware*, because the look is exactly what failed last time.

**Phase 2 — RGB-FB port (the risky step). ✅ DONE 2026-05-29 — HARDWARE-VALIDATED
(parity confirmed on SW + ESB; RMW writer works on hw, no R↔B swap, no tearing).** Done IN-PLACE in `rtl/vector_fb_ddram.sv` (reusing its proven
FIFO/CDC/triple-buffer/push_pix) rather than porting BW's multi-channel arbiter
(deferred to Phase 3/4 when extra DDR channels are actually needed). 32bpp
RGBA8888 (`FB_FORMAT=5'b00110`, **[4]=0=RGB** per `ascal.vhd:665-666` — the spec's
earlier "[4]=1" was wrong), stride 4096, re-spaced triple buffers, RMW full-word
writer (`USE_RMW=1`; `=0` = proven BE-overwrite fallback), `{color,z}→RGB888`
identical to the old palette (parity). Palette macro dropped (qsf) + the unguarded
`FB_PAL_*` connections guarded. **Validated: `sim/parity_check.py` PASS (256/256);
Quartus Analysis&Elaboration 0 errors** (11 warnings, all pre-existing). Gate (the
real one) = USER full compile + hardware A/B vs the indexed branch: no R↔B swap,
intensity ramps match, no missing pixels/tearing. Plan + risks:
`~/.claude/plans/keen-floating-chipmunk.md`.

**Phase 3 — additive accumulation.** Flip the writer merge OR → **saturating-ADD**
(§4.2); add the §4.3 clear/decay model. **Gate:** vertices/crossings visibly
hottest, color mixing correct, no dither/banding, thin lines clean. Hardware A/B.

**Phase 4 — OSD + (optional) halo.** `CONF_STR` intensity selector (§5); then, only
if Phase-1 sim said it's wanted, the clean §4.4 halo.

---

## 7. Risks & gotchas (don't re-discover)

- **The look is the whole risk.** The last attempt was *technically* bloom and
  *looked* terrible. Phase 1 (sim, A/B, PNG acceptance) exists to kill that risk
  before silicon. Do not skip it.
- **RGB565 banding** is the prime suspect for "acid trip" colors → prefer RGB888 /
  higher-precision accumulation (§4.1).
- **¼-res blur** is the prime suspect for "dithered pixelated" → if any spread is
  done, keep it full-res and additive (§4.4).
- **DDR3 silently drops writes if `DDRAM_BE` ≠ `0xFF`** → full-word writes only
  (the RMW writer is built for this).
- **`FB_FORMAT[4]=1` for RGB** semantics (inverted from the `sys_top.v` comment).
- **GHDL:** ASCII-only `report` strings (no `—`/`→`); VHDL ids can't end in `_`;
  VHDL-2008 shared vars need protected types.
- **Quartus smart-recompile caches silently** — delete `db/`+`incremental_db/` to
  force a rebuild. **User runs full compiles**; Claude runs GHDL + `quartus_sh`
  diagnostics only.
- **The RGB-FB swap (Phase 2) is the load-bearing risk** — keep the indexed FB
  branch as fallback; validate render before adding additive math.
- **DDR bandwidth at 980×700** with writer (+ decay walker if §4.3-B) contending —
  budget it; BW only proved 512×512.

---

## 8. File map

**ESB core** — `D:\deck\fpga\starwars\sw\starwars-videodr0me\`
- `rtl/vector_fb_ddram.sv` — current indexed FB (replaced in Phase 2)
- `rtl/starwars.sv` — FB hookup (~1030-1048; `video_r/g/b=0` at 1046-48; timing 1052-55)
- `Arcade-StarWars.sv` / `.qsf` — top + `MISTER_FB` macros (qsf:53,56)
- `sys/sys_top.v` — FB plumbing to ascal
- `sim/` — `render_*.py`, MAME-captured scenes (Phase-1 host)
- `docs/VIS_PLAN.md` — parent plan **(its bloom step is superseded by this doc)**

**Reusable PLUMBING** — `D:\deck\fpga\vis\workdir-bw\` *(verified path; memory's
`...\starwars\vis\workdir-bw\` is wrong)*
- `rtl/fb_writer.sv` — RMW writer → **change OR-merge to saturating-ADD**
- multi-channel DDR FB + arbiter — reuse for the RGB FB
- ❌ its ¼-res Gaussian bloom pass — **do not port** (§0.2)

**Cross-references**
- `D:\deck\fpga\Template_MiSTer-VIS\EFFECTS-BACKLOG.md` — vis_warp bloom (N/A here)
- `mamedev/mame/hlsl/` — look reference only

---

## 9. Open questions for the implementer

**Most are now ANSWERED by the Phase-1 look-lock (§0.5). Status inline:**

- **Bit depth:** ✅ **RGB888.** 565 collapses the glow falloff to 9-28 levels/ch
  (steps up to 17/255); 888 keeps 78-127. (§0.5 finding-evidence)
- **Clear vs decay (§4.3):** ⏳ **STILL OPEN — un-answerable from this data.** The
  captures are single frames; persistence is a multi-frame phenomenon. Need a
  temporal capture to decide A vs B. Within-frame, Option A (per-frame clear) is
  modeled.
- **Bright-pass / gain:** ✅ **~0.9 × full-scale single-visit**, z-weighting ON.
  Lines bright+readable, headroom for mix/halo. (the glow level is the halo knob,
  not the gain — see OSD ladder.)
- **Halo or not (§4.4):** ✅ **YES — REQUIRED, not optional.** Additive
  accumulation alone does NOT glow on this content (hw dedups dwell §0.5-#1;
  overlap is sparse §0.5-#4). The clean full-res (or ½-res area+bilinear)
  additive spread IS the glow. Promoted to load-bearing.
- **Scope of first port:** the halo being load-bearing means the RGB-FB port must
  budget the spread pass (a 2nd DDR pass) up front. Phosphor (§4.3-B) shares the
  substrate but is gated on the multi-frame clear-vs-decay question above —
  reasonable to ship additive+halo first, add phosphor when a temporal capture
  exists.

---

*Design only. Per project rule, no Quartus build proceeds without a sim datapoint
first (and Phase 1's PNG look-lock is mandatory here — the look is what failed
before). User drives full compiles.*
