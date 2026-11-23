`timescale 1ns/1ps
// Focused end-to-end UART check with accelerated phase and reference periods.
module hardware_probe_smoke #(
    parameter BAUD_CYCLES=64,
    parameter RATE_CYCLES=27000,
    parameter RUN_CYCLES=310000,
    parameter MIN_RATES=3
);
    reg clk_audio=0, clk_27m=0, reset_button=1;
    wire HP_BCK,HP_WS,HP_DIN,PA_EN,uart_tx;
    wire [5:0] led_n;
    reg [15:0] expected [0:31];
    reg [7:0] line [0:15];
    reg [7:0] received;
    integer expected_count=0,received_count=0,valid_count=0;
    integer line_length=0,phase_count=0,rate_count=0,nonzero_count=0;
    integer i,value,rate_value;
    reg [7:0] first_phase=0;
    hardware_probe_top #(
        .PHASE_SAMPLES(96),
        .RATE_REF_CYCLES(RATE_CYCLES),
        .UART_DIVISOR(BAUD_CYCLES)
    ) dut(clk_audio,clk_27m,reset_button,HP_BCK,HP_WS,HP_DIN,
          PA_EN,led_n,uart_tx);
    always #5 clk_audio=~clk_audio;
    always #9 clk_27m=~clk_27m;

    function integer hex_digit;
        input [7:0] c;
        begin
            if(c>="0" && c<="9") hex_digit=c-"0";
            else if(c>="A" && c<="F") hex_digit=c-"A"+10;
            else hex_digit=-1;
        end
    endfunction

    always @(posedge clk_audio) if(!dut.rst && dut.pcm_valid) begin
        if(valid_count==31) begin
            if(expected_count>=32) begin $display("FAIL expected buffer"); $finish; end
            expected[expected_count]=dut.pcm;
            expected_count=expected_count+1;
            valid_count=0;
        end else valid_count=valid_count+1;
    end

    // Decode the actual TX pin at the midpoint of each 8N1 symbol.
    always @(negedge uart_tx) begin
        if(!reset_button) begin
            #(BAUD_CYCLES*5);
            if(uart_tx!==0) begin $display("FAIL UART start"); $finish; end
            received=0;
            for(i=0;i<8;i=i+1) begin
                #(BAUD_CYCLES*10);
                received[i]=uart_tx;
            end
            #(BAUD_CYCLES*10);
            if(uart_tx!==1) begin $display("FAIL UART stop"); $finish; end
            if(received==8'h0a) begin
                if(line_length==3 && line[0]=="#" && line[1]=="A" &&
                   line[2]=="4") begin
                    if(phase_count!=0 && first_phase!="C") begin
                        $display("FAIL phase sequence A4"); $finish;
                    end
                    first_phase="A";
                    phase_count=phase_count+1;
                end else if(line_length==3 && line[0]=="#" && line[1]=="C" &&
                            line[2]=="H") begin
                    if(first_phase!="A") begin
                        $display("FAIL phase sequence CH"); $finish;
                    end
                    first_phase="C";
                    phase_count=phase_count+1;
                end else if(line_length==11 && line[0]=="#" && line[1]=="R" &&
                            line[2]=="A" && line[3]=="T" && line[4]=="E" &&
                            line[5]==" ") begin
                    rate_value=0;
                    for(i=6;i<11;i=i+1) begin
                        if(line[i]<"0" || line[i]>"9") begin
                            $display("FAIL rate digit"); $finish;
                        end
                        rate_value=rate_value*10+line[i]-"0";
                    end
                    if(rate_value<RATE_CYCLES/600 ||
                       rate_value>RATE_CYCLES/540) begin
                        $display("FAIL rate value %0d",rate_value); $finish;
                    end
                    rate_count=rate_count+1;
                end else if(line_length==4) begin
                    value=0;
                    for(i=0;i<4;i=i+1) begin
                        if(hex_digit(line[i])<0) begin
                            $display("FAIL sample hex"); $finish;
                        end
                        value=(value<<4)|hex_digit(line[i]);
                    end
                    if(received_count>=expected_count ||
                       value!==expected[received_count]) begin
                        $display("FAIL PCM %0d got %h expected %h",
                            received_count,value,expected[received_count]);
                        $finish;
                    end
                    if(value!=0) nonzero_count=nonzero_count+1;
                    received_count=received_count+1;
                end else begin
                    $display("FAIL UART line length %0d",line_length);
                    $finish;
                end
                line_length=0;
            end else begin
                if(line_length>=16) begin $display("FAIL long UART line"); $finish; end
                line[line_length]=received;
                line_length=line_length+1;
            end
        end
    end

    initial begin
        repeat(8) @(negedge clk_audio);
        reset_button=0;
        repeat(RUN_CYCLES) @(negedge clk_audio);
        if(phase_count<3 || rate_count<MIN_RATES || received_count<7 ||
           nonzero_count<3 || !PA_EN || !led_n[1] || !led_n[2] ||
           dut.core_fault || dut.tx_fault || dut.uart_overflow) begin
            $display("FAIL probe phases=%0d rates=%0d pcm=%0d nonzero=%0d PA=%b LEDs=%b",
                phase_count,rate_count,received_count,nonzero_count,PA_EN,led_n);
            $finish;
        end
        $display("PASS hardware probe UART PCM/phase/rate, I2S ready and fault LEDs");
        $finish;
    end
    initial begin #(RUN_CYCLES*10+1000000); $display("FAIL timeout"); $finish; end
endmodule
