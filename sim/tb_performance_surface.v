`timescale 1ns/1ps
module tb_performance_surface;
    reg clk=0,rst=1,sample_ce=0;
    reg [7:0] physical_keys=0;
    reg settings_down=0,confirm_down=0,right_up=0,right_down=0;
    reg [3:0] current_root=2;
    reg [1:0] current_scale=0,current_timbre=0;
    reg [2:0] current_octave=4;
    wire [7:0] play_keys,preview_value,commit_value;
    wire settings_active,commit_valid;
    wire [1:0] selected_field,commit_field;
    integer commits=0;
    reg [1:0] last_field;
    reg [7:0] last_value;
    reg previous_commit=0;
    performance_surface #(.HOLD_SAMPLES(3)) dut(
        .clk(clk),.rst(rst),.sample_ce(sample_ce),.physical_keys(physical_keys),
        .settings_down(settings_down),.confirm_down(confirm_down),
        .right_up(right_up),.right_down(right_down),.current_root(current_root),
        .current_scale(current_scale),.current_octave(current_octave),
        .current_timbre(current_timbre),.play_keys(play_keys),
        .settings_active(settings_active),.selected_field(selected_field),
        .preview_value(preview_value),.commit_valid(commit_valid),
        .commit_field(commit_field),.commit_value(commit_value));
    always #5 clk=~clk;
    always @(posedge clk) begin
        #1;
        if(rst) previous_commit=0;
        else begin
            if(commit_valid) begin
                if(previous_commit) begin $display("FAIL commit is longer than one system clock"); $finish; end
                commits=commits+1;last_field=commit_field;last_value=commit_value;
            end
            previous_commit=commit_valid;
        end
    end
    task tick; input integer n; begin repeat(n) begin @(negedge clk); #1; end end endtask
    task frame; begin sample_ce=1;tick(1);sample_ce=0;tick(4);end endtask
    task reset;
        begin
            rst=1;sample_ce=0;physical_keys=0;settings_down=0;confirm_down=0;
            right_up=0;right_down=0;current_root=2;current_scale=0;
            current_octave=4;current_timbre=0;tick(3);rst=0;tick(2);
            commits=0;
        end
    endtask
    task step;input up;begin right_up=up;right_down=!up;tick(1);right_up=0;right_down=0;tick(2);end endtask
    task enter_settings;
        begin
            settings_down=1;frame;frame;
            if(settings_active) begin $display("FAIL settings entered before HOLD_SAMPLES");$finish;end
            tick(15);
            if(settings_active) begin $display("FAIL hold counted system clocks");$finish;end
            frame;
            if(!settings_active) begin $display("FAIL held left button did not enter settings");$finish;end
        end
    endtask
    task confirm;begin confirm_down=1;tick(2);confirm_down=0;tick(2);end endtask
    initial begin
        // Dropping the press owner or merging menu keys into play_keys breaks this.
        reset;physical_keys=8'h08;frame;
        if(play_keys!==8'h08) begin $display("FAIL perform key did not sound");$finish;end
        settings_down=1;frame;frame;physical_keys=8'h0a;frame;
        if(!settings_active || play_keys!==8'h08 || selected_field!==1 || preview_value!==2) begin
            $display("FAIL entry ownership/new K2 selection play=%h field=%d preview=%d",play_keys,selected_field,preview_value);$finish;end
        physical_keys=8'h02;tick(1);
        if(play_keys!==0) begin $display("FAIL held perform note release was delayed/lost in settings");$finish;end
        settings_down=0;tick(2);frame;
        if(settings_active || play_keys!==0) begin $display("FAIL menu hold leaked into perform on exit");$finish;end
        physical_keys=0;frame;physical_keys=2;frame;
        if(play_keys!==2) begin $display("FAIL menu key could not play after release/repress");$finish;end
        // A menu press just after sample_ce remains a menu owner on exit.
        reset;enter_settings;physical_keys=8'h40;tick(1);settings_down=0;tick(2);frame;
        if(play_keys!==0) begin $display("FAIL between-frame menu press leaked after exit");$finish;end
        physical_keys=0;tick(1);physical_keys=8'h40;frame;
        if(play_keys!==8'h40) begin $display("FAIL between-frame menu release/repress remained blocked");$finish;end

        // A menu preview must not send authoritative writes before release confirmation.
        reset;enter_settings;
        physical_keys=3;frame;
        if(selected_field!==0) begin $display("FAIL simultaneous selection did not choose lowest key");$finish;end
        step(1);step(1);
        if(preview_value!==2 || commits!=0) begin $display("FAIL timbre preview/accumulation");$finish;end
        confirm_down=1;tick(3);
        if(commits!=0) begin $display("FAIL confirm committed on press");$finish;end
        confirm_down=0;tick(2);
        if(commits!=1 || last_field!==0 || last_value!==2 || current_timbre!==0) begin $display("FAIL release did not propose timbre independently of authority");$finish;end
        current_timbre=2;physical_keys=0;frame;physical_keys=2;frame;
        if(selected_field!==1 || preview_value!==2) begin $display("FAIL K2 current root/scale snapshot");$finish;end
        step(0);step(0);step(0);
        if(preview_value!==23) begin $display("FAIL key signature wrap at zero");$finish;end
        confirm;
        if(commits!=2 || last_field!==1 || last_value!==23) begin $display("FAIL key signature proposal");$finish;end
        current_root=11;current_scale=1;physical_keys=0;frame;physical_keys=4;frame;
        if(selected_field!==2 || preview_value!==4) begin $display("FAIL K3 octave selection");$finish;end
        step(1);step(1);step(1);
        if(preview_value!==2) begin $display("FAIL octave did not wrap within 2..6");$finish;end
        confirm;
        if(commits!=3 || last_field!==2 || last_value!==2) begin $display("FAIL octave proposal");$finish;end
        physical_keys=0;frame;physical_keys=8'h80;frame;
        if(selected_field!==2 || play_keys!==0) begin $display("FAIL reserved menu key changed field or sounded");$finish;end
        step(1);settings_down=0;tick(2);
        if(settings_active || commits!=3) begin $display("FAIL unconfirmed preview was committed on exit");$finish;end

        // Left release wins over right release even between sample_ce boundaries.
        reset;enter_settings;step(1);confirm_down=1;tick(2);
        settings_down=0;confirm_down=0;tick(2);
        if(settings_active || commits!=0) begin $display("FAIL simultaneous button release committed cancelled preview");$finish;end

        // Each detent is captured between audio frames; reversal cancels the delta.
        reset;step(1);step(1);step(0);frame;
        if(commits!=1 || last_field!==0 || last_value!==1) begin $display("FAIL perform detents between sample strobes were lost");$finish;end
        step(1);frame;
        if(commits!=1) begin $display("FAIL unacknowledged proposal used stale authoritative timbre");$finish;end
        current_timbre=1;tick(2);frame;
        if(commits!=2 || last_value!==2) begin $display("FAIL detent during commit latency was lost");$finish;end
        current_timbre=2;tick(2);step(1);step(0);frame;
        if(commits!=2) begin $display("FAIL opposite detents produced a spurious commit");$finish;end

        // Prior PERFORM detents are not applied to a newly selected menu field.
        reset;settings_down=1;frame;frame;step(1);physical_keys=2;frame;
        if(!settings_active || selected_field!==1 || preview_value!==2 || commits!=1 || last_field!==0 || last_value!==1) begin
            $display("FAIL detent crossed perform/settings boundary");$finish;end
        current_timbre=1;tick(2);step(0);
        if(preview_value!==1) begin $display("FAIL menu detent before exit");$finish;end
        settings_down=0;tick(2);frame;
        if(commits!=1) begin $display("FAIL menu detent leaked into perform after exit");$finish;end
        // A detent exactly at entry belongs to the newly selected menu field.
        reset;settings_down=1;frame;frame;physical_keys=4;right_up=1;sample_ce=1;tick(1);
        right_up=0;sample_ce=0;tick(3);
        if(preview_value!==5 || selected_field!==2 || commits!=0) begin $display("FAIL entry-cycle detent routed to perform");$finish;end
        confirm_down=1;tick(1);confirm_down=0;right_up=1;tick(1);right_up=0;tick(2);
        if(commits!=1 || last_field!==2 || last_value!==6) begin $display("FAIL confirm release omitted same-cycle detent");$finish;end
        // A confirmation immediately after a PERFORM proposal needs a separate pulse.
        reset;settings_down=1;frame;frame;step(1);confirm_down=1;tick(1);
        // This key is pressed on entry; a prior-clock press belongs to PERFORM.
        physical_keys=2;sample_ce=1;tick(1);sample_ce=0;confirm_down=0;tick(4);
        if(commits!=2 || last_field!==1 || last_value!==2) begin $display("FAIL adjacent perform/confirm proposals lost a transaction");$finish;end
        // A previous proposal's late echo cannot acknowledge the next target.
        reset;settings_down=1;frame;frame;step(1);frame;
        step(1);step(1);confirm_down=1;tick(1);confirm_down=0;sample_ce=1;
        @(posedge clk);current_timbre<=1;tick(1);sample_ce=0;tick(3);
        if(commits!=2 || last_value!==2) begin $display("FAIL phase fixture menu target");$finish;end
        settings_down=0;tick(2);step(1);sample_ce=1;
        @(posedge clk);current_timbre<=2;tick(1);sample_ce=0;tick(3);
        if(commits!=2) begin $display("FAIL older timbre echo unlocked uncommitted menu target");$finish;end
        frame;
        if(commits!=3 || last_value!==0) begin $display("FAIL rotary after late echo lost a detent");$finish;end
        $display("PASS performance settings hold, key ownership, preview, release confirmation and detent boundaries");$finish;
    end
    initial begin #1000000;$display("FAIL timeout");$finish;end
endmodule
