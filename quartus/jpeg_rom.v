// JPEG byte ROM, initialised at compile time from jpeg_rom.hex (one byte per line).
// Regenerate jpeg_rom.hex with tools/make_rom.py to show a different picture.
module jpeg_rom #(
    parameter ADDR_BITS = 17,
    parameter INIT_FILE = "jpeg_rom.hex"
) (
    input                      clk,
    input                      en,
    input      [ADDR_BITS-1:0] addr,
    output reg [7:0]           q
);
    (* ramstyle = "M10K" *) reg [7:0] mem [0:(1<<ADDR_BITS)-1];
    initial $readmemh(INIT_FILE, mem);
    always @(posedge clk)
        if (en) q <= mem[addr];
endmodule
