/*  This file is part of JTFRAME.
    JTFRAME program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTFRAME program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTFRAME.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 24-10-2021

    [MiSTer-DB9 BEGIN] - DB9MD/SNAC8 + Saturn fork
    Rewrites the original DB15-only joymux to delegate to the unified
    `joydb` wrapper (joydb.sv) which handles DB9MD / DB15 / Saturn modes
    with a per-pin push-pull mask (USER_PP_DRIVE) and Saturn key gating.
    The USB fallback (`assign_joy`) is preserved for non-DB modes.
    [MiSTer-DB9 END]
*/

module jtframe_joymux(
    input             rst,
    input             clk,
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

// Mode decode (kept local for the assign_joy mux below)
wire joy_any_en = |joy_type;

// Unified DB9MD / DB15 / Saturn wrapper
joydb u_joydb (
    .clk             ( clk             ),
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
        assign_joy[BUTTONS+3:0] = joydb[BUTTONS+3:0];
        assign_joy[COIN_BIT]    = joydb[11]; // select / mode / R-trigger
        assign_joy[START_BIT]   = joydb[10]; // start
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

wire [15:0] joydb_1_remap = swap_p1
    ? { joydb_1[15:10], joydb_1[6:4], joydb_1[9:7], joydb_1[3:0] }
    : joydb_1;
wire [15:0] joydb_2_remap = swap_p2
    ? { joydb_2[15:10], joydb_2[6:4], joydb_2[9:7], joydb_2[3:0] }
    : joydb_2;
// [MiSTer-DB9 END]

always @(posedge clk) begin
    joymux_1 <= assign_joy( joydb_1ena, joydb_1_remap, joyusb_1 );
    joymux_2 <= assign_joy( joydb_2ena, joydb_2_remap, joyusb_2 );
end

endmodule
