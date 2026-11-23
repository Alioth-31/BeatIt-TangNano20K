# Independent audio and video clock trees. Pixel/serializer stay synchronous.
create_clock -name sys_clk -period 20.345052 [get_ports {clk_audio}]
create_clock -name clk_video -period 37.037037 [get_ports {clk_video}]
create_generated_clock -name serial_clk -source [get_ports {clk_video}] -multiply_by 14 -divide_by 3 [get_pins {display/pll/CLKOUT}]
create_generated_clock -name pixel_clk -source [get_pins {display/pll/CLKOUT}] -divide_by 5 [get_pins {display/divider/CLKOUT}]
create_generated_clock -name i2s_bclk -source [get_ports {clk_audio}] -divide_by 16 [get_ports {HP_BCK}]
set_output_delay -clock i2s_bclk -max 10.0 [get_ports {HP_WS HP_DIN}]
set_output_delay -clock i2s_bclk -min 0.0 [get_ports {HP_WS HP_DIN}]
# Bundled state is held until acknowledge; sample banks are exclusive.
# Only the two-stage request/ack/reset synchronizers cross these clock trees.
set_clock_groups -asynchronous -group [get_clocks {sys_clk i2s_bclk}] -group [get_clocks {clk_video serial_clk pixel_clk}]
