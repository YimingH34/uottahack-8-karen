/****************************************************************************
FILENAME     :  video_uut.sv
PROJECT      :  Hack-a-Thon 2026 (Project W.I.F.E.)
DESCRIPTION  :  Sinusoidal Waveform with Keyframe Interpolation (Fixed)
****************************************************************************/

module video_uut (
    input  wire          clk_i       ,
    input  wire          cen_i       ,
    input  wire          rst_i       ,
    input  wire          vid_sel_i   ,
    input  wire [23:0]   vid_rgb_i   ,
    input  wire [1:0]    vh_blank_i  ,
    input  wire [2:0]    dvh_sync_i  ,
    output wire [2:0]    dvh_sync_o  ,
    input  wire [7:0]    vio_amplitude_i,
    input  wire[2:0]     vio_state_i,
    output wire [23:0]   vid_rgb_o   
); 

    // --- 1. VIO INSTANTIATION ---
    // wire [7:0] vio_amplitude;  // Volume (0-255)
  //  wire [2:0] vio_state;      // State: 0=Idle, 1=Listening, 2=Neutral, 3=Angry, 4=Screensaver



    // --- 2. SETTINGS ---
    localparam V_RES = 1080;
    localparam V_MID = V_RES / 2; 
    localparam H_RES = 1920;
    localparam LEFT_bound = H_RES / 8;           // 240 pixels
    localparam RIGHT_bound = (H_RES * 7) / 8;    // 1680 pixels
    localparam FADE_WIDTH = 120;                 // Fade zone width in pixels
    localparam LINE_THICKNESS = 10;               // Thicker waveform line
    localparam INTERP_FRAMES = 180;              // ~3 seconds at 60fps (slower keyframes)

    // --- 3. SINE LUT ROM (64 entries for quarter wave, synthesis-friendly) ---
    // Quarter-wave sine table (0° to 90°), 64 entries, scaled to ±127
    logic [6:0] sine_rom [0:63];
    initial begin
        sine_rom[0] = 7'd0; sine_rom[1] = 7'd3; sine_rom[2] = 7'd6; sine_rom[3] = 7'd9;
        sine_rom[4] = 7'd12; sine_rom[5] = 7'd16; sine_rom[6] = 7'd19; sine_rom[7] = 7'd22;
        sine_rom[8] = 7'd25; sine_rom[9] = 7'd28; sine_rom[10] = 7'd31; sine_rom[11] = 7'd34;
        sine_rom[12] = 7'd37; sine_rom[13] = 7'd40; sine_rom[14] = 7'd43; sine_rom[15] = 7'd46;
        sine_rom[16] = 7'd49; sine_rom[17] = 7'd51; sine_rom[18] = 7'd54; sine_rom[19] = 7'd57;
        sine_rom[20] = 7'd60; sine_rom[21] = 7'd63; sine_rom[22] = 7'd65; sine_rom[23] = 7'd68;
        sine_rom[24] = 7'd71; sine_rom[25] = 7'd73; sine_rom[26] = 7'd76; sine_rom[27] = 7'd78;
        sine_rom[28] = 7'd81; sine_rom[29] = 7'd83; sine_rom[30] = 7'd85; sine_rom[31] = 7'd88;
        sine_rom[32] = 7'd90; sine_rom[33] = 7'd92; sine_rom[34] = 7'd94; sine_rom[35] = 7'd96;
        sine_rom[36] = 7'd98; sine_rom[37] = 7'd100; sine_rom[38] = 7'd102; sine_rom[39] = 7'd104;
        sine_rom[40] = 7'd106; sine_rom[41] = 7'd107; sine_rom[42] = 7'd109; sine_rom[43] = 7'd111;
        sine_rom[44] = 7'd112; sine_rom[45] = 7'd113; sine_rom[46] = 7'd115; sine_rom[47] = 7'd116;
        sine_rom[48] = 7'd117; sine_rom[49] = 7'd118; sine_rom[50] = 7'd120; sine_rom[51] = 7'd121;
        sine_rom[52] = 7'd122; sine_rom[53] = 7'd122; sine_rom[54] = 7'd123; sine_rom[55] = 7'd124;
        sine_rom[56] = 7'd125; sine_rom[57] = 7'd125; sine_rom[58] = 7'd126; sine_rom[59] = 7'd126;
        sine_rom[60] = 7'd126; sine_rom[61] = 7'd127; sine_rom[62] = 7'd127; sine_rom[63] = 7'd127;
    end

    // Sine lookup function using quarter-wave symmetry
    function automatic signed [7:0] sine_lookup;
        input [7:0] phase;
        logic [5:0] addr;
        logic [6:0] value;
        
        // Quarter wave addressing with symmetry
        if (phase[7:6] == 2'b00) begin        // 0-63: Q1 (0° to 90°)
            addr = phase[5:0];
            value = sine_rom[addr];
            sine_lookup = {1'b0, value};      // Positive
        end
        else if (phase[7:6] == 2'b01) begin   // 64-127: Q2 (90° to 180°)
            addr = ~phase[5:0];               // Mirror
            value = sine_rom[addr];
            sine_lookup = {1'b0, value};      // Positive
        end
        else if (phase[7:6] == 2'b10) begin   // 128-191: Q3 (180° to 270°)
            addr = phase[5:0];
            value = sine_rom[addr];
            sine_lookup = -{1'b0, value};     // Negative
        end
        else begin                            // 192-255: Q4 (270° to 360°)
            addr = ~phase[5:0];               // Mirror
            value = sine_rom[addr];
            sine_lookup = -{1'b0, value};     // Negative
        end
    endfunction

    // --- 4. SIGNALS ---
    reg [23:0]  vid_rgb_d1, vid_rgb_d2;   // 2-stage pipeline for video
    reg [2:0]   dvh_sync_d1, dvh_sync_d2; // 2-stage pipeline for sync
    reg [11:0]  x_cnt;
    reg [11:0]  y_cnt;
    reg         prev_de; 
    
    // LFSR for random target generation
    reg [15:0]  lfsr;
    
    // Keyframe system
    reg [7:0]   frame_counter;
    
    // Frequency control
    reg [7:0]   target_freq_1, target_freq_2;
    reg [7:0]   current_freq_1, current_freq_2;
    
    // Amplitude control (dynamic per keyframe)
    reg [7:0]   target_amp;
    reg [7:0]   current_amp;

    // Random generation signals
    logic [7:0] mask_freq, half_freq, mask_amp, half_amp;
    logic [7:0] rand_f1, rand_f2, rand_a;

    // State tracking for transitions
    reg [2:0]   prev_state;  // Expanded to 3 bits for screensaver
    
    // Screensaver animation - 2px column fill/overwrite
    reg [23:0]  screensaver_timer;       // Timer for next column
    reg [10:0]  fill_column;             // Current fill column (0-959 for 1920/2)
    reg [7:0]   current_hue;             // Current fill color hue
    reg [7:0]   prev_hue;                // Previous fill color (for unfilled area)
    localparam COLUMN_FILL_DELAY = 24'd500_000;  // ~3.3ms per column at 148.5MHz (fast smooth fill)
    localparam COLUMN_WIDTH = 2;         // 2 pixels per column
    localparam NUM_COLUMNS = H_RES / COLUMN_WIDTH;  // 960 columns
    
    // =========== LOGO ROM (for Screensaver) ===========
    localparam LOGO_WIDTH  = 712;        // Logo width in pixels
    localparam LOGO_HEIGHT = 400;        // Logo height in pixels
    localparam LOGO_BYTES_PER_ROW = LOGO_WIDTH / 8;  // 89 bytes per row
    localparam LOGO_TOTAL_BYTES = LOGO_BYTES_PER_ROW * LOGO_HEIGHT;  // 35600 bytes
    
    // Bouncing logo position (like DVD screensaver)
    reg [11:0] logo_x, logo_y;           // Logo position (top-left corner)
    reg signed [2:0] logo_vx, logo_vy;   // Logo velocity (-4 to +3)
    reg [19:0] logo_timer;               // Timer for logo movement
    localparam LOGO_MOVE_DELAY = 20'd1_000_000;  // ~6.7ms between moves (~12fps movement, 5x slower)
    
    // Logo ROM storage (1-bit packed, 8 pixels per byte)
    reg [7:0] logo_rom [0:LOGO_TOTAL_BYTES-1];
    initial begin
        $readmemh("logo_rom.mem", logo_rom);
    end
    
    // =========== BREAKOUT GAME (State 5) ===========
    // Game area parameters
    localparam GAME_LEFT   = 160;        // Left margin
    localparam GAME_RIGHT  = 1760;       // Right margin (1920 - 160)
    localparam GAME_TOP    = 100;        // Top margin
    localparam GAME_BOTTOM = 1000;       // Bottom (where paddle is)
    localparam GAME_WIDTH  = GAME_RIGHT - GAME_LEFT;  // 1600
    
    // Ball parameters
    localparam BALL_SIZE   = 16;         // Ball is 16x16 pixels
    reg [11:0] ball_x, ball_y;           // Ball position (top-left corner)
    reg signed [4:0] ball_vx, ball_vy;   // Ball velocity (-16 to +15)
    
    // Paddle parameters
    localparam PADDLE_WIDTH  = 200;
    localparam PADDLE_HEIGHT = 16;
    localparam PADDLE_Y      = GAME_BOTTOM - PADDLE_HEIGHT - 20;  // Fixed Y position
    localparam PADDLE_SMOOTH = 2;        // Pixels per game tick to move (slower = smoother)
    reg [11:0] paddle_x;                 // Paddle X position (left edge)
    reg [11:0] target_paddle_x;          // Target paddle position (from input)
    
    // Block parameters - 10 columns x 5 rows = 50 blocks
    localparam BLOCK_COLS   = 10;
    localparam BLOCK_ROWS   = 5;
    localparam BLOCK_WIDTH  = GAME_WIDTH / BLOCK_COLS;  // 160 pixels
    localparam BLOCK_HEIGHT = 30;
    localparam BLOCK_GAP    = 4;
    localparam BLOCK_BORDER = 3;         // Border thickness for outline effect
    localparam BLOCKS_TOP   = GAME_TOP + 50;
    reg [49:0] blocks_alive;             // Bitmask: 1 = block exists
    
    // Game timing
    reg [19:0] game_tick;                // Counter for game speed
    localparam GAME_SPEED = 20'd600_000; // ~4ms per game tick (very slow ball)
    
    // Game score counters
    reg [7:0] balls_lost;                // Number of times ball fell off
    reg [7:0] blocks_hit;                // Number of blocks destroyed
    reg game_paused;                     // Game paused (win/lose)
    reg game_won;                        // True if won, false if lost
    
    
    // State-based parameters
    logic [23:0] state_color;
    logic [7:0]  base_amp;       // Base amplitude for state
    logic [3:0]  amp_var_bits;   // Variability of amplitude
    logic [7:0]  base_freq_1, base_freq_2;
    logic [3:0]  freq_var_bits;  // Number of bits for variation (power of 2)
    
    // Wave generation
    logic [19:0] phase_1, phase_2; // Expanded for larger multiplication
    logic [7:0]  phase_idx_1, phase_idx_2;
    logic signed [7:0]  sine_1, sine_2;
    logic signed [9:0]  combined_wave;
    logic signed [12:0] wave_height;
    logic signed [12:0] target_y;
    
    // Final amplitude calculation
    logic [7:0]  final_amp_scale;
    logic [15:0] amp_mult_debug;
    
    // Envelope/fade signals
    logic [7:0]  envelope_scale;  // 0-255, scales amplitude at edges
    logic [7:0]  period_amp_mod;  // Per-period amplitude modulation
    logic [7:0]  period_number;   // Which wave period we're in
    
    // === NEW: Seed-based per-period amplitude with interpolation ===
    reg [15:0]  prev_seed;        // Seed for previous keyframe amplitudes
    reg [15:0]  next_seed;        // Seed for next keyframe (target) amplitudes
    reg [7:0]   blend_factor;     // 0-255 interpolation factor (0=prev, 255=next)
    
    // Frequency targets also update every 2 seconds only
    reg [7:0]   stable_freq_1, stable_freq_2;  // Locked frequencies between keyframes
    
    // Grid settings
    localparam GRID_SPACING = 80;  // Smaller grid (was 200)
    localparam [23:0] GRID_COLOR = 24'h002040;  // Faint dark blue for grid
    
    // Screen center for radial gradient
    localparam H_CENTER = H_RES / 2;  // 960
    localparam V_CENTER = V_RES / 2;  // 540
    
    // --- 5. STATE CONFIGURATION ---
    always_comb begin
        case (vio_state_i)
            3'd0: begin // IDLE - Flat line
                state_color = 24'h00FF00;      // Green
                base_amp = 8'd0;               // Flat
                amp_var_bits = 4'd0;
                base_freq_1 = 8'd0;
                base_freq_2 = 8'd0;
                freq_var_bits = 4'd0;
            end
            3'd1: begin // LISTENING - Higher freq, responsive
                state_color = 24'h0000FF;      // Blue
                // Use input amplitude but keep a minimum of 20 so it's always visible
                base_amp = (vio_amplitude_i < 8'd20) ? 8'd20 : vio_amplitude_i;
                amp_var_bits = 4'd6;           // +/- 32
                base_freq_1 = 8'd120;
                base_freq_2 = 8'd140;
                freq_var_bits = 4'd4;          // +/- 8
            end
            3'd2: begin // NEUTRAL - Higher freq, moderate
                state_color = 24'h00FF00;      // Green
                base_amp = 8'd200;             // Larger base amplitude
                amp_var_bits = 4'd6;           // +/- 32
                base_freq_1 = 8'd150;
                base_freq_2 = 8'd180;
                freq_var_bits = 4'd4;          // +/- 8
            end
            3'd3: begin // ANGRY - Much higher freq, chaotic
                state_color = 24'hFF0000;      // Red
                base_amp = 8'd255;             // Maximum amplitude
                amp_var_bits = 4'd7;           // +/- 64
                base_freq_1 = 8'd220;
                base_freq_2 = 8'd250;
                freq_var_bits = 4'd5;          // +/- 16
            end
            default: begin // State 4+ = SCREENSAVER (will be drawn separately)
                state_color = 24'hFFFFFF;      // White (placeholder)
                base_amp = 8'd0;
                amp_var_bits = 4'd0;
                base_freq_1 = 8'd0;
                base_freq_2 = 8'd0;
                freq_var_bits = 4'd0;
            end
        endcase
    end
    
    // --- HSV to RGB conversion for rainbow (simplified) ---
    // Input: hue (0-255), Output: RGB (24-bit)
    function automatic [23:0] hue_to_rgb;
        input [7:0] hue;
        logic [7:0] region, remainder, p, q, t;
        logic [7:0] r, g, b;
        
        region = hue / 43;  // 6 regions (0-5)
        remainder = (hue - (region * 43)) * 6;
        
        p = 8'd0;
        q = 8'd255 - remainder;
        t = remainder;
        
        case (region)
            3'd0: begin r = 8'd255; g = t;      b = p; end
            3'd1: begin r = q;      g = 8'd255; b = p; end
            3'd2: begin r = p;      g = 8'd255; b = t; end
            3'd3: begin r = p;      g = q;      b = 8'd255; end
            3'd4: begin r = t;      g = p;      b = 8'd255; end
            default: begin r = 8'd255; g = p;   b = q; end
        endcase
        
        hue_to_rgb = {r, g, b};
    endfunction

    // --- 6. WAVE CALCULATION ---
    // Phase accumulators
    assign phase_1 = x_cnt * current_freq_1;
    assign phase_2 = x_cnt * current_freq_2;
    
    // Index into sine LUT
    assign phase_idx_1 = phase_1[15:8];
    assign phase_idx_2 = phase_2[15:8];
    
    // Lookup sine values
    assign sine_1 = sine_lookup(phase_idx_1);
    assign sine_2 = sine_lookup(phase_idx_2);
    
    // Combine waves
    assign combined_wave = $signed({sine_1[7], sine_1}) + $signed({sine_2[7], sine_2});
    
    // --- ENVELOPE CALCULATION (Smooth fade at edges) ---
    // Creates a smooth transition from 0 to full amplitude at boundaries
    always_comb begin
        if (x_cnt < LEFT_bound) begin
            envelope_scale = 8'd0;  // Before active region
        end
        else if (x_cnt < LEFT_bound + FADE_WIDTH) begin
            // Linear fade in: 0 to 255 over FADE_WIDTH pixels
            envelope_scale = ((x_cnt - LEFT_bound) * 255) / FADE_WIDTH;
        end
        else if (x_cnt > RIGHT_bound) begin
            envelope_scale = 8'd0;  // After active region
        end
        else if (x_cnt > RIGHT_bound - FADE_WIDTH) begin
            // Linear fade out: 255 to 0 over FADE_WIDTH pixels
            envelope_scale = ((RIGHT_bound - x_cnt) * 255) / FADE_WIDTH;
        end
        else begin
            envelope_scale = 8'd255; // Full amplitude in center
        end
    end
    
    // --- PER-PERIOD AMPLITUDE MODULATION WITH KEYFRAME INTERPOLATION ---
    // Period number derived from phase (increments each full cycle)
    assign period_number = phase_1[15:8]; // Wraps every 256 -> new "period"
    
    // Hash function: generates pseudo-random but consistent value for (seed, period) pair
    function automatic [7:0] hash_period;
        input [15:0] seed;
        input [7:0] period;
        logic [15:0] mixed;
        mixed = seed ^ {period, period};
        mixed = mixed ^ (mixed >> 4);
        mixed = mixed * 16'd2057;  // Prime multiplier for better distribution
        hash_period = mixed[7:0] ^ mixed[15:8];
    endfunction
    
    // Calculate amplitude for this period from BOTH seeds, then interpolate
    always_comb begin
        logic [7:0] prev_amp, next_amp;
        logic [7:0] prev_hash, next_hash;  // Intermediate for function results
        logic [15:0] blended;
        
        // Get hash values first (can't slice function return directly)
        prev_hash = hash_period(prev_seed, period_number);
        next_hash = hash_period(next_seed, period_number);
        
        // Get amplitude from previous seed (what we're fading FROM)
        prev_amp = 8'd160 + prev_hash[5:0]; // 160-223
        
        // Get amplitude from next seed (what we're fading TO)
        next_amp = 8'd160 + next_hash[5:0]; // 160-223
        
        // Linear interpolation: result = prev*(255-blend) + next*blend, all /255
        // Simplified: result = prev + (next-prev)*blend/256
        blended = ({8'd0, prev_amp} * (8'd255 - blend_factor) + {8'd0, next_amp} * blend_factor);
        period_amp_mod = blended[15:8];  // Divide by 256
    end
    
    // Scale dynamic current_amp by global VIO amplitude (master volume)
    assign amp_mult_debug = current_amp * vio_amplitude_i;
    assign final_amp_scale = amp_mult_debug[15:8];
    
    // Apply envelope, per-period modulation, and amplitude scaling
    logic signed [23:0] wave_mult_full;
    logic [31:0] amp_chain;  // Wide enough for 8*8*8 = 24 bits
    logic [7:0] scaled_amp;
    
    // Chain: final_amp_scale * envelope * period_mod / 65536
    // FIX: Use explicit 32-bit chain to avoid truncation before shift
    assign amp_chain = {24'd0, final_amp_scale} * {24'd0, envelope_scale} * {24'd0, period_amp_mod};
    assign scaled_amp = amp_chain[23:16];  // Take upper 8 bits of 24-bit result
    
    assign wave_mult_full = $signed(combined_wave) * $signed({1'b0, scaled_amp});
    
    assign wave_height = (wave_mult_full >>> 7);
    
    // Final Y position
    assign target_y = $signed(V_MID) + wave_height;


    // --- 7. MAIN LOGIC LOOP ---
    always @(posedge clk_i) begin
        if (rst_i) begin
            // Reset all registers to known states
            lfsr <= 16'hACE1;
            frame_counter <= 8'd0;
            blend_factor <= 8'd0;
            
            // Initialize seeds
            prev_seed <= 16'hACE1;
            next_seed <= 16'h1234;
            
            // Initialize frequencies
            stable_freq_1 <= 8'd120;
            stable_freq_2 <= 8'd140;
            current_freq_1 <= 8'd120;
            current_freq_2 <= 8'd140;
            target_freq_1 <= 8'd120;
            target_freq_2 <= 8'd140;
            
            current_amp <= 8'd100;
            target_amp <= 8'd100;
            
            prev_state <= 3'd0;
            screensaver_timer <= 24'd0;  // Reset screensaver timer
            fill_column <= 11'd0;        // Start from left
            current_hue <= 8'd0;         // Initial hue
            prev_hue <= 8'd60;           // Previous color (starts different)
            
            // Bouncing logo initialization
            logo_x <= 12'd100;           // Start near top-left
            logo_y <= 12'd100;
            logo_vx <= 3'd2;             // Moving right
            logo_vy <= 3'd1;             // Moving down
            logo_timer <= 20'd0;
            
            // Game counters
            balls_lost <= 8'd0;
            blocks_hit <= 8'd0;
            
            x_cnt <= 12'd0; y_cnt <= 12'd0;
            prev_de <= 1'b0;
            vid_rgb_d1 <= 24'h000000;
            vid_rgb_d2 <= 24'h000000;
            dvh_sync_d1 <= 3'b000;
            dvh_sync_d2 <= 3'b000;
        end
        else if (cen_i) begin
            
            // LFSR for random number generation (runs continuously)
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            
            // Screensaver column fill animation
            if (vio_state_i >= 3'd4) begin
                // In screensaver mode - fill columns left to right
                screensaver_timer <= screensaver_timer + 1;
                
                if (screensaver_timer >= COLUMN_FILL_DELAY) begin
                    screensaver_timer <= 24'd0;
                    
                    if (fill_column < NUM_COLUMNS) begin
                        // Move to next column
                        fill_column <= fill_column + 1;
                    end
                    else begin
                        // Screen filled - start over with new color
                        fill_column <= 11'd0;
                        prev_hue <= current_hue;           // Old color becomes background
                        current_hue <= current_hue + 8'd43; // New fill color (43 is prime)
                    end
                end
                
                // Bouncing logo movement (DVD-style)
                logo_timer <= logo_timer + 1;
                if (logo_timer >= LOGO_MOVE_DELAY) begin
                    logo_timer <= 20'd0;
                    
                    // Move logo and bounce off walls
                    // X axis movement
                    if (logo_vx[2]) begin  // Moving left (negative)
                        if (logo_x <= 5) begin
                            // At left edge - bounce right
                            logo_x <= 12'd0;
                            logo_vx <= 3'd2;  // Go right
                        end
                        else begin
                            logo_x <= logo_x - 12'd2;  // Move left by 2
                        end
                    end
                    else begin  // Moving right (positive)
                        if (logo_x >= (H_RES - LOGO_WIDTH - 5)) begin
                            // At right edge - bounce left
                            logo_x <= H_RES - LOGO_WIDTH;
                            logo_vx <= -3'd2;  // Go left (signed negative)
                        end
                        else begin
                            logo_x <= logo_x + 12'd2;  // Move right by 2
                        end
                    end
                    
                    // Y axis movement
                    if (logo_vy[2]) begin  // Moving up (negative)
                        if (logo_y <= 5) begin
                            // At top edge - bounce down
                            logo_y <= 12'd0;
                            logo_vy <= 3'd1;  // Go down
                        end
                        else begin
                            logo_y <= logo_y - 12'd1;  // Move up by 1
                        end
                    end
                    else begin  // Moving down (positive)
                        if (logo_y >= (V_RES - LOGO_HEIGHT - 5)) begin
                            // At bottom edge - bounce up
                            logo_y <= V_RES - LOGO_HEIGHT;
                            logo_vy <= -3'd1;  // Go up (signed negative)
                        end
                        else begin
                            logo_y <= logo_y + 12'd1;  // Move down by 1
                        end
                    end
                end
            end
            else begin
                // Not in screensaver - reset for next time
                screensaver_timer <= 24'd0;
                fill_column <= 11'd0;
                current_hue <= lfsr[7:0];  // Random starting color next time
                prev_hue <= lfsr[7:0] + 8'd60;
            end
            
            // =========== BREAKOUT GAME LOGIC (State 5) ===========
            if (vio_state_i == 3'd5) begin
                // Calculate target paddle position from VIO amplitude (0-255 -> paddle X range)
                // Map 0-255 to GAME_LEFT to GAME_RIGHT-PADDLE_WIDTH
                target_paddle_x <= GAME_LEFT + ((vio_amplitude_i * (GAME_WIDTH - PADDLE_WIDTH)) >> 8);
                
                // Smoothly move paddle toward target (reduces jitter from noisy input)
                if (paddle_x < target_paddle_x) begin
                    if (target_paddle_x - paddle_x > PADDLE_SMOOTH)
                        paddle_x <= paddle_x + PADDLE_SMOOTH;
                    else
                        paddle_x <= target_paddle_x;
                end
                else if (paddle_x > target_paddle_x) begin
                    if (paddle_x - target_paddle_x > PADDLE_SMOOTH)
                        paddle_x <= paddle_x - PADDLE_SMOOTH;
                    else
                        paddle_x <= target_paddle_x;
                end
                
                // Only run game physics if not paused
                if (!game_paused) begin
                    // Game tick counter
                    game_tick <= game_tick + 1;
                    
                    if (game_tick >= GAME_SPEED) begin
                        game_tick <= 20'd0;
                        
                        // Update ball position
                    ball_x <= ball_x + {{7{ball_vx[4]}}, ball_vx};  // Sign-extend and add
                    ball_y <= ball_y + {{7{ball_vy[4]}}, ball_vy};
                    
                    // Wall collisions - only bounce if moving toward wall
                    // Left wall
                    if (ball_x <= GAME_LEFT && ball_vx[4]) begin  // ball_vx[4] is sign bit (negative = moving left)
                        ball_x <= GAME_LEFT + 1;
                        ball_vx <= -ball_vx;
                    end
                    // Right wall
                    if (ball_x + BALL_SIZE >= GAME_RIGHT && !ball_vx[4]) begin  // positive = moving right
                        ball_x <= GAME_RIGHT - BALL_SIZE - 1;
                        ball_vx <= -ball_vx;
                    end
                    // Top wall - only bounce if moving up
                    if (ball_y <= GAME_TOP && ball_vy[4]) begin  // ball_vy[4] is sign bit (negative = moving up)
                        ball_y <= GAME_TOP + 1;
                        ball_vy <= -ball_vy;
                    end
                    // Paddle collision - only if ball is moving DOWN (vy positive, sign bit = 0)
                    if (!ball_vy[4] && ball_y + BALL_SIZE >= PADDLE_Y && ball_y + BALL_SIZE <= PADDLE_Y + PADDLE_HEIGHT) begin
                        if (ball_x + BALL_SIZE >= paddle_x && ball_x <= paddle_x + PADDLE_WIDTH) begin
                            ball_vy <= -ball_vy;
                            ball_y <= PADDLE_Y - BALL_SIZE - 1;  // Move ball above paddle
                            // Adjust X velocity based on where ball hit paddle
                            if (ball_x + (BALL_SIZE/2) < paddle_x + (PADDLE_WIDTH/3))
                                ball_vx <= -5'd3;  // Hit left third - go left
                            else if (ball_x + (BALL_SIZE/2) > paddle_x + (2*PADDLE_WIDTH/3))
                                ball_vx <= 5'd3;   // Hit right third - go right
                            // Middle third keeps current X velocity
                        end
                    end
                    
                    // Bottom (ball lost) - reset ball and increment counter
                    if (ball_y >= GAME_BOTTOM) begin
                        balls_lost <= balls_lost + 1;  // Count lost balls
                        // Check for game over (5 lives)
                        if (balls_lost >= 8'd4) begin
                            game_paused <= 1'b1;
                            game_won <= 1'b0;  // Lost
                        end
                        else begin
                            ball_x <= (GAME_LEFT + GAME_RIGHT) / 2;
                            ball_y <= PADDLE_Y - 100;
                            ball_vx <= 5'd2;
                            ball_vy <= -5'd3;
                        end
                    end
                    
                    // Block collisions with proper side detection
                    begin
                        logic [3:0] block_col, block_row;
                        logic [5:0] block_idx;
                        logic [11:0] block_left, block_right, block_top, block_bottom;
                        logic [11:0] ball_cx, ball_cy;  // Ball center
                        logic hit_from_top, hit_from_bottom, hit_from_side;
                        
                        ball_cx = ball_x + (BALL_SIZE / 2);
                        ball_cy = ball_y + (BALL_SIZE / 2);
                        
                        // Calculate which block the ball center might be in
                        if (ball_cy >= BLOCKS_TOP && ball_cy < BLOCKS_TOP + BLOCK_ROWS * BLOCK_HEIGHT) begin
                            block_row = (ball_cy - BLOCKS_TOP) / BLOCK_HEIGHT;
                            if (ball_cx >= GAME_LEFT && ball_cx < GAME_LEFT + BLOCK_COLS * BLOCK_WIDTH) begin
                                block_col = (ball_cx - GAME_LEFT) / BLOCK_WIDTH;
                                block_idx = block_row * BLOCK_COLS + block_col;
                                
                                if (block_idx < 50 && blocks_alive[block_idx]) begin
                                    // Calculate block bounds
                                    block_left = GAME_LEFT + block_col * BLOCK_WIDTH + BLOCK_GAP;
                                    block_right = block_left + BLOCK_WIDTH - 2*BLOCK_GAP;
                                    block_top = BLOCKS_TOP + block_row * BLOCK_HEIGHT + BLOCK_GAP;
                                    block_bottom = block_top + BLOCK_HEIGHT - 2*BLOCK_GAP;
                                    
                                    // Determine hit direction based on ball velocity and overlap
                                    // If moving up and hit bottom of block, or moving down and hit top
                                    hit_from_top = !ball_vy[4] && ball_y < block_top;  // Moving down, ball above block
                                    hit_from_bottom = ball_vy[4] && ball_y + BALL_SIZE > block_bottom;  // Moving up, ball below
                                    hit_from_side = !hit_from_top && !hit_from_bottom;
                                    
                                    blocks_alive[block_idx] <= 1'b0;  // Break block
                                    blocks_hit <= blocks_hit + 1;  // Count hit blocks
                                    
                                    if (hit_from_side) begin
                                        ball_vx <= -ball_vx;  // Side hit - reverse X
                                    end
                                    else begin
                                        ball_vy <= -ball_vy;  // Top/bottom hit - reverse Y
                                    end
                                    
                                    // Check for win (all 50 blocks destroyed)
                                    if (blocks_hit >= 8'd49) begin
                                        game_paused <= 1'b1;
                                        game_won <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end  // if (game_tick >= GAME_SPEED)
                end  // if (!game_paused)
            end  // if (vio_state_i == 3'd5)
            else if (prev_state == 3'd5 && vio_state_i != 3'd5) begin
                // Leaving game state - do nothing special
            end
            else if (vio_state_i != 3'd5 && prev_state != 3'd5) begin
                // Not in game - reset game state for next time
                ball_x <= (GAME_LEFT + GAME_RIGHT) / 2;
                ball_y <= PADDLE_Y - 100;
                ball_vx <= 5'd2;   // Slower ball
                ball_vy <= -5'd3;  // Slower ball
                paddle_x <= (GAME_LEFT + GAME_RIGHT - PADDLE_WIDTH) / 2;
                blocks_alive <= 50'h3FFFFFFFFFFFF;  // All 50 blocks alive
                game_tick <= 20'd0;
                balls_lost <= 8'd0;  // Reset counters
                blocks_hit <= 8'd0;
                game_paused <= 1'b0;
                game_won <= 1'b0;
            end

            // Detect state changes logic moved inside VSYNC block
            // prev_state <= vio_state_i; // REMOVED from here
            
            // SYNC & COUNTERS
            prev_de <= dvh_sync_i[2]; 
            if (dvh_sync_i[1]) begin 
                y_cnt <= 0; 
                x_cnt <= 0;
                
                // If state changed, reset everything to new base values
                if (prev_state != vio_state_i) begin
                    // Reset frequencies immediately
                    stable_freq_1 <= base_freq_1;
                    stable_freq_2 <= base_freq_2;
                    current_freq_1 <= base_freq_1;
                    current_freq_2 <= base_freq_2;
                    
                    // Reset amplitude
                    current_amp <= base_amp;
                    target_amp <= base_amp;
                    
                    // Reset seeds (start fresh)
                    prev_seed <= lfsr;
                    next_seed <= lfsr ^ 16'h5A5A;
                    blend_factor <= 8'd0;
                    
                    frame_counter <= 0;
                    
                    // Update prev_state here so the difference is detected exactly once
                    prev_state <= vio_state_i;
                end
                else begin
                    // State hasn't changed, continue animation
                    // Only update prev_state if we didn't just detecting a change (to avoid race)
                    // Actually, we just need to keep tracking it.
                    prev_state <= vio_state_i;
                    // === KEYFRAME SYSTEM: Every INTERP_FRAMES, update seeds and frequencies ===
                    if (frame_counter >= INTERP_FRAMES) begin
                        frame_counter <= 0;
                        
                        // Transition: current becomes previous, generate new target
                        prev_seed <= next_seed;
                        next_seed <= lfsr;  // New random seed for next keyframe
                        
                        // Reset blend factor (will animate 0->255 over next INTERP_FRAMES)
                        blend_factor <= 8'd0;
                        
                        // Lock in new frequencies (only change every 2 seconds)
                        if (freq_var_bits > 0) begin
                            mask_freq = (8'd1 << freq_var_bits) - 8'd1;
                            half_freq = 8'd1 << (freq_var_bits - 1);
                            rand_f1 = lfsr[5:0] & mask_freq;
                            rand_f2 = lfsr[11:6] & mask_freq;
                            
                            stable_freq_1 <= base_freq_1 + rand_f1 - half_freq;
                            stable_freq_2 <= base_freq_2 + rand_f2 - half_freq;
                        end else begin
                            stable_freq_1 <= base_freq_1;
                            stable_freq_2 <= base_freq_2;
                        end

                        // Update amplitude target
                        if (amp_var_bits > 0) begin
                            mask_amp = (8'd1 << amp_var_bits) - 8'd1;
                            half_amp = 8'd1 << (amp_var_bits - 1);
                            rand_a = lfsr[9:2] & mask_amp;
                            target_amp <= base_amp + rand_a - half_amp;
                        end else begin
                            target_amp <= base_amp;
                        end
                        
                    end else begin
                        frame_counter <= frame_counter + 1;
                        
                        // Smoothly increment blend_factor from 0 to 255 over INTERP_FRAMES
                        // This creates linear interpolation between keyframes
                        if (blend_factor < 255) begin
                            // Increment = 255 / INTERP_FRAMES ≈ 1.4 for 180 frames
                            // Use fixed increment of 2 for ~128 frame ramp (smooth)
                            blend_factor <= (blend_factor > 253) ? 8'd255 : blend_factor + 8'd2;
                        end
                    end
                    
                    // Smoothly interpolate current frequencies toward stable targets
                    if (current_freq_1 < stable_freq_1) current_freq_1 <= current_freq_1 + 1;
                    else if (current_freq_1 > stable_freq_1) current_freq_1 <= current_freq_1 - 1;
                    
                    if (current_freq_2 < stable_freq_2) current_freq_2 <= current_freq_2 + 1;
                    else if (current_freq_2 > stable_freq_2) current_freq_2 <= current_freq_2 - 1;

                    // Smoothly interpolate amplitude (faster ramp: +4 instead of +1)
                    if (current_amp < target_amp) begin
                         if (target_amp - current_amp > 4) current_amp <= current_amp + 4;
                         else current_amp <= target_amp;
                    end
                    else if (current_amp > target_amp) begin
                         if (current_amp - target_amp > 4) current_amp <= current_amp - 4;
                         else current_amp <= target_amp;
                    end
                end
            end 
            else if (dvh_sync_i[2]) begin 
                x_cnt <= x_cnt + 1; 
            end 
            else if (prev_de && !dvh_sync_i[2]) begin 
                y_cnt <= y_cnt + 1; 
                x_cnt <= 0; 
            end

            // --- DRAWING THE PIXEL ---
            // Check which mode we're in
            if (vio_state_i == 3'd5) begin
                // === BREAKOUT GAME MODE (State 5) ===
                logic draw_ball, draw_paddle, draw_block, draw_wall, in_game_area;
                logic draw_gui;
                logic [3:0] blk_col, blk_row;
                logic [5:0] blk_idx;
                logic [23:0] block_color;
                logic [11:0] abs_dx, abs_dy;
                logic [12:0] bg_dist;
                logic [7:0] bg_blue;
                
                // GUI digit rendering helpers
                logic [3:0] digit_val;
                logic [7:0] digit_x, digit_y;  // Position within digit
                logic in_digit, pixel_on;
                
                // Endgame display variables
                logic draw_endgame_box, draw_endgame_text;
                logic [11:0] box_left, box_right, box_top, box_bottom;
                logic [11:0] text_x, text_y;
                
                draw_ball = 1'b0;
                draw_paddle = 1'b0;
                draw_block = 1'b0;
                draw_wall = 1'b0;
                draw_gui = 1'b0;
                in_game_area = (x_cnt > GAME_LEFT && x_cnt < GAME_RIGHT-1 && 
                               y_cnt > GAME_TOP && y_cnt < GAME_BOTTOM);
                
                // Check if drawing ball
                if (x_cnt >= ball_x && x_cnt < ball_x + BALL_SIZE &&
                    y_cnt >= ball_y && y_cnt < ball_y + BALL_SIZE) begin
                    draw_ball = 1'b1;
                end
                
                // Check if drawing paddle
                if (x_cnt >= paddle_x && x_cnt < paddle_x + PADDLE_WIDTH &&
                    y_cnt >= PADDLE_Y && y_cnt < PADDLE_Y + PADDLE_HEIGHT) begin
                    draw_paddle = 1'b1;
                end
                
                // Check if drawing a block
                if (y_cnt >= BLOCKS_TOP && y_cnt < BLOCKS_TOP + BLOCK_ROWS * BLOCK_HEIGHT) begin
                    if (x_cnt >= GAME_LEFT && x_cnt < GAME_RIGHT) begin
                        blk_row = (y_cnt - BLOCKS_TOP) / BLOCK_HEIGHT;
                        blk_col = (x_cnt - GAME_LEFT) / BLOCK_WIDTH;
                        blk_idx = blk_row * BLOCK_COLS + blk_col;
                        
                        // Check if within block bounds (not in gap)
                        if (((x_cnt - GAME_LEFT) % BLOCK_WIDTH) >= BLOCK_GAP &&
                            ((y_cnt - BLOCKS_TOP) % BLOCK_HEIGHT) >= BLOCK_GAP) begin
                            if (blk_idx < 50 && blocks_alive[blk_idx]) begin
                                logic [7:0] local_x, local_y;
                                logic on_border;
                                
                                // Calculate position within block
                                local_x = (x_cnt - GAME_LEFT) % BLOCK_WIDTH - BLOCK_GAP;
                                local_y = (y_cnt - BLOCKS_TOP) % BLOCK_HEIGHT - BLOCK_GAP;
                                
                                // Check if on border (within BLOCK_BORDER pixels of edge)
                                on_border = (local_x < BLOCK_BORDER) || 
                                           (local_x >= BLOCK_WIDTH - BLOCK_GAP - BLOCK_BORDER) ||
                                           (local_y < BLOCK_BORDER) || 
                                           (local_y >= BLOCK_HEIGHT - BLOCK_GAP - BLOCK_BORDER);
                                
                                // Only draw the border, not the fill (hollow blocks)
                                if (on_border) begin
                                    draw_block = 1'b1;
                                    // Color based on row (rainbow rows)
                                    case (blk_row)
                                        4'd0: block_color = 24'hFF4444;  // Red
                                        4'd1: block_color = 24'hFFAA00;  // Orange
                                        4'd2: block_color = 24'hFFFF00;  // Yellow
                                        4'd3: block_color = 24'h44FF44;  // Green
                                        4'd4: block_color = 24'h4444FF;  // Blue
                                        default: block_color = 24'hFFFFFF;
                                    endcase
                                end
                            end
                        end
                    end
                end
                
                // Simple GUI: Show "LOST: X" on left, "HIT: X" on right using boxes
                // Left side GUI area (x: 20-140, y: 30-70)
                if (x_cnt >= 20 && x_cnt < 140 && y_cnt >= 30 && y_cnt < 70) begin
                    // Draw balls_lost as simple filled rectangles (1 per lost ball, max 10)
                    digit_x = x_cnt - 20;
                    if (digit_x < balls_lost * 12 && digit_x % 12 < 10) begin
                        draw_gui = 1'b1;
                    end
                end
                
                // Right side GUI area (x: 1780-1900, y: 30-70)
                if (x_cnt >= 1780 && x_cnt < 1900 && y_cnt >= 30 && y_cnt < 70) begin
                    // Draw blocks_hit as simple filled rectangles
                    digit_x = x_cnt - 1780;
                    if (digit_x < (blocks_hit > 99 ? 99 : blocks_hit) && (digit_x % 2 == 0)) begin
                        draw_gui = 1'b1;
                    end
                end
                
                // Game over / You win display (centered box)
                draw_endgame_box = 1'b0;
                draw_endgame_text = 1'b0;
                
                // Box dimensions: 600x200, centered
                box_left = (H_RES - 600) / 2;
                box_right = box_left + 600;
                box_top = (V_RES - 200) / 2;
                box_bottom = box_top + 200;
                
                if (game_paused) begin
                    if (x_cnt >= box_left && x_cnt < box_right &&
                        y_cnt >= box_top && y_cnt < box_bottom) begin
                        // Border (15px thick)
                        if (x_cnt < box_left + 15 || x_cnt >= box_right - 15 ||
                            y_cnt < box_top + 15 || y_cnt >= box_bottom - 15) begin
                            draw_endgame_box = 1'b1;
                        end
                        else begin
                            // Inner area = 570 x 170, centered text
                            text_x = x_cnt - box_left - 15;
                            text_y = y_cnt - box_top - 15;
                            // Draw large text indicators
                            if (game_won) begin
                                // Three tall vertical bars for WIN (spread across 570px)
                                // Bar 1: 80-130, Bar 2: 255-305, Bar 3: 430-480
                                if (((text_x >= 80 && text_x < 130) ||
                                     (text_x >= 255 && text_x < 305) ||
                                     (text_x >= 430 && text_x < 480)) &&
                                    (text_y >= 30 && text_y < 140)) begin
                                    draw_endgame_text = 1'b1;
                                end
                            end
                            else begin
                                // Large horizontal bar across middle for LOSE
                                if (text_x >= 50 && text_x < 520 &&
                                    text_y >= 65 && text_y < 105) begin
                                    draw_endgame_text = 1'b1;
                                end
                            end
                        end
                    end
                end
                
                // Draw priority: EndGame > Ball > Paddle > Blocks > GUI > Background
                if (draw_endgame_box) begin
                    vid_rgb_d1 <= game_won ? 24'h00FF00 : 24'hFF0000;  // Green for win, red for lose
                end
                else if (draw_endgame_text) begin
                    vid_rgb_d1 <= 24'hFFFFFF;  // White text
                end
                else if (draw_ball) begin
                    vid_rgb_d1 <= 24'hFFFFFF;  // White ball
                end
                else if (draw_paddle) begin
                    vid_rgb_d1 <= 24'h00CCFF;  // Cyan paddle
                end
                else if (draw_block) begin
                    vid_rgb_d1 <= block_color;
                end
                else if (draw_gui) begin
                    vid_rgb_d1 <= 24'hFF6600;  // Orange GUI elements
                end
                else if (!in_game_area) begin
                    // Outside game area = black
                    vid_rgb_d1 <= 24'h000000;
                end
                else begin
                    // Inside game area: Radial gradient background
                    abs_dx = (x_cnt > H_CENTER) ? (x_cnt - H_CENTER) : (H_CENTER - x_cnt);
                    abs_dy = (y_cnt > V_CENTER) ? (y_cnt - V_CENTER) : (V_CENTER - y_cnt);
                    bg_dist = abs_dx + abs_dy;
                    // Match main screen gradient: max 48, bits [10:5]
                    bg_blue = (bg_dist > 13'd1536) ? 8'd48 : bg_dist[10:5];
                    
                    // Grid lines on top of gradient (same as main screen)
                    if ((x_cnt % GRID_SPACING == 0) || (y_cnt % GRID_SPACING == 0)) begin
                        vid_rgb_d1 <= {8'h00, 8'h10, bg_blue + 8'd24};
                    end
                    else begin
                        vid_rgb_d1 <= {8'h00, 8'h00, bg_blue};
                    end
                end
            end
            else if (vio_state_i == 3'd4) begin
                // === SCREENSAVER MODE (State 4) ===
                logic [10:0] pixel_column;   // Which 2px column is this pixel in
                logic [23:0] base_curr, base_prev;  // Base saturated colors
                logic [23:0] dark_curr, dark_prev;  // Dark muted versions
                logic [23:0] blended_color;         // Fade-wipe result
                logic [7:0]  blend_t;               // Blend factor 0-255
                logic signed [11:0] dist_from_edge; // Distance from fill edge
                
                // Logo lookup variables (using dynamic bouncing position)
                logic in_logo_bounds;
                logic [11:0] logo_local_x, logo_local_y;
                logic [15:0] logo_byte_addr;
                logic [7:0]  logo_byte;
                logic [2:0]  logo_bit_idx;
                logic        logo_pixel;
                
                // Fade zone width in 2px columns
                localparam FADE_ZONE = 30;  // 60 pixels fade zone
                
                // Calculate which column we're in
                pixel_column = x_cnt / COLUMN_WIDTH;
                
                // Check if we're within logo bounds (using DYNAMIC logo_x, logo_y)
                in_logo_bounds = (x_cnt >= logo_x) && (x_cnt < logo_x + LOGO_WIDTH) &&
                                 (y_cnt >= logo_y) && (y_cnt < logo_y + LOGO_HEIGHT);
                
                // Calculate logo local coordinates
                logo_local_x = x_cnt - logo_x;
                logo_local_y = y_cnt - logo_y;
                
                // Calculate byte address and bit index within byte
                logo_byte_addr = logo_local_y * LOGO_BYTES_PER_ROW + (logo_local_x >> 3);
                logo_bit_idx = 3'd7 - logo_local_x[2:0];  // MSB first
                
                // Read logo pixel from ROM
                logo_byte = logo_rom[logo_byte_addr];
                logo_pixel = logo_byte[logo_bit_idx];
                
                // Get base colors from hues
                base_curr = hue_to_rgb(current_hue);
                base_prev = hue_to_rgb(prev_hue);
                
                // Create VERY dark muted colors: (color / 8) for subtle, moody look
                dark_curr = {
                    3'b000, base_curr[23:19], // R: 1/8
                    3'b000, base_curr[15:11], // G: 1/8
                    3'b000, base_curr[7:3]    // B: 1/8
                };
                
                dark_prev = {
                    3'b000, base_prev[23:19], // R: 1/8
                    3'b000, base_prev[15:11], // G: 1/8
                    3'b000, base_prev[7:3]    // B: 1/8
                };
                
                // Calculate distance from fill edge for fade-wipe
                dist_from_edge = $signed({1'b0, fill_column}) - $signed({1'b0, pixel_column});
                
                // Determine blend factor based on distance from edge
                if (dist_from_edge >= FADE_ZONE) begin
                    // Fully in new color zone
                    blend_t = 8'd255;
                end
                else if (dist_from_edge <= 0) begin
                    // Fully in old color zone
                    blend_t = 8'd0;
                end
                else begin
                    // In fade zone - linear interpolation
                    blend_t = (dist_from_edge * 255) / FADE_ZONE;
                end
                
                // Blend colors: result = prev + (curr - prev) * blend_t / 256
                blended_color = {
                    dark_prev[23:16] + (((dark_curr[23:16] - dark_prev[23:16]) * blend_t) >> 8),
                    dark_prev[15:8]  + (((dark_curr[15:8]  - dark_prev[15:8])  * blend_t) >> 8),
                    dark_prev[7:0]   + (((dark_curr[7:0]   - dark_prev[7:0])   * blend_t) >> 8)
                };
                
                // Display: logo (white) takes priority over background
                if (in_logo_bounds && logo_pixel) begin
                    vid_rgb_d1 <= 24'hFFFFFF;  // Solid white logo
                end
                else begin
                    vid_rgb_d1 <= blended_color;
                end
            end
            else if ( (y_cnt >= (target_y - (LINE_THICKNESS>>1))) && 
                 (y_cnt <  (target_y + (LINE_THICKNESS>>1))) ) 
            begin
                vid_rgb_d1 <= state_color;
            end 
            else begin
                // --- RADIAL GRADIENT BACKGROUND ---
                // Calculate distance from center (Manhattan distance for simplicity)
                logic [11:0] abs_dx, abs_dy;
                logic [12:0] manhattan_dist;
                logic [7:0] gradient_blue;
                
                // Compute absolute distances from center
                abs_dx = (x_cnt > H_CENTER) ? (x_cnt - H_CENTER) : (H_CENTER - x_cnt);
                abs_dy = (y_cnt > V_CENTER) ? (y_cnt - V_CENTER) : (V_CENTER - y_cnt);
                
                // Manhattan distance (simple, hardware-friendly)
                manhattan_dist = abs_dx + abs_dy;
                
                // Map distance to blue intensity (0 at center, ~48 at edges)
                // Max manhattan dist = 960 + 540 = 1500, divide by 32 gives ~47
                gradient_blue = (manhattan_dist > 1536) ? 8'd48 : manhattan_dist[10:5];
                
                // Grid lines on top of gradient
                if ((x_cnt % GRID_SPACING == 0) || (y_cnt % GRID_SPACING == 0)) begin
                    // Grid is slightly brighter than gradient
                    vid_rgb_d1 <= {8'h00, 8'h10, gradient_blue + 8'd24};
                end
                else begin
                    // Radial gradient: black center fading to dark blue edges
                    vid_rgb_d1 <= {8'h00, 8'h00, gradient_blue};
                end
            end

            dvh_sync_d1 <= dvh_sync_i;
            
            // Second pipeline stage (2-flop delay)
            vid_rgb_d2 <= vid_rgb_d1;
            dvh_sync_d2 <= dvh_sync_d1;
        end
    end

    // assign dvh_sync_o  = dvh_sync_d2;  // Output from 2nd stage
    
    assign dvh_sync_o  = dvh_sync_i;  // Output from 2nd stage

    assign vid_rgb_o   = vid_rgb_d2;   // Output from 2nd stage

endmodule