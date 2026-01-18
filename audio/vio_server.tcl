# ----------------------------------------------------------------------------
# KAREN VIO Server - Persistent Connection
# Watches a command file and executes VIO changes instantly
# Usage: vivado -mode tcl -source vio_server.tcl
# ----------------------------------------------------------------------------

set COMMAND_FILE "C:/Users/ming8/Desktop/UOT8/audio/vio_command.txt"
set LTX_FILE "C:/Users/ming8/Desktop/UOT8/fpga_top/fpga_top.runs/impl_1/fpga_top.ltx"

# Connect to hardware
proc connect_hardware {} {
    global LTX_FILE
    
    puts "Connecting to Hardware Manager..."
    open_hw_manager
    connect_hw_server -url localhost:3121
    
    set targets [get_hw_targets]
    if {[llength $targets] == 0} {
        puts "ERROR: No hardware targets found."
        return 0
    }
    
    current_hw_target [lindex $targets 0]
    open_hw_target
    
    set devices [get_hw_devices]
    if {[llength $devices] == 0} {
        puts "ERROR: No devices found."
        return 0
    }
    
    current_hw_device [lindex $devices 0]
    
    # Load probes
    if {[file exists $LTX_FILE]} {
        puts "Loading probes from: $LTX_FILE"
        set_property PROBES.FILE $LTX_FILE [current_hw_device]
        set_property FULL_PROBES.FILE $LTX_FILE [current_hw_device]
    }
    
    refresh_hw_device [current_hw_device]
    
    puts "Hardware connected successfully!"
    return 1
}

# Find our probes
proc find_probes {} {
    global p_state p_amp p_emotion
    
    set p_state ""
    set p_amp ""
    set p_emotion ""
    
    set vios [get_hw_vios]
    puts "Found [llength $vios] VIO cores"
    
    foreach vio $vios {
        set probes [get_hw_probes -of_objects $vio]
        foreach p $probes {
            set pname [get_property NAME $p]
            if {[string match "*state*" $pname]} {
                set p_state $p
                puts "Found state probe: $p"
            }
            if {[string match "*amplitude*" $pname]} {
                set p_amp $p
                puts "Found amplitude probe: $p"
            }
            if {[string match "*emotion*" $pname]} {
                set p_emotion $p
                puts "Found emotion probe: $p"
            }
        }
    }
    
    if {$p_state == "" || $p_amp == ""} {
        puts "WARNING: Could not find state and amplitude probes!"
        return 0
    }
    return 1
}

# Set state value
proc set_vio_state {value} {
    global p_state
    if {$p_state != ""} {
        # Format value as single hex digit (0-3)
        set hex_value [format "%X" $value]
        set_property OUTPUT_VALUE $hex_value $p_state
        commit_hw_vio $p_state
        puts "State -> $value (0x$hex_value)"
    }
}

# Set amplitude value
proc set_vio_amplitude {value} {
    global p_amp
    if {$p_amp != ""} {
        # Format value as 2-digit hex (0-255)
        set hex_value [format "%02X" $value]
        set_property OUTPUT_VALUE $hex_value $p_amp
        commit_hw_vio $p_amp
        puts "Amplitude -> $value (0x$hex_value)"
    }
}

# Set emotion value
proc set_vio_emotion {value} {
    global p_emotion
    if {$p_emotion != ""} {
        # Format value as single hex digit (0-1)
        set hex_value [format "%X" $value]
        set_property OUTPUT_VALUE $hex_value $p_emotion
        commit_hw_vio $p_emotion
        puts "Emotion -> $value (0x$hex_value)"
    } else {
        puts "Emotion probe not found, skipping..."
    }
}

# Main server loop
proc run_server {} {
    global COMMAND_FILE p_state p_amp p_emotion
    
    puts ""
    puts "========================================"
    puts "   KAREN VIO SERVER - PERSISTENT MODE"
    puts "========================================"
    puts "Watching: $COMMAND_FILE"
    puts "Commands: state <0-3>, amp <0-255>, emotion <0-1>"
    puts "Write 'quit' to exit"
    puts "========================================"
    puts ""
    
    # Create empty command file
    set f [open $COMMAND_FILE w]
    close $f
    
    set last_cmd ""
    
    while {1} {
        # Check if file exists and has content
        if {[file exists $COMMAND_FILE]} {
            set f [open $COMMAND_FILE r]
            set cmd [string trim [read $f]]
            close $f
            
            # Only process if command changed
            if {$cmd != "" && $cmd != $last_cmd} {
                set last_cmd $cmd
                
                # Parse command
                set parts [split $cmd " "]
                set action [lindex $parts 0]
                set value [lindex $parts 1]
                
                if {$action == "quit" || $action == "exit"} {
                    puts "Shutting down server..."
                    break
                } elseif {$action == "state" || $action == "s"} {
                    set_vio_state $value
                } elseif {$action == "amp" || $action == "amplitude" || $action == "a"} {
                    set_vio_amplitude $value
                } elseif {$action == "emotion" || $action == "e"} {
                    set_vio_emotion $value
                } else {
                    puts "Unknown command: $cmd"
                }
                
                # Clear the file after processing
                set f [open $COMMAND_FILE w]
                close $f
            }
        }
        
        # Small delay to avoid busy-waiting (50ms)
        after 50
    }
    
    # Cleanup
    close_hw_target
    close_hw_manager
    puts "Server stopped."
}

# Main entry point
if {[connect_hardware]} {
    if {[find_probes]} {
        run_server
    } else {
        puts "Failed to find probes. Exiting."
    }
} else {
    puts "Failed to connect to hardware. Exiting."
}
