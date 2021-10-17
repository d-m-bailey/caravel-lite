// SPDX-FileCopyrightText: 2020 Efabless Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

//-----------------------------------------------------------
// Housekeeping interface for Caravel
//-----------------------------------------------------------
// Written by Tim Edwards
// efabless, inc. September 27, 2020
//-----------------------------------------------------------

//-----------------------------------------------------------
// This is a standalone slave SPI for the caravel chip that is
// intended to be independent of the picosoc and independent
// of all IP blocks except the power-on-reset.  This SPI has
// register outputs controlling the functions that critically
// affect operation of the picosoc and so cannot be accessed
// from the picosoc itself.  This includes the PLL enables,
// mode, and trim.  It also has a general reset for the picosoc,
// an IRQ input, a bypass for the entire crystal oscillator
// and PLL chain, the manufacturer and product IDs and product
// revision number.
//
// Updated and revised, 10/13/2021:
// This module now comprises what was previously split into
// the housekeeping SPI, the mprj_ctrl block (control over
// the GPIO), and sysctrl (redirection of certain internal
// signals to the GPIO);  and additionally manages the SPI
// flash signals and pass-through mode.  Essentially all
// aspects of the system related to the use and configuration
// of the GPIO has been shifted to this module.  This allows
// GPIO to be configured from either the management SoC
// through the wishbone interface, or externally through the
// SPI interface.  It allows essentially any processor to
// take the place of the PicoRV32 as long as that processor
// can access memory-mapped space via the wishbone bus.
//-----------------------------------------------------------

//------------------------------------------------------------
// Caravel defined registers (by SPI address):
// See:  doc/memory_map.txt
//------------------------------------------------------------

