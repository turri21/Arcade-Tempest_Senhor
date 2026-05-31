// ============================================================================
// tb_gate2.sv -- verify the REAL present_gate.sv (list-aligned Tempest gate).
//
// Models the AVG as a continuous list generator: a list of LIST_PER cycles, with
// vggo_rise (list start) at the wrap and "drawing" high for the first DRAW cycles
// (the beam laying down pixels), idle for the rest.  FB_VBL pulses every VBL_PER.
//
// THE METRIC: drawing-cycles captured between consecutive eof pulses.  The gate
// must hand the framebuffer EXACTLY one complete list per present, so this must
// equal DRAW:
//     == DRAW  -> GOOD: exactly one complete list (no drop, no smear)
//     <  DRAW  -> PARTIAL (tail-drop = projectile flicker; what the old
//                 time-window gate did when the list outgrew the window)
//     >  DRAW  -> SMEAR (>one list, moving objects doubled)
//
// Scenarios:
//   NORMAL : list ~4ms, draw ~3ms          -> expect == DRAW
//   FIRING : list grown (longer tail)       -> expect == DRAW_fire (NO tail-drop)
//   DEAD   : vggo never fires               -> eof STILL fires (degrade, never
//                                              black) and capture is bounded
//   GLITCH : a stray vggo just after open   -> guard rejects it, == DRAW
//
// Params scaled /100 from real (clk 12MHz, FB_VBL 60Hz=200000cyc, list 4ms=48000)
// so the sim is fast; ratios preserved, present_gate timeouts passed scaled.
// (No SystemVerilog `string` -- ModelSim ASE rejects it as a task arg.)
// ============================================================================
`timescale 1ns/1ps
module tb_gate2;
	logic clk = 0; always #5 clk = ~clk;

	localparam int VBL_PER = 2000;   // FB_VBL period (~60Hz-equiv); tick = 2*VBL = 30Hz
	localparam int LIST_N  = 480;    // normal list period (~4ms-equiv)
	localparam int DRAW_N  = 360;    // normal draw cycles (~3ms-equiv)
	localparam int LIST_F  = 900;    // firing list period (grown)
	localparam int DRAW_F  = 780;    // firing draw cycles (grown tail = projectiles)

	localparam int KIND_EQ = 0, KIND_DEGRADE = 1;

	int  list_per = LIST_N;
	int  draw_cyc = DRAW_N;
	bit  vggo_en  = 1'b1;
	bit  glitch_en= 1'b0;
	bit  rst_stim = 1'b1;
	bit  reset    = 1'b1;

	// FB_VBL pulse generator
	int  vblc = 0;
	logic fb_vbl_pulse;
	always @(posedge clk) begin
		if (reset) begin vblc <= 0; fb_vbl_pulse <= 0; end
		else begin
			if (vblc >= VBL_PER-1) begin vblc <= 0; fb_vbl_pulse <= 1; end
			else                   begin vblc <= vblc + 1; fb_vbl_pulse <= 0; end
		end
	end

	// AVG list generator
	int  lc = 0;
	always @(posedge clk) begin
		if (rst_stim) lc <= 0;
		else          lc <= (lc >= list_per-1) ? 0 : lc + 1;
	end
	wire drawing   = (lc < draw_cyc);
	// vggo at list start; optional stray glitch 50 cyc after start (inside the guard)
	wire vggo_rise = vggo_en & ((lc == 0) | (glitch_en & (lc == 30)));

	// DUT: the real present_gate, timeouts scaled /100
	wire beam_window, eof, frame_start;
	present_gate #(
		.PRESENT_DIV   (8'd2),        // 30Hz present
		.ARMED_TIMEOUT (20'd1440),    // ~12ms-equiv (> firing list period 900)
		.MIN_CAP_GUARD (20'd60),      // ~0.5ms-equiv (rejects the lc==30 glitch)
		.CAP_TIMEOUT   (20'd1440)     // ~12ms-equiv (> firing list period 900)
	) dut (
		.clk(clk), .reset(reset),
		.fb_vbl_pulse(fb_vbl_pulse), .vggo_rise(vggo_rise),
		.beam_window(beam_window), .eof(eof), .frame_start(frame_start)
	);

	// measurement: drawing-cycles captured per eof
	int acc = 0, cap_at_eof = 0, neof = 0, nstart = 0;
	always @(posedge clk) begin
		if (reset) begin acc <= 0; cap_at_eof <= 0; neof <= 0; nstart <= 0; end
		else begin
			if (beam_window && drawing) acc <= acc + 1;
			if (frame_start) nstart <= nstart + 1;
			if (eof) begin cap_at_eof <= acc; acc <= 0; neof <= neof + 1; end
		end
	end

	int fails = 0;

	task automatic run(input int scn, input int lp, input int dc,
	                   input bit ve, input bit ge,
	                   input int kind, input int expect_val);
		int got;
		begin
			@(posedge clk); reset <= 1; rst_stim <= 1;
			list_per <= lp; draw_cyc <= dc; vggo_en <= ve; glitch_en <= ge;
			repeat (8) @(posedge clk);
			reset <= 0; rst_stim <= 0;
			repeat (6*2*VBL_PER) @(posedge clk);     // reach steady state
			got = cap_at_eof;
			$display("[scn %0d] eof/captures=%0d starts=%0d captured-draw-cycles=%0d (one list=%0d)",
			         scn, neof, nstart, got, dc);
			if (kind == KIND_EQ) begin
				if (got >= (expect_val*9)/10 && got <= (expect_val*11)/10)
					$display("         PASS: ~one complete list (no drop, no smear)");
				else if (got < expect_val) begin
					$display("         FAIL: PARTIAL/tail-drop (expected ~%0d got %0d)", expect_val, got);
					fails = fails + 1;
				end else begin
					$display("         FAIL: SMEAR (expected ~%0d got %0d)", expect_val, got);
					fails = fails + 1;
				end
			end else begin // KIND_DEGRADE
				if (neof >= 2 && got > 0 && got < 1440)
					$display("         PASS: eof still fires (NOT black), capture bounded by timeout");
				else begin
					$display("         FAIL: degrade broken (neof=%0d got=%0d)", neof, got);
					fails = fails + 1;
				end
			end
		end
	endtask

	initial begin
		$display("scn1=NORMAL scn2=FIRING scn3=DEAD(degrade) scn4=GLITCH");
		run(1, LIST_N, DRAW_N, 1'b1, 1'b0, KIND_EQ,      DRAW_N); // one ~4ms list/present
		run(2, LIST_F, DRAW_F, 1'b1, 1'b0, KIND_EQ,      DRAW_F); // firing: no tail-drop
		run(3, LIST_N, DRAW_N, 1'b0, 1'b0, KIND_DEGRADE, 0);      // vggo dead: never black
		run(4, LIST_N, DRAW_N, 1'b1, 1'b1, KIND_EQ,      DRAW_N); // stray vggo rejected
		$display("=====================================================");
		if (fails == 0) $display("ALL GATE TESTS PASSED");
		else            $display("GATE TESTS FAILED: %0d", fails);
		$display("=====================================================");
		$finish;
	end
endmodule
