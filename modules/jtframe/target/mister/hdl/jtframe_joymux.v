/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 24-10-2021
 *
 * [MiSTer-DB9 BEGIN] - DB9MD/SNAC8 + Saturn fork
 * Rewrites the original DB15-only joymux to delegate to the unified
 * `joydb` wrapper (joydb.sv) which handles DB9MD / DB15 / Saturn modes
 * with a per-pin push-pull mask (USER_PP_DRIVE) and Saturn key gating.
 * The USB fallback (`assign_joy`) is preserved for non-DB modes.
 * [MiSTer-DB9 END] */

module jtframe_joymux(
    input             rst,
    input             clk,
    // [MiSTer-DB9 BEGIN] - HPS-bus clock for the programmable-remap selector load
    input             clk_sys,
    // [MiSTer-DB9 END]
    output            show_osd,

    // MiSTer pins (USER_IO 7→8 widening, [MiSTer-DB9])
    input      [ 7:0] USER_IN,
    output     [ 7:0] USER_OUT,
    output     [ 7:0] USER_PP,

    // joystick mux selection (was: db15_en single bit)
    // joy_type: 2'd0 Off, 2'd1 Saturn, 2'd2 DB9MD, 2'd3 DB15
    input      [ 1:0] joy_type,
    input             joy_2p,
    // [MiSTer-DB9-Pro BEGIN] - Saturn key gate
    input             saturn_unlocked,
    // [MiSTer-DB9-Pro END]

    // [MiSTer-DB9 BEGIN] - OSD-open autodetect FSM glue (joydb.sv)
    //   OSD_STATUS routed from jtframe_mister.sv top-level input.
    //   snac_active / mt32_primary_active: no SNAC path, no MT32-pi on jt
    //   cores — parent binds 1'b0.
    input             OSD_STATUS,
    input             snac_active,
    input             mt32_primary_active,
    // [MiSTer-DB9 END]

    // [MiSTer-DB9 BEGIN] - DB9 programmable-remap selector stream (UIO_DB9_MAP 0xFD, from hps_io)
    input             db9_remap_cmd,
    input      [ 5:0] db9_remap_byte_cnt,
    input      [15:0] db9_remap_din,
    // [MiSTer-DB9 END]

    // USB joystick fallback (provided by hps_io)
    input      [15:0] joyusb_1,
    input      [15:0] joyusb_2,

    // Combined output to game core
    output reg [15:0] joymux_1,
    output reg [15:0] joymux_2,

    // joy_raw payload exposed to hps_io for OSD nav
    output     [15:0] joy_raw
);

parameter BUTTONS = 2;

// Same as defined in jtframe_inputs
localparam START_BIT  = 6+(BUTTONS-2);
localparam COIN_BIT   = 7+(BUTTONS-2);

wire [15:0] joydb_1, joydb_2;
wire        joydb_1ena, joydb_2ena;
wire        pad_1_6btn, pad_2_6btn;
wire [ 7:0] user_out_drive;
wire        user_osd;
// [MiSTer-DB9 BEGIN] - programmable-remap matrix outputs (joydb_remap inside joydb)
wire [15:0] joydb_1_mapped, joydb_2_mapped;
// [MiSTer-DB9 END]

// Mode decode (kept local for the assign_joy mux below)
wire joy_any_en = |joy_type;

// Unified DB9MD / DB15 / Saturn wrapper
joydb u_joydb (
    .clk             ( clk             ),
    // [MiSTer-DB9 BEGIN] - remap matrix: selector load on HPS-bus clk_sys, 0xFD stream
    .clk_sys         ( clk_sys             ),
    .remap_cmd       ( db9_remap_cmd       ),
    .remap_byte_cnt  ( db9_remap_byte_cnt  ),
    .remap_din       ( db9_remap_din       ),
    .joydb_1_mapped  ( joydb_1_mapped      ),
    .joydb_2_mapped  ( joydb_2_mapped      ),
    // [MiSTer-DB9 END]
    .USER_IN         ( USER_IN         ),
    .joy_type        ( joy_type        ),
    .joy_2p          ( joy_2p          ),
    // [MiSTer-DB9-Pro BEGIN] - Saturn key gate
    .saturn_unlocked ( saturn_unlocked ),
    // [MiSTer-DB9-Pro END]
    // [MiSTer-DB9 BEGIN] - OSD-open autodetect FSM glue
    .OSD_STATUS          ( OSD_STATUS          ),
    .snac_active         ( snac_active         ),
    .mt32_primary_active ( mt32_primary_active ),
    // [MiSTer-DB9 END]
    .USER_OUT_DRIVE  ( user_out_drive  ),
    .USER_PP_DRIVE   ( USER_PP         ),
    .USER_OSD        ( user_osd        ),
    .joydb_1         ( joydb_1         ),
    .joydb_2         ( joydb_2         ),
    .joydb_1ena      ( joydb_1ena      ),
    .joydb_2ena      ( joydb_2ena      ),
    // [MiSTer-DB9 BEGIN] - per-player 6-btn detect for SF2 row swap
    .pad_1_6btn      ( pad_1_6btn      ),
    .pad_2_6btn      ( pad_2_6btn      ),
    // [MiSTer-DB9 END]
    .joy_raw         ( joy_raw         )
);