module housekeeping #(
    parameter GPIO_BASE_ADR = 32'h2600_0000,
    parameter SPI_BASE_ADR = 32'h2610_0000,
    parameter SYS_BASE_ADR = 32'h2620_0000,
    parameter IO_CTRL_BITS = 13
) (
`ifdef USE_POWER_PINS
    inout vdd,
    inout vss, 
`endif

    // Wishbone interface to management SoC
    input wb_clk_i,
    input wb_rst_i,
    input [31:0] wb_adr_i,
    input [31:0] wb_dat_i,
    input [3:0] wb_sel_i,
    input wb_we_i,
    input wb_cyc_i,
    input wb_stb_i,
    output wb_ack_o,
    output [31:0] wb_dat_o,

    // Primary reset
    input porb,

    // Clocking control parameters
    output pll_ena,
    output pll_dco_ena,
    output [4:0] pll_div,
    output [2:0] pll_sel,
    output [2:0] pll90_sel,
    output [25:0] pll_trim,
    output pll_bypass,

    // Module enable status from SoC
    input  qspi_enabled,	// Flash SPI is in quad mode
    input  uart_enabled,	// UART is enabled
    input  spi_enabled,		// SPI master is enabled
    input  debug_mode,		// Debug mode enabled

    // UART interface to/from SoC
    input  ser_tx,
    output ser_rx,

    // SPI master interface to/from SoC
    output spi_sdi,
    input  spi_csb,
    input  spi_sck,
    input  spi_sdo,

    // External (originating from SPI and pad) IRQ and reset
    output [2:0] irq,
    output reset,

    // GPIO serial loader programming interface
    output serial_clock,
    output serial_resetn,
    output serial_data_1,
    output serial_data_2,

    // GPIO data management (to padframe)---three-pin interface
    input  [`MPRJ_IO_PADS-1:0] mgmt_gpio_in,
    output [`MPRJ_IO_PADS-1:0] mgmt_gpio_out,
    output [`MPRJ_IO_PADS-1:0] mgmt_gpio_oeb,

    // Power control output (reserved for future use with LDOs)
    output [`MPRJ_PWR_PADS-1:0] pwr_ctrl_out,

    // CPU trap state status (for system monitoring)
    input trap,

    // User clock (for system monitoring)
    input user_clock,

    // Mask revision/User project ID
    input [31:0] mask_rev_in,

    // SPI flash management (management SoC side)
    input spimemio_flash_csb,
    input spimemio_flash_clk,
    input spimemio_flash_io0_oeb,
    input spimemio_flash_io1_oeb,
    input spimemio_flash_io2_oeb,
    input spimemio_flash_io3_oeb,
    input spimemio_flash_io0_do,
    input spimemio_flash_io1_do,
    input spimemio_flash_io2_do,
    input spimemio_flash_io3_do,
    output spimemio_flash_io0_di,
    output spimemio_flash_io1_di,
    output spimemio_flash_io2_di,
    output spimemio_flash_io3_di,

    // Debug interface (routes to first GPIO) from management SoC
    output debug_in,
    input debug_out,
    input debug_oeb,

    // SPI flash management (padframe side)
    // (io2 and io3 are part of GPIO array, not dedicated pads)
    output pad_flash_csb,
    output pad_flash_csb_oeb,
    output pad_flash_clk,
    output pad_flash_clk_oeb,
    output pad_flash_io0_oeb,
    output pad_flash_io1_oeb,
    output pad_flash_io0_ieb,
    output pad_flash_io1_ieb,
    output pad_flash_io0_do,
    output pad_flash_io1_do,
    input pad_flash_io0_di,
    input pad_flash_io1_di,

    // System signal monitoring
    input  usr1_vcc_pwrgood,
    input  usr2_vcc_pwrgood,
    input  usr1_vdd_pwrgood,
    input  usr2_vdd_pwrgood
);

    localparam OEB = 1;		// Offset of output enable (bar) in shift register
    localparam INP_DIS = 3;	// Offset of input disable in shift register

    reg [25:0] pll_trim;
    reg [4:0] pll_div;
    reg [2:0] pll_sel;
    reg [2:0] pll90_sel;
    reg pll_dco_ena;
    reg pll_ena;
    reg pll_bypass;
    reg reset_reg;
    reg irq_spi;
    reg serial_bb_clock;
    reg serial_bb_resetn;
    reg serial_bb_data_1;
    reg serial_bb_data_2;
    reg serial_bb_enable;
    reg serial_xfer;

    reg clk1_output_dest;
    reg clk2_output_dest;
    reg trap_output_dest;
    reg irq_1_inputsrc;
    reg irq_2_inputsrc;

    reg [IO_CTRL_BITS-1:0] gpio_configure [`MPRJ_IO_PADS-1:0];
    reg [`MPRJ_IO_PADS-1:0] mgmt_gpio_data;
    reg [`MPRJ_PWR_PADS-1:0] pwr_ctrl_out;

    wire usr1_vcc_pwrgood;
    wire usr2_vcc_pwrgood;
    wire usr1_vdd_pwrgood;
    wire usr2_vdd_pwrgood;

    wire [7:0] odata;
    wire [7:0] idata;
    wire [7:0] iaddr;

    wire [2:0] irq;

    wire trap;
    wire rdstb;
    wire wrstb;
    wire pass_thru_mgmt;		// Mode detected by housekeeping_spi
    wire pass_thru_mgmt_delay;
    wire pass_thru_user;		// Mode detected by housekeeping_spi
    wire pass_thru_user_delay;
    wire pass_thru_mgmt_reset;
    wire pass_thru_user_reset;
    wire sdo;
    wire sdo_enb;

    wire [7:0]	caddr;	// Combination of SPI address and back door address
    wire [7:0]	cdata;	// Combination of SPI data and back door data
    wire	cwstb;	// Combination of SPI write strobe and back door write strobe
    wire	csclk;	// Combination of SPI SCK and back door access trigger

    // Housekeeping side 3-wire interface to GPIOs (see below)
    wire [`MPRJ_IO_PADS-1:0] mgmt_gpio_out_pre;

    // Pass-through mode handling.  Signals may only be applied when the
    // core processor is in reset.

    assign reset = (pass_thru_mgmt_reset) ? 1'b1 : reset_reg;

    // Handle the management-side control of the GPIO pins.  All but the
    // first and last two GPIOs (0, 1 and 36, 37) are one-pin interfaces with
    // a single I/O pin whose direction is determined by the local OEB signal.
    // The other four are straight-through connections of the 3-wire interface.

    assign mgmt_gpio_out[`MPRJ_IO_PADS-1:`MPRJ_IO_PADS-2] =
			mgmt_gpio_out_pre[`MPRJ_IO_PADS-1:`MPRJ_IO_PADS-2];
    assign mgmt_gpio_out[1:0] = mgmt_gpio_out_pre[1:0];

    genvar i;

    // This implements high-impedence buffers on the GPIO outputs other than
    // the first and last two GPIOs so that these pins can be tied together
    // at the top level to create the single-wire interface on those GPIOs.
    generate
	for (i = 2; i < `MPRJ_IO_PADS-2; i = i + 1) begin
	    assign mgmt_gpio_out[i] = mgmt_gpio_oeb[i] ?  1'bz : mgmt_gpio_out_pre[i];
	end
    endgenerate

    // Pass-through mode.  Housekeeping SPI signals get inserted
    // between the management SoC and the flash SPI I/O.

    assign pad_flash_csb = (pass_thru_mgmt) ? mgmt_gpio_in[3] : spimemio_flash_csb;
    assign pad_flash_csb_oeb = (pass_thru_mgmt) ? 1'b0 : (~porb ? 1'b1 : 1'b0);
    assign pad_flash_clk = (pass_thru_mgmt) ? mgmt_gpio_in[4] : spimemio_flash_clk;
    assign pad_flash_clk_oeb = (pass_thru_mgmt) ? 1'b0 : (~porb ? 1'b1 : 1'b0);
    assign pad_flash_io0_oeb = (pass_thru_mgmt) ? 1'b0 : spimemio_flash_io0_oeb;
    assign pad_flash_io1_oeb = (pass_thru_mgmt) ? 1'b1 : spimemio_flash_io1_oeb;
    assign pad_flash_io0_ieb = (pass_thru_mgmt) ? 1'b1 : ~spimemio_flash_io0_oeb;
    assign pad_flash_io1_ieb = (pass_thru_mgmt) ? 1'b1 : ~spimemio_flash_io1_oeb;
    assign pad_flash_io0_do = (pass_thru_mgmt) ? mgmt_gpio_in[2] : spimemio_flash_io0_do;
    assign pad_flash_io1_do = spimemio_flash_io1_do;
    assign spimemio_flash_io0_di = (pass_thru_mgmt) ? 1'b0 : pad_flash_io0_di;
    assign spimemio_flash_io1_di = (pass_thru_mgmt) ? 1'b0 : pad_flash_io1_di;

    // Wishbone bus "back door" to SPI registers.  This section of code
    // (1) Maps SPI byte addresses to memory map 32-bit addresses
    // (2) Applies signals to the housekeeping SPI to mux in the SPI address,
    //	   clock, and write strobe.  This is done carefully and slowly to
    //	   avoid glitching on the SCK line and to avoid forcing the
    //	   housekeeping module to keep up with the core clock timing.

    wire      	sys_select;	// System monitoring memory map address selected
    wire      	gpio_select;	// GPIO configuration memory map address selected
    wire      	spi_select;	// SPI back door memory map address selected

    // Wishbone Back Door.  This is a simple interface making use of the
    // housekeeping SPI protocol.  The housekeeping SPI uses byte-wide
    // data, so this interface will stall the processor by holding wb_ack_o
    // low until all bytes have been transferred between the processor and
    // housekeeping SPI.

    reg [3:0] 	wbbd_state;
    reg [7:0] 	wbbd_addr;	/* SPI address translated from WB */
    reg [7:0] 	wbbd_data;	/* SPI data translated from WB */
    reg  	wbbd_sck;	/* wishbone access trigger (back-door clock) */
    reg  	wbbd_write;	/* wishbone write trigger (back-door strobe) */
    reg		wb_ack_o;	/* acknowledge signal back to wishbone bus */
    reg [31:0]	wb_dat_o;	/* data output to wishbone bus */

    // This defines a state machine that accesses the SPI registers through
    // the back door wishbone interface.  The process is relatively slow
    // since the SPI data are byte-wide, so four individual accesses are
    // made to read 4 bytes from the SPI to fill data on the wishbone bus
    // before sending ACK and letting the processor continue.

    `define WBD_IDLE	4'h0	/* Back door access is idle */
    `define WBD_SETUP0	4'h1	/* Apply address and data for byte 1 of 4 */
    `define WBD_RW0	4'h2	/* Latch data for byte 1 of 4 */
    `define WBD_SETUP1	4'h3	/* Apply address and data for byte 2 of 4 */
    `define WBD_RW1	4'h4	/* Latch data for byte 2 of 4 */
    `define WBD_SETUP2	4'h5	/* Apply address and data for byte 3 of 4 */
    `define WBD_RW2	4'h6	/* Latch data for byte 3 of 4 */
    `define WBD_SETUP3	4'h7	/* Apply address and data for byte 4 of 4 */
    `define WBD_RW3	4'h8	/* Latch data for byte 4 of 4 */
    `define WBD_DONE	4'h9	/* Send ACK back to wishbone */

    assign sys_select = (wb_adr_i[31:8] == SYS_BASE_ADR[31:8]);
    assign gpio_select = (wb_adr_i[31:8] == GPIO_BASE_ADR[31:8]);
    assign spi_select = (wb_adr_i[31:8] == SPI_BASE_ADR[31:8]);

    /* Register bit to SPI address mapping */

    function [7:0] fdata(input [7:0] address);
	begin
	case (address)
	    /* Housekeeping SPI Protocol */
	    8'h00 : fdata = 8'h00;			// SPI status (fixed) 

	    /* Status and Identification */
	    8'h01 : fdata = {4'h0, mfgr_id[11:8]};	// Manufacturer ID (fixed)
	    8'h02 : fdata = mfgr_id[7:0];		// Manufacturer ID (fixed)
	    8'h03 : fdata = prod_id;			// Product ID (fixed)
	    8'h04 : fdata = mask_rev[31:24];		// Mask rev (via programmed)
	    8'h05 : fdata = mask_rev[23:16];		// Mask rev (via programmed)
	    8'h06 : fdata = mask_rev[15:8];		// Mask rev (via programmed)
	    8'h07 : fdata = mask_rev[7:0];		// Mask rev (via programmed)
	    8'h08 : fdata = {7'b0000000, trap};		// CPU trap state

	    /* System monitoring */
	    8'h09 : fdata = {4'b0000, usr1_vcc_pwrgood, usr2_vcc_pwrgood,
				usr1_vdd_pwrgood, usr2_vdd_pwrgood};
	    8'h0a : fdata = {5'b00000, clk1_output_dest, clk2_output_dest,
				trap_output_dest};
	    8'h0b : fdata = {6'b000000, irq_2_inputsrc, irq_1_inputsrc};

	    /* GPIO Configuration */
	    8'h0c : fdata = {3'b000, gpio_configure[0][12:8]};
	    8'h0d : fdata = gpio_configure[0][7:0];
	    8'h0e : fdata = {3'b000, gpio_configure[1][12:8]};
	    8'h0f : fdata = gpio_configure[1][7:0];
	    8'h10 : fdata = {3'b000, gpio_configure[2][12:8]};
	    8'h11 : fdata = gpio_configure[2][7:0];
	    8'h12 : fdata = {3'b000, gpio_configure[3][12:8]};
	    8'h13 : fdata = gpio_configure[3][7:0];
	    8'h14 : fdata = {3'b000, gpio_configure[4][12:8]};
	    8'h15 : fdata = gpio_configure[4][7:0];
	    8'h16 : fdata = {3'b000, gpio_configure[5][12:8]};
	    8'h17 : fdata = gpio_configure[5][7:0];
	    8'h18 : fdata = {3'b000, gpio_configure[6][12:8]};
	    8'h19 : fdata = gpio_configure[6][7:0];
	    8'h1a : fdata = {3'b000, gpio_configure[7][12:8]};
	    8'h1b : fdata = gpio_configure[7][7:0];
	    8'h1c : fdata = {3'b000, gpio_configure[8][12:8]};
	    8'h1d : fdata = gpio_configure[8][7:0];
	    8'h1e : fdata = {3'b000, gpio_configure[9][12:8]};
	    8'h1f : fdata = gpio_configure[9][7:0];
	    8'h20 : fdata = {3'b000, gpio_configure[10][12:8]};
	    8'h21 : fdata = gpio_configure[10][7:0];
	    8'h22 : fdata = {3'b000, gpio_configure[11][12:8]};
	    8'h23 : fdata = gpio_configure[11][7:0];
	    8'h24 : fdata = {3'b000, gpio_configure[12][12:8]};
	    8'h25 : fdata = gpio_configure[12][7:0];
	    8'h26 : fdata = {3'b000, gpio_configure[13][12:8]};
	    8'h27 : fdata = gpio_configure[13][7:0];
	    8'h28 : fdata = {3'b000, gpio_configure[14][12:8]};
	    8'h29 : fdata = gpio_configure[14][7:0];
	    8'h2a : fdata = {3'b000, gpio_configure[15][12:8]};
	    8'h2b : fdata = gpio_configure[15][7:0];
	    8'h2c : fdata = {3'b000, gpio_configure[16][12:8]};
	    8'h2d : fdata = gpio_configure[16][7:0];
	    8'h2e : fdata = {3'b000, gpio_configure[17][12:8]};
	    8'h2f : fdata = gpio_configure[17][7:0];
	    8'h30 : fdata = {3'b000, gpio_configure[18][12:8]};
	    8'h31 : fdata = gpio_configure[18][7:0];
	    8'h32 : fdata = {3'b000, gpio_configure[19][12:8]};
	    8'h33 : fdata = gpio_configure[19][7:0];
	    8'h34 : fdata = {3'b000, gpio_configure[20][12:8]};
	    8'h35 : fdata = gpio_configure[20][7:0];
	    8'h36 : fdata = {3'b000, gpio_configure[21][12:8]};
	    8'h37 : fdata = gpio_configure[21][7:0];
	    8'h38 : fdata = {3'b000, gpio_configure[22][12:8]};
	    8'h39 : fdata = gpio_configure[22][7:0];
	    8'h3a : fdata = {3'b000, gpio_configure[23][12:8]};
	    8'h3b : fdata = gpio_configure[23][7:0];
	    8'h3c : fdata = {3'b000, gpio_configure[24][12:8]};
	    8'h3d : fdata = gpio_configure[24][7:0];
	    8'h3e : fdata = {3'b000, gpio_configure[25][12:8]};
	    8'h3f : fdata = gpio_configure[25][7:0];
	    8'h40 : fdata = {3'b000, gpio_configure[26][12:8]};
	    8'h41 : fdata = gpio_configure[26][7:0];
	    8'h42 : fdata = {3'b000, gpio_configure[27][12:8]};
	    8'h43 : fdata = gpio_configure[27][7:0];
	    8'h44 : fdata = {3'b000, gpio_configure[27][12:8]};
	    8'h45 : fdata = gpio_configure[28][7:0];
	    8'h46 : fdata = {3'b000, gpio_configure[29][12:8]};
	    8'h47 : fdata = gpio_configure[29][7:0];
	    8'h48 : fdata = {3'b000, gpio_configure[30][12:8]};
	    8'h49 : fdata = gpio_configure[30][7:0];
	    8'h4a : fdata = {3'b000, gpio_configure[31][12:8]};
	    8'h4b : fdata = gpio_configure[31][7:0];
	    8'h4c : fdata = {3'b000, gpio_configure[32][12:8]};
	    8'h4d : fdata = gpio_configure[32][7:0];
	    8'h4e : fdata = {3'b000, gpio_configure[33][12:8]};
	    8'h4f : fdata = gpio_configure[33][7:0];
	    8'h50 : fdata = {3'b000, gpio_configure[34][12:8]};
	    8'h51 : fdata = gpio_configure[34][7:0];
	    8'h52 : fdata = {3'b000, gpio_configure[35][12:8]};
	    8'h53 : fdata = gpio_configure[35][7:0];
	    8'h54 : fdata = {3'b000, gpio_configure[36][12:8]};
	    8'h55 : fdata = gpio_configure[36][7:0];
	    8'h56 : fdata = {3'b000, gpio_configure[37][12:8]};
	    8'h57 : fdata = gpio_configure[37][7:0];

	    // GPIO Data
	    8'h58 : fdata = {2'b00, mgmt_gpio_in[`MPRJ_IO_PADS-1:32]};
	    8'h59 : fdata = mgmt_gpio_in[31:24];
	    8'h5a : fdata = mgmt_gpio_in[23:16];
	    8'h5b : fdata = mgmt_gpio_in[15:8];
	    8'h5c : fdata = mgmt_gpio_in[7:0];

	    // Power Control (reserved)
	    8'h5d : fdata = {4'b0000, pwr_ctrl_out};

	    // GPIO Control (bit bang and automatic)
	    8'h5e : fdata = {2'b00, serial_data_2, serial_data_1, serial_bb_clock,
				serial_bb_resetn, serial_bb_enable, serial_xfer};

	    /* Clocking control */
	    8'h5f : fdata = {6'b000000, pll_dco_ena, pll_ena};
	    8'h60 : fdata = {7'b0000000, pll_bypass};
	    8'h61 : fdata = {7'b0000000, irq_spi};
	    8'h62 : fdata = {7'b0000000, reset};
	    8'h63 : fdata = {6'b000000, pll_trim[25:24]};
	    8'h64 : fdata = pll_trim[23:16];
	    8'h65 : fdata = pll_trim[15:8];
	    8'h66 : fdata = pll_trim[7:0];
	    8'h67 : fdata = {2'b00, pll90_sel, pll_sel};
	    8'h68 : fdata = {3'b000, pll_div};

	    default: fdata = 8'h00;
	endcase
	end
    endfunction

    /* Memory map address to SPI address translation for back door access */
    /* (see doc/memory_map.txt)						  */

    function [7:0] spiaddr(input [31:0] wbaddress);
	begin
	case ({wbaddress[27], wbaddress[24], wbaddress[7:0]})
	    10'h300 : spiaddr = 8'h09;
	    10'h304 : spiaddr = 8'h0a;
	    10'h304 : spiaddr = 8'h0b;
	    10'h025 : spiaddr = 8'h0c;
	    10'h024 : spiaddr = 8'h0d;
	    10'h029 : spiaddr = 8'h0e;
	    10'h028 : spiaddr = 8'h0f;
	    10'h02d : spiaddr = 8'h10;
	    10'h02c : spiaddr = 8'h11;
	    10'h031 : spiaddr = 8'h12;
	    10'h030 : spiaddr = 8'h13;
	    10'h035 : spiaddr = 8'h14;
	    10'h034 : spiaddr = 8'h15;
	    10'h039 : spiaddr = 8'h16;
	    10'h038 : spiaddr = 8'h17;
	    10'h03d : spiaddr = 8'h18;
	    10'h03c : spiaddr = 8'h19;
	    10'h041 : spiaddr = 8'h1a;
	    10'h040 : spiaddr = 8'h1b;
	    10'h045 : spiaddr = 8'h1c;
	    10'h044 : spiaddr = 8'h1d;
	    10'h049 : spiaddr = 8'h1e;
	    10'h048 : spiaddr = 8'h1f;
	    10'h04d : spiaddr = 8'h20;
	    10'h04c : spiaddr = 8'h21;
	    10'h051 : spiaddr = 8'h22;
	    10'h050 : spiaddr = 8'h23;
	    10'h055 : spiaddr = 8'h24;
	    10'h054 : spiaddr = 8'h25;
	    10'h059 : spiaddr = 8'h26;
	    10'h058 : spiaddr = 8'h27;
	    10'h05d : spiaddr = 8'h28;
	    10'h05c : spiaddr = 8'h29;
	    10'h061 : spiaddr = 8'h2a;
	    10'h060 : spiaddr = 8'h2b;
	    10'h065 : spiaddr = 8'h2c;
	    10'h064 : spiaddr = 8'h2d;
	    10'h069 : spiaddr = 8'h2e;
	    10'h068 : spiaddr = 8'h2f;
	    10'h06d : spiaddr = 8'h30;
	    10'h06c : spiaddr = 8'h31;
	    10'h071 : spiaddr = 8'h32;
	    10'h070 : spiaddr = 8'h33;
	    10'h075 : spiaddr = 8'h34;
	    10'h074 : spiaddr = 8'h35;
	    10'h079 : spiaddr = 8'h36;
	    10'h078 : spiaddr = 8'h37;
	    10'h07d : spiaddr = 8'h38;
	    10'h07c : spiaddr = 8'h39;
	    10'h081 : spiaddr = 8'h3a;
	    10'h080 : spiaddr = 8'h3b;
	    10'h085 : spiaddr = 8'h3c;
	    10'h084 : spiaddr = 8'h3d;
	    10'h089 : spiaddr = 8'h3e;
	    10'h088 : spiaddr = 8'h3f;
	    10'h08d : spiaddr = 8'h40;
	    10'h08c : spiaddr = 8'h41;
	    10'h091 : spiaddr = 8'h42;
	    10'h090 : spiaddr = 8'h43;
	    10'h095 : spiaddr = 8'h44;
	    10'h094 : spiaddr = 8'h45;
	    10'h099 : spiaddr = 8'h46;
	    10'h098 : spiaddr = 8'h47;
	    10'h09d : spiaddr = 8'h48;
	    10'h09c : spiaddr = 8'h49;
	    10'h0a1 : spiaddr = 8'h4a;
	    10'h0a0 : spiaddr = 8'h4b;
	    10'h0a5 : spiaddr = 8'h4c;
	    10'h0a4 : spiaddr = 8'h4d;
	    10'h0a9 : spiaddr = 8'h4e;
	    10'h0a8 : spiaddr = 8'h4f;
	    10'h0ad : spiaddr = 8'h50;
	    10'h0ac : spiaddr = 8'h51;
	    10'h0b1 : spiaddr = 8'h52;
	    10'h0b0 : spiaddr = 8'h53;
	    10'h0b5 : spiaddr = 8'h54;
	    10'h0b4 : spiaddr = 8'h55;
	    10'h0b9 : spiaddr = 8'h56;
	    10'h0b8 : spiaddr = 8'h57;
	    10'h010 : spiaddr = 8'h58;
	    10'h00f : spiaddr = 8'h59;
	    10'h00e : spiaddr = 8'h5a;
	    10'h00d : spiaddr = 8'h5b;
	    10'h00c : spiaddr = 8'h5c;
	    10'h000 : spiaddr = 8'h5e;
	    10'h004 : spiaddr = 8'h5d;
	    10'h00c : spiaddr = 8'h5c;
	    10'h00d : spiaddr = 8'h5b;
	    10'h00e : spiaddr = 8'h5a;
	    10'h00f : spiaddr = 8'h59;
	    10'h010 : spiaddr = 8'h58;
	    10'h20c : spiaddr = 8'h5f;
	    10'h210 : spiaddr = 8'h60;
	    10'h214 : spiaddr = 8'h61;
	    10'h218 : spiaddr = 8'h62;
	    10'h21f : spiaddr = 8'h63;
	    10'h21e : spiaddr = 8'h64;
	    10'h21d : spiaddr = 8'h65;
	    10'h21c : spiaddr = 8'h66;
	    10'h220 : spiaddr = 8'h67;
	    10'h224 : spiaddr = 8'h68;
	    default : spiaddr = 8'h00;
	endcase
	end
    endfunction

    /* Wishbone back-door state machine and address translation */

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
	if (wb_rst_i) begin
	    wbbd_sck <= 1'b0;
	    wbbd_write <= 1'b0;
	    wbbd_addr <= 8'd0;
	    wbbd_data <= 8'd0;
	    wb_ack_o <= 1'b0;
	end else begin
	    case (wbbd_state)
		`WBD_IDLE: begin
	    	    if ((|wb_sel_i) && wb_cyc_i &&
				(sys_select | gpio_select | spi_select)) begin
			wb_ack_o <= 1'b1;
			wbbd_state <= `WBD_SETUP0;
		    end
		end
		`WBD_SETUP0: begin
		    wbbd_sck <= 1'b0;
		    if (sys_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0]);
		    end else if (gpio_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0]);
		    end else if (spi_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0]);
		    end
		    if (wb_sel_i[0] & wb_we_i) begin
		    	wbbd_data <= wb_dat_i[7:0];
		    end
		    wbbd_write <= wb_sel_i[0] & wb_we_i;
		    wbbd_state <= `WBD_RW0;
		end
		`WBD_RW0: begin
		    wbbd_sck <= 1'b1;
		    wb_dat_o[7:0] <= odata;
		    wbbd_state <= `WBD_SETUP1;
		end
		`WBD_SETUP1: begin
		    wbbd_sck <= 1'b0;
		    if (sys_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 1);
		    end else if (gpio_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 1);
		    end else if (spi_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 1);
		    end
		    if (wb_sel_i[1] & wb_we_i) begin
		    	wbbd_data <= wb_dat_i[15:8];
		    end
		    wbbd_write <= wb_sel_i[1] & wb_we_i;
		    wbbd_state <= `WBD_RW1;
		end
		`WBD_RW1: begin
		    wbbd_sck <= 1'b1;
		    wb_dat_o[15:8] <= odata;
		    wbbd_state <= `WBD_SETUP2;
		end
		`WBD_SETUP2: begin
		    wbbd_sck <= 1'b0;
		    if (sys_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 2);
		    end else if (gpio_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 2);
		    end else if (spi_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 2);
		    end
		    if (wb_sel_i[2] & wb_we_i) begin
		    	wbbd_data <= wb_dat_i[23:16];
		    end
		    wbbd_write <= wb_sel_i[2] & wb_we_i;
		    wbbd_state <= `WBD_RW2;
		end
		`WBD_RW2: begin
		    wbbd_sck <= 1'b1;
		    wb_dat_o[23:16] <= odata;
		    wbbd_state <= `WBD_SETUP3;
		end
		`WBD_SETUP3: begin
		    wbbd_sck <= 1'b0;
		    if (sys_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 3);
		    end else if (gpio_select) begin
		    	wbbd_addr <= spiaddr(wb_adr_i[7:0] + 3);
		    end else if (spi_select) begin
		        wbbd_addr <= spiaddr(wb_adr_i[7:0] + 3);
		    end
		    if (wb_sel_i[3] & wb_we_i) begin
		    	wbbd_data <= wb_dat_i[31:24];
		    end
		    wbbd_write <= wb_sel_i[3] & wb_we_i;
		    wbbd_state <= `WBD_RW3;
		end
		`WBD_RW3: begin
		    wbbd_sck <= 1'b1;
		    wb_dat_o[31:24] <= odata;
		    wbbd_state <= `WBD_DONE;
		end
		`WBD_DONE: begin
		    wbbd_sck <= 1'b0;
		    wb_ack_o <= 1'b0;	// Release hold on wishbone bus
		    wbbd_state <= `WBD_IDLE;
		end
	    endcase
	end
    end

    // Instantiate the SPI interface protocol module

    housekeeping_spi hkspi (
	.reset(~porb),
    	.SCK(mgmt_gpio_in[4]),
    	.SDI(mgmt_gpio_in[2]),
    	.CSB(mgmt_gpio_in[3]),
    	.SDO(sdo),
    	.sdoenb(sdo_enb),
    	.idata(odata),
    	.odata(idata),
    	.oaddr(iaddr),
    	.rdstb(rdstb),
    	.wrstb(wrstb),
    	.pass_thru_mgmt(pass_thru_mgmt),
    	.pass_thru_mgmt_delay(pass_thru_mgmt_delay),
    	.pass_thru_user(pass_thru_user),
    	.pass_thru_user_delay(pass_thru_user_delay),
    	.pass_thru_mgmt_reset(pass_thru_mgmt_reset),
    	.pass_thru_user_reset(pass_thru_user_reset)
    );

    // SPI is considered active when the GPIO for CSB is set to input and
    // CSB is low.
    wire spi_is_enabled = ~gpio_configure[3][INP_DIS];
    wire spi_is_active = spi_is_enabled && (mgmt_gpio_in[3] == 1'b0);

    // GPIO data handling to and from the management SoC

    assign mgmt_gpio_out_pre[37] = (qspi_enabled) ? spimemio_flash_io3_do :
		mgmt_gpio_data[37];
    assign mgmt_gpio_out_pre[36] = (qspi_enabled) ? spimemio_flash_io2_do :
		mgmt_gpio_data[36];

    assign mgmt_gpio_oeb[37] = (qspi_enabled) ? spimemio_flash_io3_oeb :
		~gpio_configure[37][INP_DIS];
    assign mgmt_gpio_oeb[36] = (qspi_enabled) ? spimemio_flash_io2_oeb :
		~gpio_configure[36][INP_DIS];

    assign mgmt_gpio_out_pre[35:16] = mgmt_gpio_data[35:16];
    assign mgmt_gpio_out_pre[12:11] = mgmt_gpio_data[12:11];

    assign mgmt_gpio_out_pre[10] = (pass_thru_user) ? mgmt_gpio_in[2]
			: mgmt_gpio_data[10];
    assign mgmt_gpio_out_pre[9] = (pass_thru_user) ? mgmt_gpio_in[4]
			: mgmt_gpio_data[9];
    assign mgmt_gpio_out_pre[8] = (pass_thru_user) ? mgmt_gpio_in[3]
			: mgmt_gpio_data[8];

    assign mgmt_gpio_out_pre[7] = mgmt_gpio_data[7];
    assign mgmt_gpio_out_pre[6] = (uart_enabled) ? ser_tx : mgmt_gpio_data[6];
    assign mgmt_gpio_out_pre[5] = mgmt_gpio_data[5];

    assign mgmt_gpio_out_pre[4] = (spi_enabled) ? spi_sck : mgmt_gpio_data[4];
    assign mgmt_gpio_out_pre[3] = (spi_enabled) ? spi_csb : mgmt_gpio_data[3];
    assign mgmt_gpio_out_pre[2] = (spi_enabled) ? spi_sdo : mgmt_gpio_data[2];

    // In pass-through modes, route SDO from the respective flash (user or
    // management SoC) to the dedicated SDO pin (GPIO[1])

    assign mgmt_gpio_out_pre[1] = (pass_thru_mgmt) ? pad_flash_io1_di :
		 (pass_thru_user) ? mgmt_gpio_in[11] : sdo;
    assign mgmt_gpio_out_pre[0] = (debug_mode) ? debug_out : mgmt_gpio_data[0];

    assign mgmt_gpio_oeb[1] = (spi_enabled) ? 1'b1 : sdo_enb;
    assign mgmt_gpio_oeb[0] = (debug_mode) ? debug_oeb : ~gpio_configure[0][INP_DIS];

    assign ser_rx = (uart_enabled) ? mgmt_gpio_in[5] : 1'b0;
    assign spi_sdi = (spi_enabled) ? mgmt_gpio_in[1] : 1'b0;
    assign debug_in = (debug_mode) ? mgmt_gpio_in[0] : 1'b0;

    /* These are disconnected, but apply a meaningful signal anyway */
    generate
	for (i = 2; i < `MPRJ_IO_PADS-2; i = i + 1) begin
	    assign mgmt_gpio_oeb[i] = ~gpio_configure[i][INP_DIS];
	end
    endgenerate

    // System monitoring.  Multiplex the clock and trap
    // signals to the associated pad, and multiplex the irq signals
    // from the associated pad, when the redirection is enabled.  Note
    // that the redirection is upstream of the user/managment multiplexing,
    // so the pad being under control of the user area takes precedence
    // over the system monitoring function.

    assign mgmt_gpio_out_pre[15] = (clk2_output_dest == 1'b1) ? user_clock
		: mgmt_gpio_data[15];
    assign mgmt_gpio_out_pre[14] = (clk1_output_dest == 1'b1) ? wb_clk_i
		: mgmt_gpio_data[14];
    assign mgmt_gpio_out_pre[13] = (trap_output_dest == 1'b1) ? trap
		: mgmt_gpio_data[13];

    assign irq[0] = irq_spi;
    assign irq[1] = (irq_1_inputsrc == 1'b1) ? mgmt_gpio_in[7] : 1'b0;
    assign irq[2] = (irq_2_inputsrc == 1'b1) ? mgmt_gpio_in[12] : 1'b0;

    // GPIO serial loader and GPIO management control

`define GPIO_IDLE	2'b00
`define GPIO_START	2'b01
`define GPIO_XBYTE	2'b10
`define GPIO_LOAD	2'b11

    reg [3:0]	xfer_count;
    reg [4:0]	pad_count_1;
    reg [4:0]	pad_count_2;
    reg [1:0]	xfer_state;

    reg serial_clock;
    reg serial_resetn;
    wire serial_data_1;
    wire serial_data_2;
    reg [IO_CTRL_BITS-1:0] serial_data_staging_1;
    reg [IO_CTRL_BITS-1:0] serial_data_staging_2;

    assign serial_data_1 = serial_data_staging_1[IO_CTRL_BITS-1];
    assign serial_data_2 = serial_data_staging_2[IO_CTRL_BITS-1];

    always @(posedge wb_clk_i or negedge porb) begin
	if (porb == 1'b0) begin
	    xfer_state <= `GPIO_IDLE;
	    xfer_count <= 4'd0;
            /* NOTE:  This assumes that MPRJ_IO_PADS_1 and MPRJ_IO_PADS_2 are
             * equal, because they get clocked the same number of cycles by
             * the same clock signal.  pad_count_2 gates the count for both.
             */
	    pad_count_1 <= `MPRJ_IO_PADS_1 - 1;
	    pad_count_2 <= `MPRJ_IO_PADS_1;
	    serial_resetn <= 1'b0;
	    serial_clock <= 1'b0;
	    serial_data_staging_1 <= 0;
	    serial_data_staging_2 <= 0;

	end else begin

	    case (xfer_state)
		`GPIO_IDLE: begin
		    pad_count_1 <= `MPRJ_IO_PADS_1 - 1;
                    pad_count_2 <= `MPRJ_IO_PADS_1;
                    serial_resetn <= 1'b1;
                    serial_clock <= 1'b0;
                    if (serial_xfer == 1'b1) begin
                        xfer_state <= `GPIO_START;
                    end
		end
		`GPIO_START: begin
                    serial_resetn <= 1'b1;
                    serial_clock <= 1'b0;
                    xfer_count <= 6'd0;
                    pad_count_1 <= pad_count_1 - 1;
                    pad_count_2 <= pad_count_2 + 1;
                    xfer_state <= `GPIO_XBYTE;
                    serial_data_staging_1 <= gpio_configure[pad_count_1];
                    serial_data_staging_2 <= gpio_configure[pad_count_2];
		end
		`GPIO_XBYTE: begin
                    serial_resetn <= 1'b1;
                    serial_clock <= ~serial_clock;
                    if (serial_clock == 1'b0) begin
                        if (xfer_count == IO_CTRL_BITS - 1) begin
                            if (pad_count_2 == `MPRJ_IO_PADS) begin
                                xfer_state <= `GPIO_LOAD;
                            end else begin
                                xfer_state <= `GPIO_START;
                            end
                        end else begin
                            xfer_count <= xfer_count + 1;
                        end
                    end else begin
                        serial_data_staging_1 <=
				{serial_data_staging_1[IO_CTRL_BITS-2:0], 1'b0};
                        serial_data_staging_2 <=
				{serial_data_staging_2[IO_CTRL_BITS-2:0], 1'b0};
                    end
		end
		`GPIO_LOAD: begin
                    xfer_count <= xfer_count + 1;

                    /* Load sequence:  Raise clock for final data shift in;
                     * Pulse reset low while clock is high
                     * Set clock back to zero.
                     * Return to idle mode.
                     */
                    if (xfer_count == 4'd0) begin
                        serial_clock <= 1'b1;
                        serial_resetn <= 1'b1;
                    end else if (xfer_count == 4'd1) begin
                        serial_clock <= 1'b1;
                        serial_resetn <= 1'b0;
                    end else if (xfer_count == 4'd2) begin
                        serial_clock <= 1'b1;
                        serial_resetn <= 1'b1;
                    end else if (xfer_count == 4'd3) begin
                        serial_resetn <= 1'b1;
                        serial_clock <= 1'b0;
                        xfer_state <= `GPIO_IDLE;
		    end
                end
            endcase
	end
    end

    // SPI Identification

    wire [11:0] mfgr_id;
    wire [7:0]  prod_id;
    wire [31:0] mask_rev;

    assign mfgr_id = 12'h456;		// Hard-coded
    assign prod_id = 8'h11;		// Hard-coded
    assign mask_rev = mask_rev_in;	// Copy in to out.

    // SPI Data transfer protocol.  The wishbone back door may only be
    // used if the front door is closed (CSB is high or the CSB pin is
    // not an input).  To do:  Provide an independent way to disable
    // the SPI.

    assign caddr = (spi_is_active) ? iaddr : wbbd_addr;
    assign csclk = (spi_is_active) ? mgmt_gpio_in[4] : wbbd_sck;
    assign cdata = (spi_is_active) ? idata : wbbd_data;
    assign cwstb = (spi_is_active) ? wrstb : wbbd_write;
    assign odata = fdata(caddr);

    // Register mapping and I/O to SPI interface module

    integer j;

    always @(posedge csclk or negedge porb) begin
    if (porb == 1'b0) begin
        // Set trim for PLL at (almost) slowest rate (~90MHz).  However,
        // pll_trim[12] must be set to zero for proper startup.
        pll_trim <= 26'b11111111111110111111111111;
        pll_sel <= 3'b010;	// Default output divider divide-by-2
        pll90_sel <= 3'b010;	// Default secondary output divider divide-by-2
        pll_div <= 5'b00100;	// Default feedback divider divide-by-8
        pll_dco_ena <= 1'b1;	// Default free-running PLL
        pll_ena <= 1'b0;	// Default PLL turned off
        pll_bypass <= 1'b1;	// Default bypass mode (don't use PLL)
        irq_spi <= 1'b0;
        reset_reg <= 1'b0;

	// System monitoring signals
	clk1_output_dest <= 1'b0;
	clk2_output_dest <= 1'b0;
	trap_output_dest <= 1'b0;
	irq_1_inputsrc <= 1'b0;
	irq_2_inputsrc <= 1'b0;

	// GPIO Configuration, Data, and Control
	for (j = 0; j < `MPRJ_IO_PADS; j=j+1) begin
	    gpio_configure[j] <= 13'd0;
	end
	mgmt_gpio_data <= 'd0;
	serial_bb_enable <= 1'b0;
	serial_bb_data_1 <= 1'b0;
	serial_bb_data_2 <= 1'b0;
	serial_bb_clock <= 1'b0;
	serial_bb_resetn <= 1'b0;
	serial_xfer <= 1'b0;

    end else if (cwstb == 1'b1) begin
        case (caddr)
	    /* Register 8'h00 is reserved for future use */
	    /* Registers 8'h01 to 8'h09 are read-only and cannot be written */
            8'h0a: begin
		clk1_output_dest <= cdata[2];
		clk2_output_dest <= cdata[1];
		trap_output_dest <= cdata[0];
	    end
            8'h0b: begin
		irq_2_inputsrc <= cdata[1];
		irq_1_inputsrc <= cdata[0];
	    end
            8'h0c: begin
		gpio_configure[0][12:8] <= cdata[4:0];
	    end
            8'h0d: begin
		gpio_configure[0][7:0] <= cdata;
	    end
            8'h0e: begin
		gpio_configure[1][12:8] <= cdata[4:0];
	    end
            8'h0f: begin
		gpio_configure[1][7:0] <= cdata;
	    end
            8'h10: begin
		gpio_configure[2][12:8] <= cdata[4:0];
	    end
            8'h11: begin
		gpio_configure[2][7:0] <= cdata;
	    end
            8'h12: begin
		gpio_configure[3][12:8] <= cdata[4:0];
	    end
            8'h13: begin
		gpio_configure[3][7:0] <= cdata;
	    end
            8'h14: begin
		gpio_configure[4][12:8] <= cdata[4:0];
	    end
            8'h15: begin
		gpio_configure[4][7:0] <= cdata;
	    end
            8'h16: begin
		gpio_configure[5][12:8] <= cdata[4:0];
	    end
            8'h17: begin
		gpio_configure[5][7:0] <= cdata;
	    end
            8'h18: begin
		gpio_configure[6][12:8] <= cdata[4:0];
	    end
            8'h19: begin
		gpio_configure[6][7:0] <= cdata;
	    end
            8'h1a: begin
		gpio_configure[7][12:8] <= cdata[4:0];
	    end
            8'h1b: begin
		gpio_configure[7][7:0] <= cdata;
	    end
            8'h1c: begin
		gpio_configure[8][12:8] <= cdata[4:0];
	    end
            8'h1d: begin
		gpio_configure[8][7:0] <= cdata;
	    end
            8'h1e: begin
		gpio_configure[9][12:8] <= cdata[4:0];
	    end
            8'h1f: begin
		gpio_configure[9][7:0] <= cdata;
	    end
            8'h20: begin
		gpio_configure[10][12:8] <= cdata[4:0];
	    end
            8'h21: begin
		gpio_configure[10][7:0] <= cdata;
	    end
            8'h22: begin
		gpio_configure[11][12:8] <= cdata[4:0];
	    end
            8'h23: begin
		gpio_configure[11][7:0] <= cdata;
	    end
            8'h24: begin
		gpio_configure[12][12:8] <= cdata[4:0];
	    end
            8'h25: begin
		gpio_configure[12][7:0] <= cdata;
	    end
            8'h26: begin
		gpio_configure[13][12:8] <= cdata[4:0];
	    end
            8'h27: begin
		gpio_configure[13][7:0] <= cdata;
	    end
            8'h28: begin
		gpio_configure[14][12:8] <= cdata[4:0];
	    end
            8'h29: begin
		gpio_configure[14][7:0] <= cdata;
	    end
            8'h2a: begin
		gpio_configure[15][12:8] <= cdata[4:0];
	    end
            8'h2b: begin
		gpio_configure[15][7:0] <= cdata;
	    end
            8'h2c: begin
		gpio_configure[16][12:8] <= cdata[4:0];
	    end
            8'h2d: begin
		gpio_configure[16][7:0] <= cdata;
	    end
            8'h2e: begin
		gpio_configure[17][12:8] <= cdata[4:0];
	    end
            8'h2f: begin
		gpio_configure[17][7:0] <= cdata;
	    end
            8'h30: begin
		gpio_configure[18][12:8] <= cdata[4:0];
	    end
            8'h31: begin
		gpio_configure[18][7:0] <= cdata;
	    end
            8'h32: begin
		gpio_configure[19][12:8] <= cdata[4:0];
	    end
            8'h33: begin
		gpio_configure[19][7:0] <= cdata;
	    end
            8'h34: begin
		gpio_configure[20][12:8] <= cdata[4:0];
	    end
            8'h35: begin
		gpio_configure[20][7:0] <= cdata;
	    end
            8'h36: begin
		gpio_configure[21][12:8] <= cdata[4:0];
	    end
            8'h37: begin
		gpio_configure[21][7:0] <= cdata;
	    end
            8'h38: begin
		gpio_configure[22][12:8] <= cdata[4:0];
	    end
            8'h39: begin
		gpio_configure[22][7:0] <= cdata;
	    end
            8'h3a: begin
		gpio_configure[23][12:8] <= cdata[4:0];
	    end
            8'h3b: begin
		gpio_configure[23][7:0] <= cdata;
	    end
            8'h3c: begin
		gpio_configure[24][12:8] <= cdata[4:0];
	    end
            8'h3d: begin
		gpio_configure[24][7:0] <= cdata;
	    end
            8'h3e: begin
		gpio_configure[25][12:8] <= cdata[4:0];
	    end
            8'h3f: begin
		gpio_configure[25][7:0] <= cdata;
	    end
            8'h40: begin
		gpio_configure[26][12:8] <= cdata[4:0];
	    end
            8'h41: begin
		gpio_configure[26][7:0] <= cdata;
	    end
            8'h42: begin
		gpio_configure[27][12:8] <= cdata[4:0];
	    end
            8'h43: begin
		gpio_configure[27][7:0] <= cdata;
	    end
            8'h44: begin
		gpio_configure[28][12:8] <= cdata[4:0];
	    end
            8'h45: begin
		gpio_configure[28][7:0] <= idata;
	    end
            8'h46: begin
		gpio_configure[29][12:8] <= cdata[4:0];
	    end
            8'h47: begin
		gpio_configure[29][7:0] <= cdata;
	    end
            8'h48: begin
		gpio_configure[30][12:8] <= cdata[4:0];
	    end
            8'h49: begin
		gpio_configure[30][7:0] <= cdata;
	    end
            8'h4a: begin
		gpio_configure[31][12:8] <= cdata[4:0];
	    end
            8'h4b: begin
		gpio_configure[31][7:0] <= cdata;
	    end
            8'h4c: begin
		gpio_configure[32][12:8] <= cdata[4:0];
	    end
            8'h4d: begin
		gpio_configure[32][7:0] <= cdata;
	    end
            8'h4e: begin
		gpio_configure[33][12:8] <= cdata[4:0];
	    end
            8'h4f: begin
		gpio_configure[33][7:0] <= cdata;
	    end
            8'h50: begin
		gpio_configure[34][12:8] <= cdata[4:0];
	    end
            8'h51: begin
		gpio_configure[34][7:0] <= cdata;
	    end
            8'h52: begin
		gpio_configure[35][12:8] <= cdata[4:0];
	    end
            8'h53: begin
		gpio_configure[35][7:0] <= cdata;
	    end
            8'h54: begin
		gpio_configure[36][12:8] <= cdata[4:0];
	    end
            8'h55: begin
		gpio_configure[36][7:0] <= cdata;
	    end
            8'h56: begin
		gpio_configure[37][12:8] <= cdata[4:0];
	    end
            8'h57: begin
		gpio_configure[37][7:0] <= cdata;
	    end
	    8'h58: begin
		mgmt_gpio_data[37:32] <= cdata[5:0];
	    end
	    8'h59: begin
		mgmt_gpio_data[31:24] <= cdata;
	    end
	    8'h5a: begin
		mgmt_gpio_data[23:16] <= cdata;
	    end
	    8'h5b: begin
		mgmt_gpio_data[15:8] <= cdata;
	    end
	    8'h5c: begin
		mgmt_gpio_data[7:0] <= cdata;
	    end
	    8'h5d: begin
		pwr_ctrl_out <= cdata[3:0];
	    end
	    8'h5e: begin
		serial_bb_data_2 <= cdata[5];
		serial_bb_data_1 <= cdata[4];
		serial_bb_clock <= cdata[3];
		serial_bb_resetn <= cdata[2];
		serial_bb_enable <= cdata[1];
		serial_xfer <= cdata[0];
	    end
            8'h5f: begin
                pll_ena <= cdata[0];
                pll_dco_ena <= cdata[1];
            end
            8'h60: begin
                pll_bypass <= cdata[0];
            end
            8'h61: begin
                irq_spi <= cdata[0];
            end
            8'h62: begin
                reset_reg <= cdata[0];
            end
            8'h63: begin
                pll_trim[25:24] <= cdata[1:0];
            end
            8'h64: begin
                pll_trim[23:16] <= cdata;
            end
            8'h65: begin
                pll_trim[15:8] <= cdata;
            end
            8'h66: begin
                pll_trim[7:0] <= cdata;
            end
            8'h67: begin
                pll90_sel <= cdata[5:3];
                pll_sel <= cdata[2:0];
            end
            8'h68: begin
                pll_div <= cdata[4:0];
            end
        endcase	// (caddr)
    end else begin
	serial_xfer <= 1'b0;	// Serial transfer is self-resetting
	irq_spi <= 1'b0;	// IRQ is self-resetting
    end
    end
endmodule	// housekeeping

`default_nettype wire
