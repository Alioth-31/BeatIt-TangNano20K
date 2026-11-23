`timescale 1ns/1ps
module tb_i2c_register #(parameter P=31);
    reg clk=0; always #5 clk=~clk;
    reg rst=1,start=0,read_op=0,two_bytes=0;
    reg [6:0] address=7'h48;
    reg [7:0] reg_addr=1;
    reg [15:0] write_data=16'hc3e3;
    wire busy,done; wire [1:0] error; wire [15:0] read_data;
    wire scl_release,sda_release;
    reg slave_sda=1,slave_scl=1;
    wire scl=scl_release & slave_scl, sda=sda_release & slave_sda;
    integer checks=0, n; reg [7:0] got;
    reg measure_recovery=0,measure_gap=1,after_stop=0,count_recovery=0;time low_edge=0,high_edge=0,stop_time=0;
    always @(posedge scl)if(count_recovery)n=n+1;
    always @(posedge sda)if(scl&&!rst)begin after_stop=1;stop_time=$time;end
    always @(negedge sda)if(scl)begin
        if(measure_gap&&after_stop)check($time-stop_time>=(2*P+2)*10,"STOP-to-START bus-free time too short");
        after_stop=0;
    end
    always @(negedge scl) if(measure_recovery)begin
        if(high_edge!=0)check($time-high_edge>=(2*P+2)*10,"recovery SCL high too short");
        low_edge=$time;
    end
    always @(posedge scl) if(measure_recovery&&low_edge!=0)begin
        check($time-low_edge>=(2*P+2)*10,"recovery SCL low too short");high_edge=$time;
    end
    i2c_register #(.PRESCALE(P),.TIMEOUT_CYCLES(750*P)) dut(
        .clk(clk),.rst(rst),.start(start),.address(address),.reg_addr(reg_addr),
        .read_op(read_op),.two_bytes(two_bytes),.write_data(write_data),
        .busy(busy),.done(done),.error(error),.read_data(read_data),
        .scl_i(scl),.sda_i(sda),.scl_release(scl_release),.sda_release(sda_release));
    task check; input cond; input [511:0] msg; begin
        checks=checks+1; if(!cond) begin $display("FAIL %0s",msg); $fatal(1); end
    end endtask
    task request; input rd; input two; begin
        @(negedge clk); read_op=rd;two_bytes=two;start=1;
        @(negedge clk);start=0;
    end endtask
    task wait_start; begin @(negedge sda); check(scl,"START requires high SCL"); end endtask
    task receive; input [7:0] expected; input ack; integer b; begin
        got=0;
        for(b=7;b>=0;b=b-1) begin @(posedge scl); got[b]=sda; end
        check(got===expected,"wire byte mismatch");
        @(negedge scl);slave_sda=~ack;
        @(posedge scl);@(negedge scl);slave_sda=1;
    end endtask
    task transmit; input [7:0] value; input expected_ack; integer b; begin
        for(b=7;b>=0;b=b-1) begin slave_sda=value[b]; @(posedge scl);@(negedge scl); end
        slave_sda=1;@(posedge scl);check(sda===~expected_ack,"read ACK/NACK mismatch");
        @(negedge scl);
    end endtask
    task finish; input [1:0] expected_error; begin
        wait(done); #1; check(error==expected_error,"transaction status");
        check(!busy,"done while busy");check(scl_release&&sda_release,"bus not released");
        repeat(6) @(negedge clk);
    end endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        fork
            begin request(0,1);finish(0); end
            begin wait_start; receive(8'h90,1);receive(1,1);receive(8'hc3,1);receive(8'he3,1); end
        join
        fork
            begin request(1,1);finish(0);check(read_data==16'h8123,"two-byte read order/sign bits");end
            begin wait_start;receive(8'h90,1);receive(1,1);wait_start;receive(8'h91,1);
                transmit(8'h81,1);transmit(8'h23,0);end
        join
        address=7'h20;reg_addr=3;write_data=16'h00a5;
        fork
            begin request(0,0);finish(0);end
            begin wait_start;receive(8'h40,1);receive(3,1);receive(8'ha5,1);end
        join
        fork
            begin request(1,0);finish(0);check(read_data==16'h005a,"one byte read");end
            begin wait_start;receive(8'h40,1);receive(3,1);wait_start;receive(8'h41,1);transmit(8'h5a,0);end
        join
        fork
            begin request(0,0);finish(1);end
            begin wait_start;receive(8'h40,0);end
        join
        fork
            begin request(0,0);finish(1);end
            begin wait_start;receive(8'h40,1);receive(3,0);end
        join
        fork
            begin request(0,1);finish(1);end
            begin wait_start;receive(8'h40,1);receive(3,1);receive(0,0);end
        join
        // A finite slave clock stretch must be honored rather than timed out.
        fork
            begin request(0,0);finish(0);end
            begin wait_start;receive(8'h40,1);receive(3,1);receive(8'ha5,1);end
            begin @(negedge scl);slave_scl=0;repeat(80)@(negedge clk);slave_scl=1;end
        join
        // Physically stuck clock yields bounded failure and released drivers.
        measure_gap=0;slave_scl=0;request(0,0);finish(2);slave_scl=1;
        // Slave stranded in a read releases SDA after recovery clock pulses.
        slave_sda=0;measure_recovery=1;high_edge=0;
        fork
            begin request(0,0);finish(2);end
            begin repeat(4) @(posedge scl);@(negedge scl);slave_sda=1;end
        join
        measure_recovery=0;
        // A permanently stuck SDA must consume a bounded recovery sequence.
        slave_sda=0;repeat(4)@(negedge clk);n=0;count_recovery=1;
        request(0,0);finish(2);count_recovery=0;
        check(n>=9&&n<=10,"recovery must attempt nine clocks and STOP");slave_sda=1;
        repeat(2*P+4)@(negedge clk);
        // Interrupted read: no partial result may survive a timeout.
        fork
            begin request(1,1);finish(2);check(read_data==0,"partial read survived timeout");slave_scl=1;end
            begin wait_start;receive(8'h40,1);receive(3,1);wait_start;receive(8'h41,1);
                transmit(8'h56,1);slave_scl=0;end
        join
        repeat(2*P+4)@(negedge clk);
        // Next real transaction works after both fault types.
        fork
            begin request(0,0);finish(0);end
            begin wait_start;receive(8'h40,1);receive(3,1);receive(8'ha5,1);end
        join
        $display("PASS i2c register %0d checks",checks);$finish;
    end
    initial begin #3000000;$fatal(1,"I2C test timeout");end
endmodule