// USER_OUT: when no DB controller selected, leave high so UART/HDMI fallback
// (handled in jtframe_mister.sv) can drive the pins.
assign USER_OUT = joy_any_en ? user_out_drive : 8'hFF;
assign show_osd = joy_any_en & user_osd;

// Map DB-controller joydb data to jotego's expected joystick layout.
// DB9MD / DB15 / Saturn all expose directions in [3:0], buttons starting at
// [4], Start at [10], and Mode/Coin/R-trigger at [11] — matching the legacy
// DB15-only `assign_joy` logic. When no DB controller is active, fall back
// to the USB joystick. (DB9MD 3-btn pads have no Mode button at [11];
// joydb9md.v synthesizes one via Start+B chord internally — no per-core
// fallback needed here.)
function [15:0] assign_joy(
    input        ena,
    input [15:0] joydb,
    input [15:0] joyusb
);
    if( ena ) begin
        assign_joy = 0;
        // [MiSTer-DB9 BEGIN] - matrix output is J1-position-indexed = jt layout, so
        // pull start/coin from their jt bit positions (was joydb[10]/[11], the fixed
        // physical Start/Mode). Identical at factory default for every BUTTONS count
        // (derive places Start->raw10 at slot START_BIT, Coin->raw11 at COIN_BIT) and
        // now honours a user remap of Start/Coin. Pause and higher J1 entries stay
        // uncopied -> zeroed -> DB9-unreachable, exactly as before.
        assign_joy[BUTTONS+3:0] = joydb[BUTTONS+3:0];
        assign_joy[COIN_BIT]    = joydb[COIN_BIT];  // select / mode / R-trigger
        assign_joy[START_BIT]   = joydb[START_BIT]; // start
        // [MiSTer-DB9 END]
    end else begin
        assign_joy = joyusb;
    end
endfunction

// [MiSTer-DB9 BEGIN] - Sega 6-button row swap for fighter convention
// On 6-button DB9MD / Saturn pads the physical layout is two rows:
//   top    = X Y Z   (joydb bits [9:7])
//   bottom = A B C   (joydb bits [6:4])
// Capcom arcade convention (and Sega's own SF2:CE) puts punches on the top
// row and kicks on the bottom row:
//   joystick[4..6] = LP MP HP   (button 1..3)
//   joystick[7..9] = LK MK HK   (button 4..6)
// Swap the two triples so jt cores see XYZ -> LP/MP/HP and ABC -> LK/MK/HK.
// Active only when BUTTONS == 6 and the pad is 6-btn-shaped (pad_*_6btn,
// driven by joydb.sv). A 3-btn MD pad must NOT swap or A/B/C land past
// the game's used buttons in 2-3 button cores (jtcps1 ffight/captcomm/
// ghouls/wof). joydb sources pad_*_6btn from the protocol-level handshake
// in joydb9md (Saturn is always 6-btn-shaped, DB15 has no row geometry
// and reports 0). Fixes MiSTer-DB9/Issues#47.
wire swap_p1 = (BUTTONS == 6) && pad_1_6btn;
wire swap_p2 = (BUTTONS == 6) && pad_2_6btn;

// Layer B: consume the programmable-remap matrix output (joydb_*_mapped) instead
// of the raw joydb_*. At factory default the derive reproduces the joydb identity
// order (A=4..Z=9, Start=10, Mode/Coin=11) so the 6-btn fighter row swap below and
// assign_joy stay bit-for-bit unchanged; user remaps now flow through.
wire [15:0] joydb_1_remap = swap_p1
    ? { joydb_1_mapped[15:10], joydb_1_mapped[6:4], joydb_1_mapped[9:7], joydb_1_mapped[3:0] }
    : joydb_1_mapped;
wire [15:0] joydb_2_remap = swap_p2
    ? { joydb_2_mapped[15:10], joydb_2_mapped[6:4], joydb_2_mapped[9:7], joydb_2_mapped[3:0] }
    : joydb_2_mapped;
// [MiSTer-DB9 END]

always @(posedge clk) begin
    joymux_1 <= assign_joy( joydb_1ena, joydb_1_remap, joyusb_1 );
    joymux_2 <= assign_joy( joydb_2ena, joydb_2_remap, joyusb_2 );
end

endmodule
