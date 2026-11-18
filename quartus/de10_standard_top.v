// Terasic DE10-Standard (Cyclone V SX 5CSXFC6D6F31C6) top level for the Hardcaml JPEG decoder.
//
//   KEY[0]  reset + decode again          SW[3]  7-seg shows decode time (us, hex)
//   LEDR[0] decode finished               SW[2]  7-seg shows width / height (hex)
//   LEDR[1] checksum matches expected     SW[1]  7-seg shows the expected checksum
//   LEDR[2] checksum MISMATCH             SW[0]  7-seg shows checksum bits [31:24]
//   LEDR[3] decoder error                 (all SW down: checksum bits [23:0])
//   LEDR[7:4] error code, LEDR[8] busy, LEDR[9] heartbeat
//   VGA: 640x480 @ 60 Hz, the 320x240 frame buffer shown 2x2.
//
// jpeg_system.v is generated from the Hardcaml sources (dune exec bin/gen_verilog.exe).
module de10_standard_top (
    input        CLOCK_50,
    input  [3:0] KEY,
    input  [9:0] SW,
    output [9:0] LEDR,
    output [6:0] HEX0,
    output [6:0] HEX1,
    output [6:0] HEX2,
    output [6:0] HEX3,
    output [6:0] HEX4,
    output [6:0] HEX5,
    output [7:0] VGA_R,
    output [7:0] VGA_G,
    output [7:0] VGA_B,
    output       VGA_CLK,
    output       VGA_BLANK_N,
    output       VGA_SYNC_N,
    output       VGA_HS,
    output       VGA_VS
);
    `include "jpeg_expected.vh"   // EXPECTED_CHECKSUM, EXPECTED_VALID (tools/make_rom.py)

    // power-on reset, plus KEY[0] (active low, already debounced on the board)
    reg [7:0] por_cnt  = 8'd0;
    reg [1:0] key_sync = 2'b00;
    reg       reset    = 1'b1;
    always @(posedge CLOCK_50) begin
        key_sync <= {key_sync[0], KEY[0]};
        if (por_cnt != 8'hFF) por_cnt <= por_cnt + 8'd1;
        reset <= (por_cnt != 8'hFF) | ~key_sync[1];
    end

    reg [9:0] sw_meta, sw_sync;
    always @(posedge CLOCK_50) begin
        sw_meta <= SW;
        sw_sync <= sw_meta;
    end

    wire [16:0] rom_addr;
    wire        rom_en;
    wire [7:0]  rom_q;

    jpeg_rom #(.ADDR_BITS(17)) rom (
        .clk  (CLOCK_50),
        .en   (rom_en),
        .addr (rom_addr),
        .q    (rom_q)
    );

    jpeg_system sys (
        .clock             (CLOCK_50),
        .clear             (reset),
        .rom_q             (rom_q),
        .sw                (sw_sync),
        .expected_checksum (EXPECTED_CHECKSUM),
        .expected_valid    (EXPECTED_VALID),
        .rom_addr          (rom_addr),
        .rom_en            (rom_en),
        .vga_r             (VGA_R),
        .vga_g             (VGA_G),
        .vga_b             (VGA_B),
        .vga_hs            (VGA_HS),
        .vga_vs            (VGA_VS),
        .vga_blank_n       (VGA_BLANK_N),
        .vga_sync_n        (VGA_SYNC_N),
        .vga_clk           (VGA_CLK),
        .ledr              (LEDR),
        .hex0              (HEX0),
        .hex1              (HEX1),
        .hex2              (HEX2),
        .hex3              (HEX3),
        .hex4              (HEX4),
        .hex5              (HEX5),
        .checksum          (),
        .done_ok           ()
    );
endmodule
