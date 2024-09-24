//======================================================================== 
// openCologne * NLnet-sponsored open-source design ware for GateMate
//------------------------------------------------------------------------
//                   Copyright (C) 2024 Chili.CHIPS*ba
// 
// Redistribution and use in source and binary forms, with or without 
// modification, are permitted provided that the following conditions 
// are met:
//
// 1. Redistributions of source code must retain the above copyright 
// notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright 
// notice, this list of conditions and the following disclaimer in the 
// documentation and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its 
// contributors may be used to endorse or promote products derived
// from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS 
// IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED 
// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
// PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT 
// HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//              https://opensource.org/license/bsd-3-clause
//------------------------------------------------------------------------
// Description: 
//   Minimal UART, with all serial parameters fixed in hardware:
//     - 115.2kbps (i.e. one bit period is 8.68usec)
//     - 8 Data bits
//     - 1 Stop bit
//     - 0 Parity
//
//   It is designed for the minimal expenditure in hardware resources.
//   It therefore does not have Rx/Tx FIFOs, but only single-byte buffer
//   in each direction. Handshake with SW is based on 'tx.busy' and
//   'rx.valid+overflow' flags:
//     - New Tx data is accepted from SW only when 'tx.busy=0'
//     - New Rx data is loaded into holding register only when 'rx.valid=0'.
//       Otherwise, 'rx.overflow' is raised
//
//   Both Rx flags are Clear-on-Read -- Zero value on them tells HW that
//   SW has got the posted value. See 'csr_pkg.sv for additional detail.
//========================================================================

module uart
   import csr_pkg::*;
(
   input  logic    arst_n,
   input  logic    clk,
   input  logic    tick_02us,
                    
   input  logic    uart_rx,
   output logic    uart_tx,
                  
   input  logic uart_tx_write,
   input  logic [7:0] uart_tx_data,
   input  logic uart_rx_read,

   output logic uart_tx_busy,
   output uart_rx_t uart_rx_arr
   //csr_if.SLV_UART csr

 // IMEM Write port, for live updates of CPU program
/*    output logic        imem_we,
   output logic [31:2] imem_waddr,
   output logic [31:0] imem_wdat */
);

//--------------------------------------
// Common
//--------------------------------------

   typedef enum logic[3:0] {
      IDLE  = 4'd14,

      START = 4'd15, // skipped altogether in RxFSM

      D0    = 4'd0,  // LSB first
      D1    = 4'd1,  //  | 
      D2    = 4'd2,  //  | 
      D3    = 4'd3,  //  | 
      D4    = 4'd4,  //  | 
      D5    = 4'd5,  //  | 
      D6    = 4'd6,  //  V 
      D7    = 4'd7,  // MSB last
                      
      STOP  = 4'd8   // only one Stop bit

      // Zero Parity bit
   } state_t;


   typedef logic [7:0] cnt02us_t;

   
//--------------------------------------
// Rx
//--------------------------------------
// To save resources, SOC-level 1us tick is used as time base for
// Rx sampling. Since one bit period is 8.68us, upon detecting START,
// the FSM first waits 9+4=13us to skip the START bit and get close to 
// the middle of D0, where it samples it. It then waits 8us or 9us for 
// subsequent data bits. This keep the sampling sufficiently centered, 
// despite 'tick_1us' being completely asynchronous to incoming data:
//
// - START+D0center=8.68us+4.34us=13.02us is the ideal D0 sampling point.
//   Given that 'tick_02us' is async to START, actual D0 sampling can fall
//   anywhere in (13..13.2)us window. Max D0 sampling error is thus +0.18us
//
// - D1 ideal sampling is (2*8.68)+4.34=21.70us
//   Actual is (13..13.2)+8.6=(21.6..21.8)us: Max error: +-0.1us
//
// - D2 ideal sampling is (3*8.68)+4.34=30.38us
//   Actual is (21.6..21.8)+8.6=(30.2..30.4)us: Max error: -0.18us
//
// - D3 ideal sampling is (4*8.68)+4.34=39.06us
//   Actual is (30.2..30.4)+8.8=(39..39.2)us: Max error: +0.14us
//
// - D4 ideal sampling is (5*8.68)+4.34=47.74us
//   Actual is (39..39.2)+8.6=(47.6..47.8)us: Max error: -0.14us
//
// - D5 ideal sampling is (6*8.68)+4.34=56.42us
//   Actual is (47.6..47.8)+8.8=(56.4..56.6)us: Max error: +0.18us
//
// - D6 ideal sampling is (7*8.68)+4.34=65.10us
//   Actual is (56.4..56.6)+8.6=(65..65.2)us: Max error: +-0.1us
//
// - D7 ideal sampling is (8*8.68)+4.34=73.78us
//   Actual is (65..65.2)+8.6=(73.6..73.8)us: Max error: -0.18us
//
// - STOP ideal sampling is (9*8.68)+4.34=82.46us
//   Actual is (73.6..73.8)+8.8=(82.4..82.6)us: Max error: +0.14us
//
// In other words, sampling error is within +/-0.18us from the center
// of +/-4.34us window, thus leaving more than sufficient margin 
// for reliable data reception.
//--------------------------------------

