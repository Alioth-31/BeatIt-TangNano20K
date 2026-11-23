// Default development image: no guessed sensor endpoints.
// --factory-calibration replaces this header only in the staged build.
localparam [95:0] BOOT_CALIBRATION=96'd0;
localparam [2:0] BOOT_CALIBRATION_MASK=3'b000;
localparam [2:0] BOOT_ENABLE_MASK=3'b000;
localparam BOOT_INVERT_X=1'b0;
