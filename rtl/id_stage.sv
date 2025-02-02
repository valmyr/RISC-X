module id_stage import core_pkg::*; #(
    parameter bit ISA_M = 0,
    parameter bit ISA_C = 0,
    parameter bit ISA_F = 0
) (
    input  logic clk_i,
    input  logic rst_n_i,
    
    // Input from IF stage
    input  logic [31:0] pc_if_i,
    input  logic [31:0] instr_if_i,
    input  logic        valid_if_i,
    
    // Output to IF stage
    output logic [31:0] jump_target_id_o,
    
    // Output to EX stage
    output alu_operation_t alu_operation_id_o,
    output logic [ 4:0]    rd_addr_id_o,
    output logic           mem_wen_id_o,
    output data_type_t     mem_data_type_id_o,
    output logic           mem_sign_extend_id_o,
    output logic           reg_alu_wen_id_o,
    output logic           reg_mem_wen_id_o,
    output pc_source_t     pc_source_id_o,
    output logic           is_branch_id_o,
    output logic [31:0]    alu_operand_1_id_o,
    output logic [31:0]    alu_operand_2_id_o,
    output logic [31:0]    mem_wdata_id_o,
    output logic [31:0]    branch_target_id_o,
    output logic           valid_id_o,
    
    // Input from WB stage
    input  logic [31:0] reg_wdata_wb_i,
    input  logic [ 4:0] rd_addr_wb_i,
    input  logic        reg_wen_wb_i,
    
    // Output to controller
    output logic [ 4:0] rs1_addr_id_o,
    output logic [ 4:0] rs2_addr_id_o,
    
    // Output to CSRs
    output logic           csr_access_id_o,
    output csr_operation_t csr_op_id_o,
    
    // Control inputs
    input  logic stall_id_i,
    input  logic flush_ex_i,
    
    // Inputs for forwarding
    input  forward_t    fwd_op1_id_i,
    input  forward_t    fwd_op2_id_i,
    input  logic [31:0] alu_result_ex_i,
    input  logic [31:0] alu_result_mem_i,
    input  logic [31:0] mem_rdata_mem_i,
    input  logic [31:0] alu_result_wb_i,
    input  logic [31:0] mem_rdata_wb_i,
    input  logic [31:0] csr_rdata_ex_i
);

///////////////////////////////////////////////////////////////////////////////
//////////////////////        INSTRUCTION DECODE        ///////////////////////
///////////////////////////////////////////////////////////////////////////////

logic [31:0] pc_id;
logic [31:0] instr_id;

logic [31:0] rs1_rdata_id, rs2_rdata_id;
logic [31:0] rs1_or_fwd_id, rs2_or_fwd_id;

alu_source_1_t     alu_source_1_id; 
alu_source_2_t     alu_source_2_id; 
immediate_source_t immediate_type_id;
logic [31:0]       immediate_id;

logic illegal_instr_id;
logic instr_addr_misaligned_id;
logic trap_id;

// Pipeline registers IF->ID
always_ff @(posedge clk_i, negedge rst_n_i) begin
    if (!rst_n_i) begin
        pc_id    <= '0;
        instr_id <= '0;
    end else begin
        if (!stall_id_i) begin
            if (valid_if_i) begin
                pc_id    <= pc_if_i;
                instr_id <= instr_if_i;
            end
            // Insert bubble if previous stage wasn't valid
            else begin
                // instr_id <= '0;
                instr_id <= 32'h0000_0013; // NOP instruction
            end
        end
    end
end

decoder #(
    .ISA_M ( ISA_M ),
    .ISA_C ( ISA_C ),
    .ISA_F ( ISA_F )
) decoder_inst (
    // ALU related signals
	.alu_operation_o  ( alu_operation_id_o ),
    .alu_source_1_o   ( alu_source_1_id ), 
    .alu_source_2_o   ( alu_source_2_id ), 
    .immediate_type_o ( immediate_type_id ),
    
    // Source/destiny general purpose registers
    .rs1_addr_o (rs1_addr_id_o),
    .rs2_addr_o (rs2_addr_id_o),
    .rd_addr_o  (rd_addr_id_o),
    
    // Memory access related signals
    .mem_wen_o         ( mem_wen_id_o ),
    .mem_data_type_o   ( mem_data_type_id_o ),
    .mem_sign_extend_o ( mem_sign_extend_id_o ),
    
    // Write enable for ALU and mem access operations
    .reg_alu_wen_o ( reg_alu_wen_id_o ), 
    .reg_mem_wen_o ( reg_mem_wen_id_o ), 
    
    // Control transfer related signals
    .pc_source_o ( pc_source_id_o ), 
    .is_branch_o ( is_branch_id_o ),
    
    // CSR related signals
    .csr_access_o ( csr_access_id_o ),
    .csr_op_o     ( csr_op_id_o ),
    
    // Decoded an illegal instruction
    .illegal_instr_o ( illegal_instr_id ),
    
    // Instruction to be decoded
	.instr_i ( instr_id )
);

