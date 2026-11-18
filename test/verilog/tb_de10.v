// Icarus Verilog testbench for the full Quartus top level (generated jpeg_system.v +
// hand-written de10_standard_top.v / jpeg_rom.v). Run from the quartus/ directory so
// $readmemh finds jpeg_rom.hex. Prints LEDs and the 7-segment value when decoding ends.
`timescale 1ns/1ps
module tb_de10;
    reg clk = 0;
    always #10 clk = ~clk;
    reg [3:0] key = 4'b1111;
    reg [9:0] sw = 10'd0;
    wire [9:0] ledr;
    wire [6:0] h0, h1, h2, h3, h4, h5;
    wire [7:0] r, g, b;
    wire vclk, blank_n, sync_n, hs, vs;
    de10_standard_top dut (
        .CLOCK_50(clk), .KEY(key), .SW(sw), .LEDR(ledr),
        .HEX0(h0), .HEX1(h1), .HEX2(h2), .HEX3(h3), .HEX4(h4), .HEX5(h5),
        .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_CLK(vclk), .VGA_BLANK_N(blank_n),
        .VGA_SYNC_N(sync_n), .VGA_HS(hs), .VGA_VS(vs));

    function [3:0] seg2hex(input [6:0] s);
        case (~s)
            7'h3F: seg2hex = 4'h0; 7'h06: seg2hex = 4'h1; 7'h5B: seg2hex = 4'h2;
            7'h4F: seg2hex = 4'h3; 7'h66: seg2hex = 4'h4; 7'h6D: seg2hex = 4'h5;
            7'h7D: seg2hex = 4'h6; 7'h07: seg2hex = 4'h7; 7'h7F: seg2hex = 4'h8;
            7'h6F: seg2hex = 4'h9; 7'h77: seg2hex = 4'hA; 7'h7C: seg2hex = 4'hB;
            7'h39: seg2hex = 4'hC; 7'h5E: seg2hex = 4'hD; 7'h79: seg2hex = 4'hE;
            7'h71: seg2hex = 4'hF; default: seg2hex = 4'hX;
        endcase
    endfunction

    integer cycles = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 3000000) begin
            $display("TIMEOUT LEDR=%b", ledr);
            $finish;
        end
    end

    initial begin
        wait (ledr[0] | ledr[3]);
        repeat (20) @(posedge clk);
        $display("after %0d cycles: LEDR=%b (done=%b match=%b mismatch=%b error=%b code=%0d)",
                 cycles, ledr, ledr[0], ledr[1], ledr[2], ledr[3], ledr[7:4]);
        $display("7-seg (SW=0, checksum[23:0]): %h%h%h%h%h%h",
                 seg2hex(h5), seg2hex(h4), seg2hex(h3), seg2hex(h2), seg2hex(h1), seg2hex(h0));
        sw = 10'b0000000001;
        repeat (10) @(posedge clk);
        $display("7-seg (SW0, checksum[31:24]):    %h%h", seg2hex(h1), seg2hex(h0));
        sw = 10'b0000000100;
        repeat (10) @(posedge clk);
        $display("7-seg (SW2, width/height):  %h%h%h %h%h%h",
                 seg2hex(h5), seg2hex(h4), seg2hex(h3), seg2hex(h2), seg2hex(h1), seg2hex(h0));
        sw = 10'b0000001000;
        repeat (10) @(posedge clk);
        $display("7-seg (SW3, decode time us): %h%h%h%h%h%h",
                 seg2hex(h5), seg2hex(h4), seg2hex(h3), seg2hex(h2), seg2hex(h1), seg2hex(h0));
        // press KEY[0] to decode again
        key[0] = 0; repeat (5) @(posedge clk); key[0] = 1;
        repeat (400) @(posedge clk);
        $display("after KEY0 press: LEDR[0]=%b busy=%b", ledr[0], ledr[8]);
        wait (ledr[0] | ledr[3]);
        repeat (20) @(posedge clk);
        $display("re-decode: LEDR=%b at cycle %0d", ledr, cycles);
        $finish;
    end
endmodule
