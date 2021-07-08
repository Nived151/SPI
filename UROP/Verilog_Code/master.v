module spi_master 
    #(
      parameter DATA_WIDTH = 8
     )

    (
      input Clk,                      // 50-MHz clock
      input Reset,                    // Global Reset
      input Start,                    // Start transmitting (also used to register TxData)
      input [1:0] MODE,
      input [1:0] ClkDiv,             // Clock divider: 0 => /4
                                      //                1 => /8
                                      //                2 => /16
                                      //                3 => /32
      input [DATA_WIDTH-1:0] TxData,  // Transmit Data

      output reg Done,                // Transmit Completed
      output reg [DATA_WIDTH-1:0] RxData, // Receive Data

// SPI Interface Signals
      input  MISO,                    // Master In Slave Out
      output reg SClk,                // SPI Clock
      output reg MOSI,                // Master Out Slave In
      output reg SS                   // Slave Select
    );

    wire ClkPol;
    wire ClkPha;
    wire XferComplete;

// Frequency dividing logic to generate midCyc signal.
    wire ClkEn;
    wire [4:0] next_count;
    reg  [4:0] count;
    reg  [3:0] halfcyc;
    reg        midCyc;
    reg        capture_nxt, shift_nxt;
    reg        capture, shift;
    reg        bitcnt_en;

// FSM States for generating SPI Clock
    localparam  IDLE  = 2'b11,
                BEGIN = 2'b10,
                LEAD  = 2'b01,
                TRAIL = 2'b00;

// FSM to generate SPI Clock and other SPI interface signals
    reg [1:0] current_state, next_state;

// Master shift register
    reg [DATA_WIDTH-1:0] txreg;

// Bit counter
    reg [DATA_WIDTH-1:0] bitcnt;

// Generate polarity & phase signals for the various SPI modes
// Clock Polarity. 0=Idle at '0' with pulse of '1'.
//                 1=Idle at '1' with pulse of '0'
    assign ClkPol = (MODE[1:0] == 2'b10) || (MODE[1:0] == 2'b11);
// Clock Phase. 0=Change data on trailing edge, capture on leading edge.
//              1=Change data on leading edge, capture on trailing edge.
    assign ClkPha = (MODE[1:0] == 2'b01) || (MODE[1:0] == 2'b11);

