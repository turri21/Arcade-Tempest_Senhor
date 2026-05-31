// ============================================================================
// present_gate.sv -- Tempest vector present-gate (list-aligned, HW-safe).
//
// PURPOSE
//   The Tempest AVG redraws its display list continuously at ~240-250 Hz (the
//   CPU kicks vggo/$4800 once per ~250 Hz IRQ -> one complete list every ~4 ms,
//   cleanly bounded vggo[n] -> vggo[n+1]).  The DDR framebuffer can only clear +
//   present at ~30-60 Hz, so we must pick ONE list per HDMI present and drop the
//   rest -- WITHOUT cutting a list mid-draw (that is the flicker).
//
// WHY LIST-ALIGNED (not a time window)
//   A fixed beam-on TIME window is not list-aligned: its start (HDMI vblank) and
//   the AVG list start (vggo, game clock) drift, so the captured arc cuts lists
//   at a drifting phase -> tail (late-drawn projectiles) dropped on some frames,
//   and moving objects captured at >1 position (smear).  Bounding the capture by
//   vggo[n]->vggo[n+1] captures EXACTLY one complete list: no tail-drop, no
//   smear, regardless of how long the list is (firing included).
//
// WHY vggo (not avg_halted)
//   avg_halted has a very short idle (~sub-ms) and prior HW builds that gated on
//   the avg_halted EDGE landed partial frames.  vggo is a deliberate once-per-
//   list CPU address-decode strobe ($48xx) -- the same boundary the shipped Star
//   Wars core already feeds its framebuffer.  We bound vggo->vggo and never touch
//   avg_halted.
//
// HW-SAFE DEGRADE (this is the key robustness property)
//   If vggo never arrives (synthesis/timing/CDC pathology -- the documented
//   reason earlier edge-based builds failed on HW), the ARMED and CAP states time
//   out and the gate behaves like a plain ~30 Hz time-window gate (== the known-
//   good "_n" build).  So this gate is NEVER worse than _n: best case perfect
//   (list-aligned), worst case _n-quality.  It can never hang to black.
//
// PACING / BUDGET
//   tick = every PRESENT_DIV-th FB_VBL (locked to HDMI scan-out => zero beat).
//   PRESENT_DIV=2 -> 30 Hz present (each frame shown twice on the 60 Hz panel =>
//   no flicker, like 30fps video).  EOF lands <=~12 ms after the tick even when
//   firing, leaving the DDR clear a ~21-24 ms window (> _n's 21 ms) inside the
//   ~33 ms period -> the clear always finishes before the next draw.
//   PRESENT_DIV=1 -> 60 Hz present (smoother motion; ~12 ms clear budget -- fine
//   because one list is only ~4 ms, but tighter under heavy firing).
//
//   Inputs/outputs are all in the clk_12 (vector-generator) domain -- the same
//   domain as the framebuffer's FIFO write side -- so there is NO new CDC here.
// ============================================================================

module present_gate #(
	parameter [7:0]  PRESENT_DIV   = 8'd2,        // FB_VBL divider: 2=30Hz, 1=60Hz
	// ARMED/CAP timeouts must EXCEED one list period (~4 ms @250 Hz IRQ; <=~12 ms even
	// if redraw slows under heavy fire) so they only fire when vggo is genuinely DEAD.
	// If ARMED_TIMEOUT is shorter than a list period, ARMED times out mid-list and the
	// capture opens UN-aligned to vggo -> partial list (tail-drop).  12 ms is safely
	// above any real period yet leaves clear time inside the ~33 ms (30 Hz) present.
	parameter [19:0] ARMED_TIMEOUT = 20'd144000,  // ~12 ms: no list start -> open anyway (degrade)
	parameter [19:0] MIN_CAP_GUARD = 20'd6000,    // ~0.5 ms: ignore a closing vggo before this --
	                                              //   rejects a stray $48xx double-strobe (the avg_go
	                                              //   decode is not gated on read/write); the real
	                                              //   next-list vggo is ~one IRQ period (~4 ms) out
	parameter [19:0] CAP_TIMEOUT   = 20'd144000   // ~12 ms: no closing vggo -> close anyway (degrade)
)(
	input  clk,             // clk_12 (vector-generator clock)
	input  reset,
	input  fb_vbl_pulse,    // FB_VBL rising-edge pulse, 1 per HDMI vblank (clk domain)
	input  vggo_rise,       // avg_go rising-edge pulse, 1 per list start (clk domain)

	output beam_window,     // 1 while capturing exactly one list (gate rast_beam with this)
	output reg eof,         // 1-cycle pulse at list close  -> FB FRAME_DONE (swap+clear)
	output reg frame_start  // 1-cycle pulse at list open   -> FB START_FRAME
);

	localparam [1:0] S_WAIT = 2'd0,   // beam off; waiting for the 30/60 Hz tick
	                 S_ARMED= 2'd1,   // beam off; tick fired, waiting for the next list start
	                 S_CAP  = 2'd2;   // beam ON; capturing one complete list (vggo->vggo)

	reg [1:0]  st  = S_WAIT;
	reg [7:0]  div = 8'd0;            // FB_VBL present divider
	reg [19:0] tmr = 20'd0;          // safety timeout counter (degrade to time-window if vggo dead)
	reg        tick;

	// ----- present divider: tick once per PRESENT_DIV vblanks (locked to HDMI) -----
	always @(posedge clk) begin
		tick <= 1'b0;
		if (reset) div <= 8'd0;
		else if (fb_vbl_pulse) begin
			if (div >= PRESENT_DIV - 8'd1) begin div <= 8'd0; tick <= 1'b1; end
			else                                div <= div + 8'd1;
		end
	end

	// ----- capture FSM -----
	always @(posedge clk) begin
		eof         <= 1'b0;
		frame_start <= 1'b0;
		if (reset) begin
			st  <= S_WAIT;
			tmr <= 20'd0;
		end else begin
			case (st)
				S_WAIT:  if (tick) begin st <= S_ARMED; tmr <= 20'd0; end

				S_ARMED: begin
					tmr <= tmr + 20'd1;
					// Open the capture at the next list start (vggo).  If vggo never
					// comes, open anyway after ARMED_TIMEOUT (degrade to time-window).
					if (vggo_rise || (tmr >= ARMED_TIMEOUT)) begin
						st          <= S_CAP;
						tmr         <= 20'd0;
						frame_start <= 1'b1;
					end
				end

				S_CAP: begin
					tmr <= tmr + 20'd1;
					// Close at the NEXT list start (vggo) => captured buffer holds exactly
					// one complete list.  Ignore a vggo within MIN_CAP_GUARD (stray $48xx).
					// If the closing vggo never comes, close after CAP_TIMEOUT (degrade:
					// capture becomes an _n-style time window).
					if ((vggo_rise && (tmr >= MIN_CAP_GUARD)) || (tmr >= CAP_TIMEOUT)) begin
						st  <= S_WAIT;
						eof <= 1'b1;
					end
				end

				default: st <= S_WAIT;
			endcase
		end
	end

	assign beam_window = (st == S_CAP);

endmodule
