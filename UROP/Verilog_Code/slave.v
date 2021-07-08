module spi_slave
    #(
      parameter DATA_WIDTH = 8
     )

    (
      input Clk,                            // System (or FPGA) clock.
      input [1:0] MODE,
      input [DATA_WIDTH-1:0] TxData,        // Transmit Data

      output Done,                          // Transmit Completed
      output reg [DATA_WIDTH-1:0] RxData,   // Receive Data

// SPI Interface Signals
      input  SClk,                          // SPI clock
      input  MOSI,                          // Master Out Slave In
      input  SS,                            // Slave Select
      output MISO                           // Master In Slave Out
    );

    wire ClkPol;
    wire ClkPha;
//    reg  Dout;
    wire Dout;
    reg  capture_en;
    reg  shift_en;

// Bit counter
    reg [DATA_WIDTH-1:0] bitcnt;
    reg                  bitcnt_en;

    reg [1:0] current_state, next_state;

// FSM States to capture or shift data
    localparam  IDLE  = 2'b11,
                BEGIN = 2'b10,
                LEAD  = 2'b01,
                TRAIL = 2'b00;

// Generate polarity & phase signals for the various SPI modes
// Clock Polarity. 0=Idle at '0' with pulse of '1'.
//                 1=Idle at '1' with pulse of '0'
    assign ClkPol = (MODE[1:0] == 2'b10) || (MODE[1:0] == 2'b11);
// Clock Phase. 0=Change data on trailing edge, capture on leading edge.
//              1=Change data on leading edge, capture on trailing edge.
    assign ClkPha = (MODE[1:0] == 2'b01) || (MODE[1:0] == 2'b11);

// Slave shift register
    reg [DATA_WIDTH-1:0] txreg;

    assign MISO = (SS) ? 1'bz: Dout;
    assign Dout = txreg[DATA_WIDTH-1];

// Next-state logic for FSM
    always @ ( current_state or ClkPol or SClk or SS )
      begin
        case ( current_state )
          IDLE: if ( SS )
                  next_state <= IDLE;
                else
                  next_state <= BEGIN;
          BEGIN: begin
                   if ( {ClkPol, SClk} == 2'b00 || {ClkPol, SClk} == 2'b11 ) begin
                     next_state <= BEGIN;
                   end else begin
                     next_state <= LEAD;
                   end
                 end
          LEAD: begin
                  if ( {ClkPol, SClk} == 2'b00 || {ClkPol, SClk} == 2'b11 ) begin
                    next_state <= TRAIL;
                  end else begin
                    next_state <= LEAD;
                  end
                end
          TRAIL: begin
                   if ( {ClkPol, SClk} == 2'b00 || {ClkPol, SClk} == 2'b11 ) begin
                     next_state <= TRAIL;
                   end else begin
                     next_state <= LEAD;
                   end
                 end
        endcase
      end

/////////////////////////////////////////////////////////////////////////////////////////
// Update State machine
    always @ (posedge Clk)
      if ( SS == 1'b1 ) begin
        current_state <= IDLE;
        bitcnt <= {DATA_WIDTH{1'b0}};
        txreg <= TxData;
//        Dout <= TxData[DATA_WIDTH-1];
//        $display("SS=1----%0t txreg:%0x Dout:%0x", $time, txreg, Dout);
      end else begin
        current_state <= next_state;
// bitcnt_en is asserted in the trailing edge. bitcnt is shifted left with bitcnt_en asserted.
        if ( bitcnt_en == 1'b1 )
          bitcnt <= {bitcnt[DATA_WIDTH-2:0], 1'b1};
        else
          bitcnt <= bitcnt;

        if ( capture_en == 1'b1 ) begin
          RxData <= {RxData[DATA_WIDTH-2:0], MOSI};
        end else begin
          RxData <= RxData;
        end

//        if ( next_state == IDLE ) begin
//          Dout <= TxData[DATA_WIDTH-1];
//          txreg <= TxData;
//        end else
        if ( shift_en == 1'b1 ) begin
          txreg <= {txreg[DATA_WIDTH-2:0], 1'b0};
//          Dout <= txreg[DATA_WIDTH-1];
//          $display("SS=0 shift_en=1----%0t txreg:%0x Dout:%0x", $time, txreg, Dout);
        end else begin
//          Dout <= Dout;
          txreg <= txreg;
//          $display("SS=0 shift_en=0----%0t txreg:%0x Dout:%0x", $time, txreg, Dout);
        end
      end
/////////////////////////////////////////////////////////////////////////////////////////

// Set Done when the MSB of the bit counter is '1'.
    assign Done = bitcnt[DATA_WIDTH-1];

// bitcnt_en logic
    always @ ( current_state or next_state )
      begin
        if ( current_state == LEAD && next_state == TRAIL )
          bitcnt_en <= 1'b1;
        else
          bitcnt_en <= 1'b0;
      end

// Generating capture_en to capture data into RxData base on next_state
    always @ ( next_state or current_state or ClkPha )
      begin
          case ( next_state )
            IDLE : capture_en <= 1'b0;
            BEGIN: capture_en <= 1'b0;
            LEAD : if ( current_state == BEGIN && ClkPha == 1'b0 )
                     capture_en <= 1'b1;
                   else if ( current_state == TRAIL && ClkPha == 1'b0 )
                     capture_en <= 1'b1;
                   else
                     capture_en <= 1'b0;
            TRAIL: if ( current_state == LEAD && ClkPha == 1'b1 )
                     capture_en <= 1'b1;
                   else
                     capture_en <= 1'b0;
          endcase
      end


// Generating txreg based on next_state
      always @ ( next_state or current_state or ClkPha )
        begin
          case ( next_state )
// Load the transmit data into Slave shift register
            IDLE : shift_en <= 1'b0;
// Make sure that data is available before the leading edge for CPHA=0
            BEGIN: shift_en <= 1'b0;
            LEAD : if ( current_state == TRAIL && ClkPha == 1'b1 )
                     shift_en <= 1'b1;
                   else
                     shift_en <= 1'b0;
            TRAIL: if ( current_state == LEAD && ClkPha == 1'b0 )
                     shift_en <= 1'b1;
                   else
                     shift_en <= 1'b0;
          endcase
        end

//    always @ (posedge SClk)
//      case ( {ClkPol, ClkPha} )
//        2'b00: RxData <= {RxData[DATA_WIDTH-2:0], MOSI};
//        2'b01, 
//        2'b10: begin
//                 txreg <= {txreg[DATA_WIDTH-2:0], 1'b0};
//                 Dout <= txreg[DATA_WIDTH-1];
//               end
//        2'b11: RxData <= {RxData[DATA_WIDTH-2:0], MOSI};
//        default: ;
//      endcase

//    always @ (negedge SClk)
//      case ( {ClkPol, ClkPha} )
//        2'b00: begin
//                 txreg <= {txreg[DATA_WIDTH-2:0], 1'b0};
//                 Dout <= txreg[DATA_WIDTH-1];
//               end
//        2'b01, 
//        2'b10: RxData <= {RxData[DATA_WIDTH-2:0], MOSI};
//        2'b11: begin
//                 txreg <= {txreg[DATA_WIDTH-2:0], 1'b0};
//                 Dout <= txreg[DATA_WIDTH-1];
//               end
//        default: ;
//      endcase

endmodule