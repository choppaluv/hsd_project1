`timescale 1ns / 1ps

module pe_con#(
       parameter VECTOR_SIZE = 64, // vector size
	   parameter L_RAM_SIZE = 6
    )
    (
        input start,
        output done,
        input aclk,
        input aresetn,
        //output [L_RAM_SIZE:0] rdaddr,
	    //input [31:0] rddata,
	    //output reg [31:0] wrdata,
	    
	    // to BRAM
	    output [31:0] BRAM_ADDR,
	    output [31:0] BRAM_WRDATA,
	    output [3:0] BRAM_WE,
	    output BRAM_CLK,
	    input [31:0] BRAM_RDDATA
);
   // PE
    wire [31:0] ain;
    wire [31:0] din;
    wire [L_RAM_SIZE-1:0] addr;
    wire we_local;
    wire we_global;
    //wire we;
    wire valid;
    wire dvalid [0:VECTOR_SIZE-1];
    wire [31:0] dout [0:VECTOR_SIZE-1];
    
    //bram addr
    // wire [L_RAM_SIZE-1:0] rdaddr;
    // wire [L_RAM_SIZE-1:0] upaddr;
    wire bitaddr; 
    wire [L_RAM_SIZE-1:0] row;

    wire [31:0] rddata;
    
    
    reg [31:0] wrdata;
    
    clk_wiz_0 u_clk (.clk_out1(BRAM_CLK), .clk_in1(aclk));
   
   genvar j;
   // global block ram
    reg [31:0] gdout [0:VECTOR_SIZE-1];
    (* ram_style = "block" *) reg [31:0] globalmem [0:VECTOR_SIZE-1][0:VECTOR_SIZE-1];

    always @(posedge aclk)
        if (we_global)
            globalmem[row][addr] <= rddata;
        else begin
            generate for (j=0; j<VECTOR_SIZE; j=j+1) begin : gdout64
                gdout[j] <= globalmem[j][addr];
            end endgenerate
        end

  
	//FSM
    // transition triggering flags
    wire load_done;
    wire calc_done;
    wire done_done;
    wire write_done;
        
    // state register
    reg [3:0] state, state_d;
    localparam S_IDLE = 4'd0;
    localparam S_LOAD = 4'd1;
    localparam S_CALC = 4'd2;
    localparam S_DONE = 4'd3;

	//part 1: state transition
    always @(posedge aclk)
        if (!aresetn)
            state <= S_IDLE;
        else
            case (state)
                S_IDLE:
                    state <= (start)? S_LOAD : S_IDLE;
                S_LOAD: // LOAD PERAM
                    state <= (load_done)? S_CALC : S_LOAD;
                S_CALC: // CALCULATE RESULT
                    state <= (calc_done)? S_DONE : S_CALC;
                S_DONE:
                    state <= (done_done)? S_IDLE : S_DONE;
                default:
                    state <= S_IDLE;
            endcase
    
    always @(posedge aclk)
        if (!aresetn)
            state_d <= S_IDLE;
        else
            state_d <= state;

	//part 2: determine state
    // S_LOAD
    reg load_flag;
    wire load_flag_reset = !aresetn || load_done;
    wire load_flag_en = (state_d == S_IDLE) && (state == S_LOAD);
    localparam CNTLOAD1 = (2*(VECTOR_SIZE*VECTOR_SIZE + VECTOR_SIZE)) -1;
    always @(posedge aclk)
        if (load_flag_reset)
            load_flag <= 'd0;
        else
            if (load_flag_en)
                load_flag <= 'd1;
            else
                load_flag <= load_flag;
    
    // S_CALC
    reg calc_flag;
    wire calc_flag_reset = !aresetn || calc_done;
    wire calc_flag_en = (state_d == S_LOAD) && (state == S_CALC);
    localparam CNTCALC1 = (VECTOR_SIZE) - 1;
    always @(posedge aclk)
        if (calc_flag_reset)
            calc_flag <= 'd0;
        else
            if (calc_flag_en)
                calc_flag <= 'd1;
            else
                calc_flag <= calc_flag;
    
    // S_DONE
    reg done_flag;
    wire done_flag_reset = !aresetn || done_done;
    wire done_flag_en = (state_d == S_CALC) && (state == S_DONE);
    localparam CNTDONE = 5;
    always @(posedge aclk)
        if (done_flag_reset)
            done_flag <= 'd0;
        else
            if (done_flag_en)
                done_flag <= 'd1;
            else
                done_flag <= done_flag;
    
    
    // down counter
    reg [31:0] counter;
    wire [31:0] ld_val = (load_flag_en)? CNTLOAD1 :
                         (calc_flag_en)? CNTCALC1 : 
                         (done_flag_en || write_done)? CNTDONE  : 'd0;
    wire counter_ld = load_flag_en || calc_flag_en || done_flag_en;
    wire counter_en = load_flag || &dvalid || done_flag;
    wire counter_reset = !aresetn || load_done || calc_done || done_done;
    always @(posedge aclk)
        if (counter_reset)
            counter <= 'd0;
        else
            if (write_done || done_flag_en)
                counter <= ld_val;
            else if (counter_en)
                counter <= counter - 1;
    
    // additional counter for done 64
    reg [L_RAM_SIZE-1:0] done_cnt;
    always @(posedge aclk)
        if (counter_reset)
            done_cnt <= 'd0;
        else
            if (done_flag_en)
                done_cnt <= VECTOR_SIZE;
            else if (write_done)
                done_cnt <= done_cnt - 1;

    //part3: update output and internal register
    //S_LOAD: we
	assign we_local = (load_flag && bitaddr && !counter[0]) ? 'd1 : 'd0;
	assign we_global = (load_flag && !bitaddr && !counter[0]) ? 'd1 : 'd0;
	
	//S_CALC: wrdata 
   always @(posedge aclk)
        if (!aresetn)
                wrdata <= 'd0;
        else
            if (calc_done || write_done)
                    wrdata <= dout[done_cnt];
            else
                    wrdata <= wrdata;

	//S_CALC: valid
    reg valid_pre, valid_reg;
    always @(posedge aclk)
        if (!aresetn)
            valid_pre <= 'd0;
        else
            if (counter_ld || counter_en)
                valid_pre <= 'd1;
            else
                valid_pre <= 'd0;
    
    always @(posedge aclk)
        if (!aresetn)
            valid_reg <= 'd0;
        else if (calc_flag)
            valid_reg <= valid_pre;
     
    assign valid = (calc_flag) && valid_reg;
    
	//S_CALC: ain
    genvar k;
    generate for (k=0; k<VECTOR_SIZE; k=k+1) begin : ain64
        assign ain[k] = (calc_flag)? gdout[k] : 'd0;
    end endgenerate

	//S_LOAD&&CALC
    assign addr = (load_flag)? counter[L_RAM_SIZE:1]:
                  (calc_flag)? counter[L_RAM_SIZE-1:0]: 'd0;

        // S_LOAD: row index of matrix
    assign row = (load_flag)? counter[2* L_RAM_SIZE:L_RAM_SIZE+1];

        // S_LOAD: bitaddr (bitaddr becomes 1 when starts reading vector from bram)
    assign bitaddr = counter[2*L_RAM_SIZE+1];

	//S_LOAD
	assign din = (load_flag)? rddata : 'd0;
    // assign rdaddr = (state == S_LOAD)? counter[L_RAM_SIZE+1:1] : 'd0;

	//done signals
    assign load_done = (load_flag) && (counter == 'd0);
    assign calc_done = (calc_flag) && (counter == 'd0) && (&dvalid);
    assign write_done = (done_flag) && (counter == 'd0);
    assign done_done = (done_flag) && (done_cnt == 'd0);
    assign done = (state == S_DONE) && done_done;
    
    
    // BRAM interface
    assign rddata = BRAM_RDDATA;
    assign BRAM_WRDATA = wrdata;
    
    assign BRAM_ADDR = (done_flag_en)? {24'd64, done_cnt, 2'b00} : { {29-L_RAM_SIZE*2{1'b0}}, bitaddr, row, addr, 2'b00};
    assign BRAM_WE = (done_flag_en)? 4'hF : 0;
    
    genvar i;

    generate for (i=0;i<VECTOR_SIZE;i=i+1) begin: pe64
    my_pe #(
        .L_RAM_SIZE(L_RAM_SIZE)
    ) u_pe (
        .aclk(aclk),
        .aresetn(aresetn && (state != S_DONE)),
        .ain(ain[i]),
        .din(din),
        .addr(addr),
        .we(we_local),
        .valid(valid),
        .dvalid(dvalid[i]),
        .dout(dout[i])
    );
    end endgenerate

endmodule
