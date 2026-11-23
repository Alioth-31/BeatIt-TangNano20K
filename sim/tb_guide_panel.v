`timescale 1ns/1ps
// Actual panel + guide authority: menu ownership, confirmation and run control.
module tb_guide_panel;
    reg clk=0,rst=1,ce=0,left=0,right=0,up=0,down=0;
    reg [7:0] keys=0;wire[7:0]play,preview,value,leds;wire[2:0]field,commit_field;
    wire settings,commit,toggle,enabled,song;wire[1:0]tempo;wire[63:0]state;
    integer checks=0,toggles=0,timbre_writes=0;
    localparam[55:0]MAP={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    performance_surface #(.HOLD_SAMPLES(2),.GUIDE_ENABLED(1)) panel(
        .clk(clk),.rst(rst),.sample_ce(ce),.physical_keys(keys),.settings_down(left),
        .confirm_down(right),.right_up(up),.right_down(down),.current_root(4'd0),
        .current_scale(2'd0),.current_octave(3'd4),.current_timbre(2'd0),
        .current_guide(enabled),.current_song(song),.current_tempo(tempo),.guide_toggle(toggle),
        .play_keys(play),.settings_active(settings),.selected_field(field),
        .preview_value(preview),.commit_valid(commit),.commit_field(commit_field),.commit_value(value));
    guide_control #(.SAMPLE_HZ(240)) control(clk,rst,ce,64'd0,1'b0,,,commit,commit_field,value,
        settings,field,toggle,MAP,MAP,play,1'b0,1'b1,8'd0,enabled,song,tempo,leds,state);
    always #5 clk=~clk;
    always @(posedge clk)if(!rst)begin
        if(toggle)toggles=toggles+1;
        if(commit&&commit_field==0)timbre_writes=timbre_writes+1;
    end
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide panel %0s",msg);$finish;end end endtask
    task frame;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(30)@(negedge clk);end endtask
    task select_key;input[7:0]mask;begin keys=0;frame();keys=mask;frame();end endtask
    task rotate;input inc;begin @(negedge clk);up=inc;down=!inc;@(negedge clk);up=0;down=0;end endtask
    task click;begin @(negedge clk);right=1;repeat(3)@(negedge clk);right=0;repeat(3)@(negedge clk);frame();frame();end endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;frame();left=1;frame();frame();
        check(settings,"held left enters settings");select_key(8'h20);
        check(field==0,"tempo selection unavailable in free play");
        select_key(8'h08);check(field==3&&preview==0&&play==0,"K4 selects mode without sounding");
        rotate(1);check(!enabled,"mode preview does not commit");click();
        check(enabled&&!state[1]&&toggles==0,"mode confirmation enables paused guide");
        select_key(8'h10);rotate(1);click();check(song&&field==4,"K5 chooses chord exercise");
        select_key(8'h20);rotate(1);rotate(1);click();check(tempo==0&&field==5,"K6 tempo wraps four choices");
        right=1;repeat(3)@(negedge clk);left=0;frame();right=0;frame();frame();
        check(!settings&&!state[1]&&toggles==0&&play==0,"menu press released after exit never resumes or sounds");
        keys=0;frame();rotate(1);rotate(1);rotate(0);frame();
        check(timbre_writes==0,"guide rotation cannot leak into timbre");
        click();check(state[1]&&toggles==1,"explicit direct GPIO click starts guide");
        left=1;frame();frame();check(settings&&!state[1],"settings pauses running guide");
        left=0;frame();frame();check(!state[1],"settings exit stays paused");
        // Right press begun before menu entry must also lose run-control ownership.
        right=1;frame();left=1;frame();frame();left=0;frame();right=0;frame();frame();
        check(!state[1]&&toggles==1,"press crossing settings cannot auto-resume");
        click();check(state[1]&&toggles==2,"fresh post-menu click resumes");
        left=1;frame();frame();select_key(8'h08);rotate(1);click();left=0;keys=0;frame();
        check(!enabled&&!state[1],"K4 returns to free performance");
        rotate(1);frame();check(timbre_writes==1,"free-play rotary timbre selection retained");
        $display("PASS guide panel %0d checks",checks);$finish;
    end
    initial begin #1000000;$display("FAIL guide panel timeout");$finish;end
endmodule
