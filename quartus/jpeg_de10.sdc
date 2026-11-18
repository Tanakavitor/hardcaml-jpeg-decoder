create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# asynchronous, human-speed inputs (synchronised in the top level)
set_false_path -from [get_ports {KEY[*] SW[*]}]
# LEDs and 7-segment displays
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
# VGA outputs are registers that change half a pixel (20 ns) before the rising edge of
# VGA_CLK, which is itself a register in the same clock domain: ample margin for the DAC.
set_false_path -to [get_ports {VGA_*}]
