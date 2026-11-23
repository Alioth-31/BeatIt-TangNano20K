create_clock -name sys_clk -period 37.037037 [get_ports {clk_27m}]
set_false_path -from [get_ports {reset_button}]
set_false_path -to [get_ports {led_n[*] PA_EN}]
