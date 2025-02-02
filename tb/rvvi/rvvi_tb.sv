module rvvi_tb;

localparam int ADDR_WIDTH = 16;
localparam int MEM_SIZE = 2**ADDR_WIDTH;

localparam ISA_M = 0;
localparam ISA_C = 0;
localparam ISA_F = 0;

// Primary inputs
logic clk;
logic rst_n;

// Data memory interface
logic [31:0] dmem_rdata;
logic [31:0] dmem_wdata;
logic [31:0] dmem_addr;
logic        dmem_wen;
logic  [3:0] dmem_ben;

// Instruction memory interface
logic [31:0] imem_rdata;
logic [31:0] imem_addr;


localparam int TEXT_START_ADDR = 32'h0000_3000;
localparam int TEXT_END_ADDR   = 32'h0000_3ffc;
localparam int TEXT_SIZE       = TEXT_END_ADDR - TEXT_START_ADDR;
wire [ADDR_WIDTH-1:0] instr_addr = imem_addr + TEXT_START_ADDR;

`define CORE wrapper_inst.core_inst

//==============   Module instantiations - BEGIN   ==============//

rvviTrace #(
    .ILEN(32),  // Instruction length in bits
    .XLEN(32),  // GPR length in bits
    .FLEN(32),  // FPR length in bits
    .VLEN(256), // Vector register size in bits
    .NHART(1),   // Number of harts reported
    .RETIRE(1)    // Number of instructions that can retire during valid event
) rvvi ();

rvvi_wrapper #(
    .ISA_M(ISA_M),
    .ISA_C(ISA_C),
    .ISA_F(ISA_F)
) wrapper_inst (
    .clk_i   ( clk ),
    .rst_n_i ( rst_n ),
    
    .dmem_rdata_i ( dmem_rdata ),
    .dmem_wdata_o ( dmem_wdata ),
    .dmem_addr_o  ( dmem_addr ),
    .dmem_wen_o   ( dmem_wen ),
    .dmem_ben_o   ( dmem_ben ),
    
    .imem_rdata_i ( imem_rdata ),
    .imem_addr_o  ( imem_addr ),
    
    .rvvi ( rvvi )
);

rvvi_tracer tracer_inst (
    .clk_i   ( clk ),
    .rst_n_i ( rst_n ),
    
    .rvvi ( rvvi )
);

mem #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(32)
) mem_inst (
    .clk,
    .rst_n,
    
    // Port a (data)
    .rdata_a (dmem_rdata),
    .wdata_a (dmem_wdata),
    .addr_a  (dmem_addr[ADDR_WIDTH-1:0]),
    .wen_a   (dmem_wen),
    .ben_a   (dmem_ben),
    
    // Port b (instruction)
    .rdata_b (imem_rdata),
    .wdata_b (32'b0),
    // .addr_b  (imem_addr[ADDR_WIDTH-1:0]),
    .addr_b  (instr_addr),
    .wen_b   (1'b0),
    .ben_b   (4'b0)
);

//==============   Module instantiations - END   ==============//

//=================   Simulation - BEGIN   =================//

int n_mismatches;
int cnt_x_instr;
bit verbose = 0;

logic [31:0] regs_clone [32];
assign regs_clone[1:31] = `CORE.id_stage_inst.register_file_inst.mem;
assign regs_clone[0] = '0;
logic [31:0] dmem_clone [MEM_SIZE/4];
always_comb 
    foreach(dmem_clone[i]) begin //dmem_clone[i] = mem_inst.mem[i*4+:4];
        dmem_clone[i][ 0+:8] = mem_inst.mem[i*4  ];
        dmem_clone[i][ 8+:8] = mem_inst.mem[i*4+1];
        dmem_clone[i][16+:8] = mem_inst.mem[i*4+2];
        dmem_clone[i][24+:8] = mem_inst.mem[i*4+3];
    end
