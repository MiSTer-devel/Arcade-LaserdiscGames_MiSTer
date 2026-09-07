//============================================================================
// ldp_bus.svh — the transport command bus shared by every LD player front-end.
//
// A front-end decodes its player's byte protocol and emits ops on this bus; the
// transport owns the disc mechanism and never sees a protocol byte.  Adding a
// player means writing one front-end and adding it to the mux in ldp_top.sv.
//============================================================================
// NO include guard on purpose: these are localparams that must land in EVERY module's
// scope, and `define is global to the compilation unit -- a guard would let the first
// includer consume it and leave every other module without the constants.

// cmd_op values.  cmd_action pulses for ANY accepted action opcode (including
// OP_NOP) because the transport arms its search-busy countdown on that edge.
localparam [3:0] OP_NOP      = 4'd0,   // inert / CLEAR: consumes the accumulator only
                 OP_SEARCH   = 4'd1,   // arg = absolute target frame
                 OP_PLAY     = 4'd2,   // 1x forward
                 OP_PLAY_SPD = 4'd3,   // arg[4:0] = speed in q4 (4 = 1x, 0 = still)
                 OP_STOP     = 4'd4,   // still frame
                 OP_PARK     = 4'd5,   // reject / head parked
                 OP_AUTOSTOP = 4'd6,   // arg = stop frame, and begin playing
                 OP_STEP_FWD = 4'd7,
                 OP_STEP_REV = 4'd8,
                 OP_SCAN_FWD = 4'd9,
                 OP_SCAN_REV = 4'd10,
                 OP_AUDIO1   = 4'd11,  // arg[1] = explicit, arg[0] = value; else toggle
                 OP_AUDIO2   = 4'd12,
                 OP_SKIP     = 4'd13;  // arg = frames forward, relative

// Transport modes, exported so front-ends can report their own status codes.
localparam [2:0] M_PARK=3'd0, M_SEARCH=3'd1, M_PLAY=3'd2, M_STOP=3'd3,
                 M_SCAN_FWD=3'd4, M_SCAN_REV=3'd5;
