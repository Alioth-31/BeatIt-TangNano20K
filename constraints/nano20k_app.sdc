create_clock -name sys_clk -period 20.345052 [get_ports {clk_audio}]
create_generated_clock -name i2s_bclk -source [get_ports {clk_audio}] -divide_by 16 [get_ports {HP_BCK}]
set_output_delay -clock i2s_bclk -max 10.0 [get_ports {HP_WS HP_DIN}]
set_output_delay -clock i2s_bclk -min 0.0 [get_ports {HP_WS HP_DIN}]
# Mechanical asynchronous inputs terminate in synchronizers/reset synchronizer.
set_false_path -from [get_ports {keys_n[*] volume_ab[*] bend_ab[*] volume_sw_n bend_sw_n test_button reset_button}]
set_false_path -to [get_ports {led_n[*] PA_EN}]

# UART asynchronous input terminates in its two-flop synchronizer.
set_false_path -from [get_ports {uart_rx}]
set_false_path -to [get_ports {uart_tx}]