// midCyc logic. Asserts when the frequency is half cycle base on ClkDiv[1:0]
    assign next_count[4:0] = count[4:0] + 1;
    assign ClkEn = (next_count == {halfcyc,1'b0});

// Update the clock counter (logic used to generate SClk)
    always @ (posedge Clk)
      begin
// If the current FSM is in IDLE, then reset the counter
        if ( current_state == IDLE ) begin
          midCyc <= 1'b0;
          count[4:0] <= 5'b0;
        end else begin
// Otherwise, start counting until midCyc is asserted
          case ( {Reset, ClkEn} )
            2'b00: begin
                     midCyc <= 1'b0;
                     count[4:0] <= next_count[4:0];
                   end
            2'b01: begin
                     midCyc <= 1'b1;
                     count[4:0] <= 5'b0;
                   end
            2'b10,
            2'b11: begin
                     midCyc <= 1'b0;
                     count[4:0] <= 5'b0;
                   end
            default: ;
          endcase
        end
      end

// Selects clock divider for SPI Clock based on ClkDiv[1:0] inputs
    always @ (ClkDiv)
      case ( ClkDiv[1:0] )
        2'b00: halfcyc = 4'b0001;     // Clk/4
        2'b01: halfcyc = 4'b0010;     // Clk/8
        2'b10: halfcyc = 4'b0100;     // Clk/16
        2'b11: halfcyc = 4'b1000;     // Clk/32
//        default: halfcyc = 4'b0001;   // Clk/4
      endcase

// Logic used to generate SS (Slave Select) as well as SPI Clock (SClk) and Done signals
// base on the current_state of FSM. In the IDLE state, SClk reflects the clock polarity.
    always @ (current_state or XferComplete or ClkPol)
      begin
        case ( current_state )
          IDLE: begin
                  SS <= 1'b1;
                  SClk <= ClkPol;
                  Done <= 1'b1;
                end
          BEGIN: begin
                   SS <= 1'b0;
                   SClk <= ClkPol;
                   Done <= 1'b0;
                 end
          LEAD: begin
                  SS <= 1'b0;
                  SClk <= ClkPol ^ current_state[0];
                  Done <= 1'b0;
                end
          TRAIL: begin
                   SS <= 1'b0;
                   SClk <= ClkPol ^ current_state[0];
                   if ( XferComplete )
                     Done <= 1'b1;
                   else
                     Done <= 1'b0;
                 end
        endcase
      end

// Next-state logic for FSM.
      always @ ( current_state or Start or midCyc or XferComplete )
        begin
          case ( current_state )
            IDLE: if ( !Start )
                    next_state <= IDLE;
                  else
                    next_state <= BEGIN;
            BEGIN: next_state <= LEAD;
            LEAD: if ( midCyc )
                    next_state <= TRAIL;
                  else
                    next_state <= LEAD;
            TRAIL: case ( {XferComplete, midCyc} )
                     2'b00: next_state <= TRAIL;
                     2'b01: next_state <= LEAD;
                     2'b10: next_state <= IDLE;
                     2'b11: next_state <= IDLE;
                   endcase
          endcase
        end

// Logic for shifting the master shift register and capturing data on MISO.
    always @ (current_state or next_state or midCyc or capture or shift or ClkPha)
    begin
      case ( current_state )
        IDLE: begin
                bitcnt_en <= 1'b0;

                shift_nxt <= 1'b0;
                capture_nxt <= 1'b0;
              end
        BEGIN: begin
                 bitcnt_en <= 1'b0;

// In the case of the first cycle (where the current_state = BEGIN and the next_state = LEAD),
// then at the next clock edge, if CPHA=0, then capture the data on MISO. Othewise (CPHA=1),
// shift on the next clock edge.
                 if ( next_state == LEAD ) begin
                   if ( ClkPha == 1'b0 ) begin
                     shift_nxt <= 1'b0;
                     capture_nxt <= 1'b1;                   
                   end else begin
                     shift_nxt <= 1'b1;
                     capture_nxt <= 1'b0;  
                   end
                 end else begin
                   shift_nxt <= 1'b0;
                   capture_nxt <= 1'b0;
                 end
               end
        LEAD : begin
// If midCyc is asserted, that means that the next cycle is the trailing edge
// If ClkPha == 1'b0, then start shifting. Otherwise (i.e. ClkPha == 1'b1),
// begin capturing on the next clock edge.
                 if ( midCyc ) begin
                   if ( ClkPha == 1'b0 ) begin
                     capture_nxt <= 1'b0;
                     if ( !shift )
                       shift_nxt <= 1'b1;
                     else
                       shift_nxt <= 1'b0;
                   end else begin
                     shift_nxt <= 1'b0;
                     if ( !capture )
                       capture_nxt <= 1'b1;
                     else
                       capture_nxt <= 1'b0;
                   end
                 end else begin
                   capture_nxt <= 1'b0;
                   shift_nxt <= 1'b0;
                 end

                 if ( next_state == TRAIL )
                   bitcnt_en <= 1'b1;
                 else
                   bitcnt_en <= 1'b0;
               end
        TRAIL: begin
                 bitcnt_en <= 1'b0;

                 if ( midCyc ) begin
                   if ( ClkPha == 1'b0 ) begin
                     shift_nxt <= 1'b0;
                     if ( !capture )
                       capture_nxt <= 1'b1;
                     else
                       capture_nxt <= 1'b0;
                   end else begin
                     capture_nxt <= 1'b0;
                     if ( !shift )
                       shift_nxt <= 1'b1;
                     else
                       shift_nxt <= 1'b0;
                   end
                 end else begin
                   capture_nxt <= 1'b0;
                   shift_nxt <= 1'b0;
                 end
               end
      endcase
    end

// data bit count is clocked using SPI clock (SClk)
// Set XferComplete when the MSB of the bit counter is '1'.
    assign XferComplete = bitcnt[DATA_WIDTH-1];

// Update State machine.
    always @ (posedge Clk)
      if ( Reset ) begin
        current_state <= IDLE;
        txreg <= 0;
        RxData <= 0;
        bitcnt <= 0;
      end else begin
        current_state <= next_state;

// Load TxData into Master Shift Register if Start is asserted.
        if ( Start )
          txreg <= TxData;
        else
          txreg <= txreg;

// MOSI is driven for the case where a transmission is started and CPHA = 0
        if ( current_state == BEGIN && ClkPha == 1'b0 ) begin
          MOSI <= TxData[DATA_WIDTH-1];
          txreg <= {TxData[DATA_WIDTH-2:0], 1'b0};
        end

// If shift_nxt is asserted, then begin shifting the register onto MOSI port.
        if ( shift_nxt == 1'b1 ) begin
          txreg <= {txreg[DATA_WIDTH-2:0], 1'b0};
          MOSI <= txreg[DATA_WIDTH-1];
        end

        shift <= shift_nxt;

// If capture_nxt is asserted, capture the data from MISO
        if ( capture_nxt == 1'b1 ) begin
          RxData <= {RxData[DATA_WIDTH-2:0], MISO};
        end

        capture <= capture_nxt;

        if ( XferComplete == 1'b1 ) begin
          bitcnt <= 0;
        end else if ( bitcnt_en )
          bitcnt <= {bitcnt[DATA_WIDTH-2:0], 1'b1};
        else
          bitcnt <= bitcnt;
      end

endmodule