//    localparam bit[3:0] RX_WAIT_D0   = 4'd13; //=14 ticks: From 13 to 0
//    localparam bit[3:0] RX_WAIT_D1   = 4'd7;
//    localparam bit[3:0] RX_WAIT_D2   = 4'd8;
//    localparam bit[3:0] RX_WAIT_D3   = 4'd8;
//    localparam bit[3:0] RX_WAIT_D4   = 4'd7;
//    localparam bit[3:0] RX_WAIT_D5   = 4'd8;
//    localparam bit[3:0] RX_WAIT_D6   = 4'd8;
//    localparam bit[3:0] RX_WAIT_D7   = 4'd7;
//    localparam bit[3:0] RX_WAIT_STOP = 4'd8;

   localparam bit[7:0] RX_WAIT_D0   = 8'd64; //=65 ticks: From 64 to 0 - 13us
   localparam bit[7:0] RX_WAIT_D1   = 8'd42; // 8.6
   localparam bit[7:0] RX_WAIT_D2   = 8'd42;
   localparam bit[7:0] RX_WAIT_D3   = 8'd43; // 8.8
   localparam bit[7:0] RX_WAIT_D4   = 8'd42;
   localparam bit[7:0] RX_WAIT_D5   = 8'd43;
   localparam bit[7:0] RX_WAIT_D6   = 8'd42;
   localparam bit[7:0] RX_WAIT_D7   = 8'd42;
   localparam bit[7:0] RX_WAIT_STOP = 8'd43;
   
   state_t  rx_state;
   cnt02us_t rx_cnt02us; // counts 1us ticks
   logic    rx_cnt02us_is0;
   assign   rx_cnt02us_is0 = (rx_cnt02us == '0);

   logic    rx_nextbit;
   assign   rx_nextbit = tick_02us & rx_cnt02us_is0;

   logic [7:0] rx_shift;

   always_ff @(negedge arst_n or posedge clk) begin
      if (arst_n == 1'b0) begin
         rx_state          <= IDLE;
         rx_cnt02us         <= '0;
         rx_shift          <= '0;

         uart_rx_arr.valid <= 1'b0;
         uart_rx_arr.oflow <= 1'b0;
         uart_rx_arr.data  <= '0;
      end 
      else begin

        // when not in IDLE, count 1us ticks
         if ((tick_02us == 1'b1) && (rx_state != IDLE)) begin
            rx_cnt02us <= cnt02us_t'(rx_cnt02us - cnt02us_t'(1));
         end

        // SW Clear-on-Read is async to UART traffic 
        //  and with lower priority to HW Set
         if (uart_rx_read == 1'b1) begin
            uart_rx_arr.valid <= 1'b0;
            uart_rx_arr.oflow <= 1'b0;
         end

        // FSM runs on main clock, with most states gated by 'rx_cnt02us_is0'
         unique case (rx_state)

           //---Wait for 'uart_rx' negedge to start reception
            IDLE: begin
               rx_cnt02us <= RX_WAIT_D0;

               if (uart_rx == 1'b0) begin
                  rx_state <= D0;
               end
            end

            //---New Rx data is collected:
            // - if SW has already taken previous data, present the new data
            // - otherwise, report overflow. New data is dropped in such case
            STOP: if (rx_nextbit == 1'b1) begin

               if (uart_rx_arr.valid == 1'b1) begin
                  uart_rx_arr.oflow <= 1'b1;
               end
               else begin
                  uart_rx_arr.valid <= 1'b1;
                  uart_rx_arr.data  <= rx_shift;
               end

               rx_state <= IDLE;

            `ifdef UART_DEBUG
               $display("%t %m RX'd %0h (%s)", $time, rx_shift, string'(rx_shift));
            `endif 
            end

           //---Wait the prescribed amount of time to position sampling
           //   point to Rx bit center, then capture DATA bits
            default: if (rx_nextbit == 1'b1) begin
               rx_shift <= {uart_rx, rx_shift[7:1]}; // MSB goes in last

               unique case (rx_state)
                  D0: begin
                         rx_cnt02us <= RX_WAIT_D1;
                         rx_state  <= D1;
                      end 
                  D1: begin
                         rx_cnt02us <= RX_WAIT_D2;
                         rx_state  <= D2;
                      end 
                  D2: begin
                         rx_cnt02us <= RX_WAIT_D3;
                         rx_state  <= D3;
                      end 
                  D3: begin
                         rx_cnt02us <= RX_WAIT_D4;
                         rx_state  <= D4;
                      end 
                  D4: begin
                         rx_cnt02us <= RX_WAIT_D5;
                         rx_state  <= D5;
                      end 
                  D5: begin
                         rx_cnt02us <= RX_WAIT_D6;
                         rx_state  <= D6;
                      end 
                  D6: begin
                         rx_cnt02us <= RX_WAIT_D7;
                         rx_state  <= D7;
                      end 
                  D7: begin
                         rx_cnt02us <= RX_WAIT_STOP;
                         rx_state  <= STOP;
                      end 
                 default: begin end
               endcase // unique case (rx_state)
            end
         endcase // unique case (rx_state)

      end
   end
   

//--------------------------------------
// Tx
//--------------------------------------
// To save resources, SOC-level 1us tick is used as Tx time base.
// Upon detecting SW request to send, and given 8.68us bit period,
// the FSM employs the following delay scheme to generate bits:
// - START ideal end: 1*8.68us= 8.68us. Actual: 8.6(+8.6). Error: -0.08us
// - D0    ideal end: 2*8.68us=17.38us. Actual:17.4(+8.8). Error: +0.02us
// - D1    ideal end: 3*8.68us=26.04us. Actual:26.0(+8.6). Error: -0.04us
// - D2    ideal end: 4*8.68us=34.72us. Actual:34.8(+8.8). Error: +0.08us
// - D3    ideal end: 5*8.68us=43.40us. Actual:43.4(+8.6). Error:  0.00us
// - D4    ideal end: 6*8.68us=52.08us. Actual:52.0(+8.6). Error: -0.08us
// - D5    ideal end: 7*8.68us=60.76us. Actual:60.8(+8.8). Error: +0.04us
// - D6    ideal end: 8*8.68us=69.44us. Actual:69.4(+8.6). Error: -0.04us
// - D7    ideal end: 9*8.68us=78.12us. Actual:78.2(+8.8). Error: +0.08us
// - STOP  ideal end:10*8.68us=86.80us. Actual:86.8(+8.6). Error:  0.00us
//
// In other words, edge placement error is within +/-0.44us for 8.68us
// period, i.e. +/-5%, thus leaving sufficient margin for reliable 
// data reception on the other end.
//--------------------------------------

   localparam bit[7:0] TX_WAIT_START = 8'd43; //+1 tick for initial sync
   localparam bit[7:0] TX_WAIT_D0    = 8'd43; //=44 ticks, from 43 to 0
   localparam bit[7:0] TX_WAIT_D1    = 8'd42; // 8.6
   localparam bit[7:0] TX_WAIT_D2    = 8'd43; // 8.8
   localparam bit[7:0] TX_WAIT_D3    = 8'd42;
   localparam bit[7:0] TX_WAIT_D4    = 8'd42;
   localparam bit[7:0] TX_WAIT_D5    = 8'd43;
   localparam bit[7:0] TX_WAIT_D6    = 8'd42;
   localparam bit[7:0] TX_WAIT_D7    = 8'd43;
   localparam bit[7:0] TX_WAIT_STOP  = 8'd42;

//    localparam bit[3:0] TX_WAIT_START = 4'd9; //+1 tick for initial sync
//    localparam bit[3:0] TX_WAIT_D0    = 4'd7; //=8 ticks, from 7 to 0
//    localparam bit[3:0] TX_WAIT_D1    = 4'd8;
//    localparam bit[3:0] TX_WAIT_D2    = 4'd8;
//    localparam bit[3:0] TX_WAIT_D3    = 4'd7;
//    localparam bit[3:0] TX_WAIT_D4    = 4'd8;
//    localparam bit[3:0] TX_WAIT_D5    = 4'd8;
//    localparam bit[3:0] TX_WAIT_D6    = 4'd7;
//    localparam bit[3:0] TX_WAIT_D7    = 4'd8;
//    localparam bit[3:0] TX_WAIT_STOP  = 4'd8;


   state_t  tx_state;
   cnt02us_t tx_cnt02us; // counts 1us ticks
   logic    tx_cnt02us_is0;
   assign   tx_cnt02us_is0 = (tx_cnt02us == '0);

   logic    tx_nextbit;
   assign   tx_nextbit = tick_02us & tx_cnt02us_is0;
 
   logic [7:0] tx_data;

  // SW write is ignored when sending another byte
   assign uart_tx_busy = (tx_state != IDLE);

   always_ff @(negedge arst_n or posedge clk) begin
      if (arst_n == 1'b0) begin
         tx_state  <= IDLE;
         tx_cnt02us <= '0;
         tx_data   <= '0;

         uart_tx   <= 1'b1; //STOP
      end 
      else begin

        // when not in IDLE, count 1us ticks
         if ((tick_02us == 1'b1) && (tx_state != IDLE)) begin
            tx_cnt02us <= cnt02us_t'(tx_cnt02us - cnt02us_t'(1));
         end

        // FSM runs on main clock, with most states gated by 'tx_cnt02us_is0'
         unique case (tx_state) 

           //---Wait for SW write (which is ignored when not IDLE)
           //   to store SW data that needs to be sent
            IDLE: begin
               uart_tx   <= 1'b1; //STOP
               tx_cnt02us <= TX_WAIT_START;

               if (uart_tx_write == 1'b1) begin
                  tx_data  <= uart_tx_data;
                  tx_state <= START;
               end
            end
           
           //---Wait for next 1us tick to start driving 0 (i.e. sync TX to
           //   the tick), then wait the prescribed amount of time to move on 
           START: if (tick_02us == 1'b1) begin
              uart_tx <= 1'b0; //START

              if (tx_cnt02us_is0 == 1'b1) begin 
                 uart_tx   <= tx_data[0]; //LSB goes out first
                 tx_cnt02us <= TX_WAIT_D0;
                 tx_state  <= D0;
              end
           end
           //---Wait the prescribed amount of time while driving D0,
           //   then move on. Keep repeating the same, till D7
           D0: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[1];
              tx_cnt02us <= TX_WAIT_D1;
              tx_state  <= D1;
           end
           D1: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[2];
              tx_cnt02us <= TX_WAIT_D2;
              tx_state  <= D2;
           end
           D2: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[3];
              tx_cnt02us <= TX_WAIT_D3;
              tx_state  <= D3;
           end
           D3: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[4];
              tx_cnt02us <= TX_WAIT_D4;
              tx_state  <= D4;
           end
           D4: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[5];
              tx_cnt02us <= TX_WAIT_D5;
              tx_state  <= D5;
           end
           D5: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[6];
              tx_cnt02us <= TX_WAIT_D6;
              tx_state  <= D6;
           end
           D6: if (tx_nextbit == 1'b1) begin
              uart_tx   <= tx_data[7];
              tx_cnt02us <= TX_WAIT_D7;
              tx_state  <= D7;
           end
           D7: if (tx_nextbit == 1'b1) begin
              uart_tx   <= 1'b1; // STOP bit
              tx_cnt02us <= TX_WAIT_STOP;
              tx_state  <= STOP;

            `ifdef UART_DEBUG
               $display("%t %m TX'd \t\t%0h (%s)", $time, 
                         tx_data, string'(tx_data));
            `endif 
           end

           //---Wait the prescribed amount of time while driving STOP bit
           STOP: if (tx_nextbit == 1'b1) begin
              tx_state  <= IDLE;
           end

           default: begin end
         endcase // unique case (tx_state)
      end
   end
   

//=========================================
// TODO: FSM for loading IMEM via UART
//=========================================
/*    assign imem_we    = '0;
   assign imem_waddr = '0;
   assign imem_wdat  = '0;
 */
/* Anel's code from TetriSaraj
   parameter [3:0] T_STATES_WAIT_SOP = 0;
   parameter [3:0] T_STATES_CMD = 1;
   parameter [3:0] T_STATES_LEN_LB = 2;
   parameter [3:0] T_STATES_LEN_HB = 3;
   parameter [3:0] T_STATES_DATA0 = 4;
   parameter [3:0] T_STATES_DATA1 = 5;
   parameter [3:0] T_STATES_DATA2 = 6;
   parameter [3:0] T_STATES_DATA3 = 7;
   parameter [3:0] T_STATES_CS = 8;
   parameter [3:0] T_STATES_EOP = 9;
   parameter [3:0] T_STATES_ERROR = 10;
   parameter [3:0] T_STATES_FINISH = 11;
   
   // command protocol constants:
   parameter [7:0]  C_SOP = 8'h23;
   parameter [7:0]  C_EOP = 8'h0d;
   
   // commands:
   parameter [7:0]  C_REGISTER_RD = 8'h08;
   parameter [7:0]  C_REGISTER_WR = 8'h07;
   
   wire             rx_busy, tx_busy, converted, data_valid;
   reg [15:0]       data_length, data_cnt;
   reg [7:0]        command;  

    // Local control logic variables
    // FSM state        
    reg [3:0] state;

    // This variable is super critical in preventing wrong FSM state changes
    reg allow_next;     // Local signal to prevent race conditions 
    
    // IO related variables
    reg flush_ctrl;     // Flush the RX data after reading
    reg tx_enable_ctrl; // Allow tranmission of output, after data is settled

    wire [7:0]  uart_data;   // The actual RX UART data         
    reg  [7:0]  out_data;     // The data that will be sent over TX    
                
        reg             ram_wen;        
        reg [31:0]      ram_data, ram_addr;
    reg [15:0]  display_data;
    reg [7:0]   checksum;       
        reg [8:0]       leds;

    // UART clock related variables
    reg                 clk_uart;           // (100MHz) / (BAUD_RATE*OVERSAMPLING*2) 
    reg [4:0]   counter;        


    // Divided clock for UART @ 115200 baud
        always @(posedge clk_bufg) 
        begin           
                if(sw[15]) begin
                        counter <= counter + 1;
                        if(counter == 5'd27) begin 
                                counter <= 0;
                                clk_uart <= ~clk_uart;
                        end
                end else begin
                        counter         <= 0;
                        clk_uart        <= 0;                   
                end             
        end

        always @(posedge clk_uart)
        begin
                if(!resetn) begin
                        leds = 0;
                        display_data = 16'd1234;
                        state = T_STATES_WAIT_SOP;
                        ram_wen = 0;                    
                        ram_data = 0;
                        ram_addr = 32'hFFFFFFFF;
                end else begin
                        case (state)
                                T_STATES_WAIT_SOP : begin
                                        tx_enable_ctrl <= 0;                                    
                                        leds = 0;
                                        command <= 0;                                   
                                        data_cnt <= 0;
                                        if(converted) begin
                                                if (uart_data == C_SOP) begin
                                                        leds[0] = 1;                                                    
                                                        checksum = 8'b0;
                                                        data_length = 0;
                                                        flush_ctrl <= 1;        // Flush UART RX registers
                                                        state = T_STATES_CMD;
                                                end
                                        end
                                end

                                T_STATES_CMD : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                command  <= uart_data;
                                                state = T_STATES_LEN_LB;
                                        end else
                                                flush_ctrl <= 0;
                                end

                                T_STATES_LEN_LB : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                data_length <= {8'b0, uart_data};
                                                state = T_STATES_LEN_HB;
                                        end else
                                                flush_ctrl <= 0;
                                end
                                        
                                T_STATES_LEN_HB : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                data_length <= { uart_data, data_length[7:0]};
                                                state = T_STATES_DATA0;
                                        end else
                                                flush_ctrl <= 0;
                                end

                                T_STATES_DATA0 : begin
                                        ram_wen <= 0;
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                ram_data[7:0] <= uart_data;
                                                checksum <= checksum + uart_data;
                                                state = T_STATES_DATA1;
                                        end else
                                                flush_ctrl <= 0;
                                end

                                T_STATES_DATA1 : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                ram_data[15:8] <= uart_data;
                                                checksum <= checksum + uart_data;
                                                state = T_STATES_DATA2;
                                        end else
                                                flush_ctrl <= 0;
                                end

                                T_STATES_DATA2 : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                ram_data[23:16] <= uart_data;
                                                checksum <= checksum + uart_data;
                                                state = T_STATES_DATA3;
                                        end else
                                                flush_ctrl <= 0;
                                end
                                        
                                T_STATES_DATA3 : begin
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin        
                                                leds[1] = 1;
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;

                                                data_cnt <= data_cnt + 1;
                                                display_data <= data_cnt + 1;
                                                
                                                ram_data[31:24] <= uart_data;
                                                checksum <= checksum + uart_data;                                               
                                                ram_addr <= {16'd0, data_cnt};
                                                ram_wen <= 1;                                           
                                                
                                                if (data_cnt == (data_length - 16'd1)) begin
                                                        state  = T_STATES_CS;
                                                end else
                                                        state  = T_STATES_DATA0;
                                        end else
                                                flush_ctrl <= 0;
                                end
                                        
                                T_STATES_CS : begin
                                        ram_wen <= 0;
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                leds[2] = 1;
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                state = (uart_data == checksum[7:0]) ? T_STATES_EOP : T_STATES_ERROR;
                                        end else
                                                flush_ctrl <= 0;
                                end
                                        
                                T_STATES_EOP : begin                                    
                                        // Once RX module has produced the final output(converted)
                                        // and registers are cleared(converted is set low), go ahead
                                        if(~flush_ctrl && ~converted)
                                                allow_next <= 1;        // Allow RX after registers cleared
                                                        
                                        if(converted && ~flush_ctrl && allow_next) begin
                                                leds[3] = 1;
                                                flush_ctrl <= 1;        // Data read, flush RX register
                                                allow_next <= 0;
                                                
                                                state = (uart_data == C_EOP) ? T_STATES_FINISH : T_STATES_ERROR;
                                        end else
                                                flush_ctrl <= 0;
                                end
                                        
                                T_STATES_ERROR : begin  
                                        leds[4] = 1;
                                        out_data <= checksum[7:0];
                                        // Once TX is complete, allow going to next state
                                        if(~tx_busy && ~allow_next)
                                                tx_enable_ctrl <= 1;
                                        else begin
                                                allow_next <= 1;
                                                flush_ctrl <= 0;
                                                tx_enable_ctrl <= 0;
                                        end
                                        // TX complete, go to next state
                                        if(~tx_busy && allow_next) begin
                                                allow_next <= 0;
                                                state = T_STATES_WAIT_SOP;
                                        end
                                end

                                T_STATES_FINISH : begin
                                        leds[5] = 1;
                                        out_data <= 8'h55;
                                        // Once TX is complete, allow going to next state
                                        if(~tx_busy && ~allow_next)
                                                tx_enable_ctrl <= 1;
                                        else begin
                                                allow_next <= 1;
                                                flush_ctrl <= 0;
                                                tx_enable_ctrl <= 0;
                                        end
                                        // TX complete, go to next state
                                        if(~tx_busy && allow_next) begin
                                                allow_next <= 0;
                                                state = T_STATES_WAIT_SOP;
                                        end
                                end

                                default:begin
                                        state = T_STATES_WAIT_SOP;
                                end
                        endcase
                end
        end
        
        reg progmem_wen;
        reg ram_wen_dl1, ram_wen_dl2;
    always @(posedge clk)  
    begin       
                if(sw[15]) begin        
                        ram_wen_dl1 <= ram_wen; 
                        ram_wen_dl2 <= ram_wen_dl1;
                        if(ram_wen_dl2 == 1'b0 && ram_wen == 1'b1)
                                progmem_wen <= 1'b1;
                        else 
                                progmem_wen <= 1'b0;
                end else begin
                        progmem_wen <= 1'b0;
                end
        end
*/

endmodule: uart

/*
-----------------------------------------------------------------------------
Version History:
-----------------------------------------------------------------------------
 2024/8/17 Tarik Ibrahimovic: initial creation
*/