logic [31:0] instr_clone;
assign instr_clone = `CORE.id_stage_inst.instr_id;

logic [31:0] xptd_dmem [MEM_SIZE/4];
logic [31:0] xptd_regs [32];

string progs [] = '{"OP", "OP-IMM", "LUI_AUIPC", "ST_LD", 
                    "BRANCH", "JAL", "WR_ALL_MEM"};
// The tests below were copied from https://github.com/shrubbroom/Simple-RISC-V-testbench/tree/main
string progs_with_regs [] = '{"1_basic", 
                              "2_hazard_control_0", "2_hazard_data_0", "2_hazard_data_1", 
                              "3_bubble_sort", "3_fib", "3_qsort"};

string prog_name = "2_hazard_control_0";
string progs_path = "../basic_tb/programs/";
bit check_regs = 1;

localparam int PERIOD = 2;
localparam int MAX_CYCLES = 1000000;
initial begin
    clk = 0; 
    repeat(MAX_CYCLES) #(PERIOD/2) clk = ~clk;
    $display ("\n%t: Simulation reached the time limit. Terminating simulation.\n", $time);
    $finish;
end

initial begin
    // Specifying time format (%t)
    $timeformat(-9, 0, "ns", 12); // e.g.: "900ns"

    $display("#==========================================================#");
    
    $display("%t: text region size: %0d.", $time, TEXT_SIZE);
    reset ();
    
    drive_prog(prog_name, check_regs);
    
    $display("%t: Simulation end. Number of mismatches: %0d.", $time, n_mismatches);

    $display("#==========================================================#");
    $finish;
end

//=================   Simulation - END   =================//

//==============   Tasks and functions - BEGIN   ==============//

task reset ();
    @(negedge clk);
    rst_n = 0;
    @(negedge clk);
    rst_n = 1;
    $display("%t: Reset done.", $time);
endtask

task load_instr_mem (string prog_name, string prog_file);
    logic [31:0] mem [MEM_SIZE/4];
    int addr;
    $readmemh(prog_file, mem);
    foreach(mem[i]) begin
        addr = i*4 + TEXT_START_ADDR;
        mem_inst.mem[addr  ] = mem[i][ 0+:8];
        mem_inst.mem[addr+1] = mem[i][ 8+:8];
        mem_inst.mem[addr+2] = mem[i][16+:8];
        mem_inst.mem[addr+3] = mem[i][24+:8];
    end
    // print_instr_mem();
endtask

task print_instr_mem;
    logic [31:0] data;
    for(int i = TEXT_START_ADDR; i <= TEXT_END_ADDR; i += 4) begin
        data[ 0+:8] = mem_inst.mem[i  ];
        data[ 8+:8] = mem_inst.mem[i+1];
        data[16+:8] = mem_inst.mem[i+2];
        data[24+:8] = mem_inst.mem[i+3];
        $display("%t: Read 0x%h from memory address %8h.", $time, data, i);
    end
endtask

task print_regs;
    foreach(regs_clone[i]) begin
        $display("%t: Read 0x%h from register %0d.", $time, regs_clone[i], i);
    end
endtask

task load_xptd_dmem (string dmem_file);
    $readmemh(dmem_file, xptd_dmem);
endtask
task load_xptd_regs (string regs_file);
    $readmemh(regs_file, xptd_regs);
endtask

task checkit (string what_mem, logic [31:0] expected [], logic [31:0] actual []);
    $display("%t: Checking %s...", $time, what_mem);
    assert(expected.size() == actual.size()) else $display("Sizes don't match!");
    foreach (expected[i]) begin
        if (expected[i] != actual[i]) begin
            n_mismatches++;
            $display("%t: ERROR! Index = %0d. Expected = %h. Actual = %h. Mem = %s.", $time, i, expected[i], actual[i], what_mem);
        end
    end
    $display("%t: Done checking.", $time);
endtask

task drive_prog (string prog_name, bit check_regs);
    string prog_file;
    string dmem_file;
    string regs_file;
    
    if (prog_name != "all") begin
        prog_file = {progs_path, prog_name, "_prog.txt"};
        dmem_file = {progs_path, prog_name, "_data.txt"};
        regs_file = {progs_path, prog_name, "_regs.txt"};
        
        $display("#==========================================================#");
        $display("%t: Executing program %s.", $time, prog_name);
        reset ();
        
        // Load instructions into instruction memory
        load_instr_mem(prog_name, prog_file);
        
        // Wait for instructions to end
        do begin
            @(negedge clk);
            if (instr_clone === 'x) // After the end of instr mem code, there's only unknowns
                cnt_x_instr++;
            else
                cnt_x_instr = 0;
            // $display("%t: Instr in ID stage is = %h. %g", $time, instr_clone, rvvi.valid[0][0]);
            // $display("%t: Instr in WB stage is = %h. %g", $time, wrapper_inst.rvfi_insn, rvvi.valid[0][0]);
        end while (cnt_x_instr != 4); // Proceed when 4 consecutive 'x instrs happen in ID stage

        // Get expected data memory values (got from RARS simulator)
        load_xptd_dmem(dmem_file);
        if (check_regs)
            load_xptd_regs(regs_file);
        
        if (verbose) begin
            foreach (xptd_dmem[i]) begin
                if(i == 32) break;
                $display("xptd_dmem[%2d] = %h. dmem[%2d] = %h.", i, xptd_dmem[i], i, dmem_clone[i]);
            end
        end
        checkit("dmem", xptd_dmem, dmem_clone);
        
        if (check_regs) begin
            if (verbose)
                foreach (xptd_regs[i])
                    $display("xptd_regs[%2d] = %h. reg[%2d] = %h.", i, xptd_regs[i], i, regs_clone[i]);
            checkit("regs", xptd_regs, regs_clone);
        end

        $display("%t: Finished executing program %s.", $time, prog_name);
        $display("%t: Simulation end. Number of mismatches: %0d.", $time, n_mismatches);
        $display("#==========================================================#");
    end // if (prog_name != "all")
    else begin
        foreach(progs[i]) begin
            string single_prog;
            single_prog = progs[i];
        
            drive_prog (single_prog, 0);
        end
    end
endtask

//==============   Tasks and functions - END   ==============//

endmodule