imm_extender imm_extender_inst (
    .immediate        ( immediate_id ),
    .immediate_type_i ( immediate_type_id ),
    .instr_i          ( instr_id )
);

register_file register_file_inst (
    .rdata1_o ( rs1_rdata_id ),
    .rdata2_o ( rs2_rdata_id ),
    .raddr1_i ( rs1_addr_id_o ),
    .raddr2_i ( rs2_addr_id_o ),
    
    .wdata_i  ( reg_wdata_wb_i ),
    .waddr_i  ( rd_addr_wb_i ),
    .wen_i    ( reg_wen_wb_i ),
    
    .clk_i    ( clk_i ),
    .rst_n_i  ( rst_n_i )
);

// Resolve forwarding for rs1 and rs2
always_comb begin
    unique case (fwd_op1_id_i)
        NO_FORWARD           : rs1_or_fwd_id = rs1_rdata_id;
        FWD_EX_ALU_RES_TO_ID : rs1_or_fwd_id = alu_result_ex_i;
        FWD_MEM_ALU_RES_TO_ID: rs1_or_fwd_id = alu_result_mem_i;
        FWD_MEM_RDATA_TO_ID  : rs1_or_fwd_id = mem_rdata_mem_i;
        FWD_WB_ALU_RES_TO_ID : rs1_or_fwd_id = alu_result_wb_i;
        FWD_WB_RDATA_TO_ID   : rs1_or_fwd_id = mem_rdata_wb_i;
        default: rs1_or_fwd_id = rs1_rdata_id;
    endcase
    unique case (fwd_op2_id_i)
        NO_FORWARD           : rs2_or_fwd_id = rs2_rdata_id;
        FWD_EX_ALU_RES_TO_ID : rs2_or_fwd_id = alu_result_ex_i;
        FWD_MEM_ALU_RES_TO_ID: rs2_or_fwd_id = alu_result_mem_i;
        FWD_MEM_RDATA_TO_ID  : rs2_or_fwd_id = mem_rdata_mem_i;
        FWD_WB_ALU_RES_TO_ID : rs2_or_fwd_id = alu_result_wb_i;
        FWD_WB_RDATA_TO_ID   : rs2_or_fwd_id = mem_rdata_wb_i;
        default: rs2_or_fwd_id = rs2_rdata_id;
    endcase
end

// ALU operands
always_comb begin
    unique case (alu_source_1_id)
        ALU_SCR1_RS1    : alu_operand_1_id_o = rs1_or_fwd_id;
        ALU_SCR1_PC     : alu_operand_1_id_o = pc_id;
        ALU_SCR1_ZERO   : alu_operand_1_id_o = 32'b0;
        ALU_SCR1_IMM_CSR: alu_operand_1_id_o = {27'b0, instr_id[19:15]}; // Pass CSR wdata as ALU operand
        default: alu_operand_1_id_o = 32'b0;
    endcase
    unique case (alu_source_2_id)
        ALU_SCR2_RS2   : alu_operand_2_id_o = rs2_or_fwd_id;
        ALU_SCR2_IMM   : alu_operand_2_id_o = immediate_id;
        ALU_SCR2_4_OR_2: alu_operand_2_id_o = 32'd4;
        default: alu_operand_2_id_o = 32'b0;
    endcase
end

// Pass forward the data to write in the memory
assign mem_wdata_id_o = rs2_or_fwd_id;

// Calculate branch target
assign branch_target_id_o = pc_id + immediate_id;

// Calculate jump target
always_comb begin
    unique case (pc_source_id_o)
        PC_JAL : jump_target_id_o = pc_id + immediate_id;
        PC_JALR: jump_target_id_o = rs1_or_fwd_id + immediate_id;
        default: jump_target_id_o = pc_id + immediate_id;
    endcase
    jump_target_id_o[0] = 1'b0; // Clear LSB
end

// Jump target misaligned exception
always_comb begin
    if (ISA_C) // No such exceptions if compressed instructions are allowed
        instr_addr_misaligned_id = 1'b0;
    else // If no compressed instructions, target must be 4-byte aligned
        instr_addr_misaligned_id = jump_target_id_o[1] && (pc_source_id_o inside {PC_JAL, PC_JALR});
end

// Traps: illegal instruction decoded, jump target misaligned
assign trap_id = illegal_instr_id || instr_addr_misaligned_id;

// Resolve validness. Not valid implies inserting bubble
// assign valid_id_o = !stall_id_i && !flush_ex_i && !illegal_instr_id;
assign valid_id_o = !stall_id_i && !flush_ex_i && !trap_id;


endmodule