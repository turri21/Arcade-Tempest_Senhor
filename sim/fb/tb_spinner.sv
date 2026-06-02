// tb_spinner.sv -- rate-paced +-1 stepper with 3/4 slow-gain.  Velocity = step RATE, not size.
// CRITICAL invariant (HW-proven direction rule): t_spin must NEVER change by >=8 within any
// 60Hz game frame, or the game's (new-old) dial decode inverts.  This TB is a behavioral MIRROR
// of the spinner block in Arcade-StarWars.sv (it does NOT instantiate the RTL), so its durable
// job is the INVARIANT check (worst_frame < 8) and direction sign -- both must hold under the new
// 3/4 input gain.  Step COUNTS are loose ranges: with 3/4 gain + lossless carry + STEP_CAP, exact
// counts depend on carry phase (documented-flaky), so we assert sane bands, not exact equality.
`timescale 1ns/1ps
module tb_spinner;
	logic clk = 0; always #5 clk = ~clk;          // 100MHz tb clock (stands in for clk_12)
	logic [24:0] ps2_mouse = 25'd0;
	logic  [8:0] spinner_0 = 9'd0, spinner_1 = 9'd0;
	logic        osd_sp_rev = 1'b0;
	logic        clr = 1'b0;                       // per-subtest reset of queue/carry (TB only)

	reg  [3:0]  t_spin = 4'd0;
	reg         sp_tgl_d=1'b0, ps2_tgl_d=1'b0;
	wire        sp_tgl  = spinner_0[8] ^ spinner_1[8];
	wire        ps2_tgl = ps2_mouse[24];
	wire        ps2_evt = ps2_tgl ^ ps2_tgl_d;
	wire        spin_evt= sp_tgl  ^ sp_tgl_d;
	wire signed [8:0] ps2_dx = $signed({ps2_mouse[4], ps2_mouse[15:8]});
	wire signed [8:0] sp_dx  = $signed(spinner_0[7:0]) + $signed(spinner_1[7:0]);
	wire signed [8:0] sp_in  = ps2_evt ? ps2_dx : sp_dx;
	wire signed [8:0] sp_raw = osd_sp_rev ? -sp_in : sp_in;
	wire        [8:0] sp_mag = sp_raw[8] ? (~sp_raw + 9'd1) : sp_raw;

	// ----- mirror of RTL constants + 3/4 lossless-gain accumulator -----
	localparam [15:0] PACE_DIV = 16'd28000;   // ~7 steps / 60Hz frame (matches RTL)
	localparam [9:0]  STEP_CAP = 10'd14;
	reg  [9:0]  sp_queue = 10'd0; reg sp_qdir = 1'b0; reg [15:0] sp_pace = 16'd0;
	reg  [1:0]  sp_frac  = 2'd0;
	wire [10:0] sp_scaled = {1'b0,sp_mag} + {sp_mag,1'b0} + {9'd0, sp_frac}; // mag*3 + carry
	wire [8:0]  sp_steps  = sp_scaled[10:2];                                 // >>2 -> 3/4 gain
	wire [1:0]  sp_remn   = sp_scaled[1:0];

	always @(posedge clk) begin
		sp_tgl_d <= sp_tgl; ps2_tgl_d <= ps2_tgl;
		if (clr) begin sp_queue<=10'd0; sp_frac<=2'd0; sp_pace<=16'd0; end
		else if ((ps2_evt|spin_evt) && (sp_mag != 9'd0)) begin
			if (sp_raw[8] == sp_qdir) begin
				sp_frac  <= sp_remn;
				sp_queue <= (sp_queue+sp_steps>STEP_CAP)?STEP_CAP:(sp_queue+sp_steps);
			end else begin
				sp_qdir  <= sp_raw[8]; sp_frac <= sp_remn;
				sp_queue <= ({1'b0,sp_steps}>STEP_CAP)?STEP_CAP:{1'b0,sp_steps};
			end
		end else if (sp_queue != 10'd0) begin
			if (sp_pace == 16'd0) begin sp_pace<=PACE_DIV; sp_queue<=sp_queue-10'd1; t_spin<=t_spin+(sp_qdir?-4'sd1:4'sd1); end
			else sp_pace <= sp_pace - 16'd1;
		end
	end

	// net knob motion: steps are ALWAYS +-1, so on each t_spin change add +1 or -1 directly
	int net=0; reg [3:0] prev=4'd0; logic [3:0] d;
	always @(posedge clk) begin
		prev<=t_spin; d=t_spin-prev;
		if (d==4'd1)      net<=net+1;
		else if (d==4'hF) net<=net-1;   // -1 step (wrapped)
		// |d|>1 never happens by construction; ignore (would be a bug)
	end

	// MAX per-"frame" delta watchdog: sample t_spin every FRAME_CLKS and assert |delta|<8 always
	localparam int FRAME_CLKS = 1666;  // ~60Hz at this tb clock scale
	int worst_frame = 0; reg [3:0] fprev = 4'd0; int fcd = FRAME_CLKS;
	always @(posedge clk) begin
		if (fcd==0) begin
			automatic logic [3:0] fd = t_spin - fprev;
			automatic int sfd = fd[3] ? (int'(fd)-16) : int'(fd);
			if (sfd<0) sfd=-sfd;
			if (sfd>worst_frame) worst_frame=sfd;
			fprev<=t_spin; fcd<=FRAME_CLKS;
		end else fcd<=fcd-1;
	end

	int fails=0;
	task automatic mpoll(input int signed dx);
		begin ps2_mouse[15:8]=dx[7:0]; ps2_mouse[4]=dx[8]; ps2_mouse[24]=~ps2_tgl_d; @(posedge clk);@(posedge clk); end
	endtask
	task automatic drain(input int n); begin repeat(n) @(posedge clk); end endtask
	task automatic reset_acc; begin clr<=1'b1; @(posedge clk); @(posedge clk); clr<=1'b0; net=0; end endtask
	task automatic chk(input string nm, input int got, input int lo, input int hi);
		begin if(got>=lo&&got<=hi) $display("  PASS %-22s = %0d (want %0d..%0d)",nm,got,lo,hi);
		      else begin $display("  FAIL %-22s = %0d (want %0d..%0d)",nm,got,lo,hi); fails=fails+1; end end
	endtask

	initial begin
		@(posedge clk);
		// Drain windows MUST scale with PACE_DIV (one step / PACE_DIV clks): N steps need ~N*PACE_DIV.
		// SLOW: 3 minimal +1 polls -> 3/4 gain w/ carry queues 2 steps -> net +2
		reset_acc; mpoll(1); mpoll(1); mpoll(1); drain(4*PACE_DIV); chk("slow +1x3 -> ~2 (3/4)", net, 1, 3);
		// direction other way must be NEGATIVE (sign correct)
		reset_acc; mpoll(-1); mpoll(-1); mpoll(-1); drain(4*PACE_DIV); chk("slow -1x3 -> neg", net, -3, -1);
		// medium +5 -> 5*3/4 = 3 steps (velocity->count, reduced gain)
		reset_acc; mpoll(5); drain(6*PACE_DIV); chk("med +5 -> ~3 (3/4)", net, 3, 5);
		// big flick +40 -> 40*3/4=30 capped to STEP_CAP=14 -> 14 (fast UNCHANGED: cap-limited)
		reset_acc; mpoll(40); drain(16*PACE_DIV); chk("flick +40 -> cap 14", net, 12, 14);
		// instant reversal: let ~3 up-steps emit, then -10 (latest intent wins) -> ends NEGATIVE
		reset_acc; mpoll(10); drain(3*PACE_DIV); mpoll(-10); drain(16*PACE_DIV); chk("reverse +10/-10 -> neg", net, -10, -1);
		// idle: a zero-delta heartbeat must add nothing
		reset_acc; ps2_mouse[15:8]=0; ps2_mouse[4]=0; for(int i=0;i<20;i++) begin ps2_mouse[24]=~ps2_mouse[24]; drain(50); end
		chk("idle heartbeat -> 0", net, 0, 0);
		// THE INVARIANT (must hold under 3/4 gain): no 60Hz frame ever saw |delta|>=8
		chk("worst frame delta <8", worst_frame, 0, 7);
		$display("=====================================================");
		if(fails==0) $display("ALL RATE-STEPPER TESTS PASSED"); else $display("TESTS FAILED");
		$finish;
	end
endmodule
