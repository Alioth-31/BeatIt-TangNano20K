`timescale 1ns/1ps
// Compare default and optional chains while driving the same physical keys.
module tb_timbre_integration;
    reg clk=0,reset_button=1;
    reg [7:0] keys_n=8'hff;
    wire bck0,ws0,sd0,pa0,bck1,ws1,sd1,pa1;
    wire [5:0] leds0,leds1;
    integer frames=0, different_core=0, changed_fx=0;
    integer dry_tx=0, wet_tx=0, different_i2s=0;
    nano20k_synth_top #(.DEBOUNCE_CYCLES(8)) baseline(
        clk,reset_button,1'b0,keys_n,2'b11,1'b1,2'b11,1'b1,
        bck0,ws0,sd0,pa0,leds0);
    nano20k_synth_top #(.DEBOUNCE_CYCLES(8),.WAVEFORM_MODE(3),
                        .FX_ENABLE(1),.FX_DC_ENABLE(1),.FX_DELAY_ENABLE(1)) changed(
        clk,reset_button,1'b0,keys_n,2'b11,1'b1,2'b11,1'b1,
        bck1,ws1,sd1,pa1,leds1);
    always #5 clk=~clk;
    always @(posedge clk) if(!reset_button) begin
        if(baseline.pcm_valid && changed.pcm_valid) begin
            frames=frames+1;
            if(baseline.pcm !== changed.pcm) different_core=different_core+1;
        end
        if(baseline.tx_valid) begin
            dry_tx=dry_tx+1;
            if(baseline.tx_pcm !== baseline.pcm) begin
                $display("FAIL baseline PCM altered"); $finish;
            end
        end
        if(changed.tx_valid) begin
            wet_tx=wet_tx+1;
            if(changed.tx_pcm !== changed.pcm) changed_fx=changed_fx+1;
        end
        if(pa0 && pa1 && sd0!==sd1) different_i2s=different_i2s+1;
    end
    initial begin
        repeat(8) @(negedge clk); reset_button=0; keys_n=8'hdf;
        repeat(240000) @(negedge clk);
        if(frames<100 || different_core<50 || changed_fx<50 ||
           dry_tx!=wet_tx || dry_tx<100 || different_i2s<100 ||
           !pa0 || !pa1 || baseline.core_fault || changed.core_fault ||
           baseline.tx_fault || changed.tx_fault || changed.fx_fault) begin
            $display("FAIL end-to-end frames=%d core_diff=%d fx_diff=%d I2S_diff=%d tx=%d/%d",
                frames,different_core,changed_fx,different_i2s,dry_tx,wet_tx);
            $finish;
        end
        $display("PASS default and optional wave/fx paths reach independent I2S, no underrun");
        $finish;
    end
endmodule
