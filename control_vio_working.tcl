
# ----------------------------------------------------------------------------
# KAREN VIO Controller Script - WORKING VERSION
# Usage: vivado -mode tcl -source control_vio_working.tcl
# ----------------------------------------------------------------------------

proc connect_board {} {
    puts "Connecting to Hardware Manager..."
    open_hw_manager
    connect_hw_server -url localhost:3121
    
    set targets [get_hw_targets]
    if {[llength $targets] == 0} {
        puts "Error: No hardware targets found. Check USB connection."
        return 0
    }
    
    set target_0 [lindex $targets 0]
    puts "Opening target: $target_0"
    current_hw_target $target_0
    open_hw_target
    
    set devices [get_hw_devices]
    if {[llength $devices] == 0} {
        puts "Error: No devices found on target."
        return 0
    }
    
    set dev_0 [lindex $devices 0]
    puts "Refreshing device: $dev_0"
    current_hw_device $dev_0
    
    # Load the LTX file with the correct path
    set ltx_file "C:/Users/dagab/Desktop/KAREN/uOttaHack_FPGA/fpga_top/fpga_top.runs/impl_1/fpga_top.ltx"
    
    if {[file exists $ltx_file]} {
        puts "Loading probes from: $ltx_file"
        set_property PROBES.FILE $ltx_file $dev_0
        set_property FULL_PROBES.FILE $ltx_file $dev_0
        refresh_hw_device $dev_0
    } else {
        puts "ERROR: LTX file not found at $ltx_file"
        return 0
    }
    
    return 1
}

proc main {} {
    if {![connect_board]} { return }

    puts ""
    puts "========================================"
    puts "       KAREN VIO CONTROLLER"
    puts "========================================"
    puts ""

    # Get VIO cores
    set vios [get_hw_vios]
    puts "Found [llength $vios] VIO cores:"
    foreach vio $vios {
        puts "  - $vio"
    }
    
    # Try each VIO to find the one with our probes
    set target_vio ""
    set p_amp ""
    set p_state ""
    
    foreach vio $vios {
        puts "\nChecking VIO: $vio"
        set all_probes [get_hw_probes -of_objects $vio]
        puts "  Probes found: [llength $all_probes]"
        
        foreach p $all_probes {
            set pname [get_property NAME $p]
            puts "    - $pname"
            
            if {[string match "*amplitude*" $pname]} {
                set p_amp $p
                set target_vio $vio
            } elseif {[string match "*state*" $pname]} {
                set p_state $p
                set target_vio $vio
            }
        }
        
        # If we found both probes, use this VIO
        if {$p_amp != "" && $p_state != ""} {
            break
        }
    }
    
    if {$target_vio == ""} {
        puts "\nERROR: Could not find VIO with amplitude/state probes!"
        puts "Available VIOs: $vios"
        return
    }
    
    puts "\n========================================"
    puts "Using VIO: $target_vio"
    puts "Amplitude probe: $p_amp"
    puts "State probe: $p_state"
    
    puts "\n========================================"
    puts "Commands:"
    puts "  s <0-3>    : Set state (0=Idle, 1=Listen, 2=Neutral, 3=Angry)"
    puts "  a <0-255>  : Set amplitude (0-255)"
    puts "  r          : Read current values"
    puts "  q          : Quit"
    puts "========================================\n"
    
    while {1} {
        puts -nonewline "> "
        flush stdout
        
        if {[gets stdin line] < 0} { break }
        
        set parts [split $line " "]
        set cmd [lindex $parts 0]
        set arg [lindex $parts 1]

        if {$cmd == "q" || $cmd == "quit" || $cmd == "exit"} {
            break
        } elseif {$cmd == "s"} {
            if {$arg == ""} {
                puts -nonewline "Enter State (0=Idle, 1=Listen, 2=Neutral, 3=Angry): "
                flush stdout
                gets stdin arg
            }
            
            set_property OUTPUT_VALUE $arg $p_state
            commit_hw_vio $p_state
            puts "State set to $arg"
            
        } elseif {$cmd == "a"} {
            if {$arg == ""} {
                puts -nonewline "Enter Amplitude (0-255): "
                flush stdout
                gets stdin arg
            }
            
            set_property OUTPUT_VALUE $arg $p_amp
            commit_hw_vio $p_amp
            puts "Amplitude set to $arg"
            
        } elseif {$cmd == "r"} {
            refresh_hw_vio -update_output_values $target_vio
            set curr_amp [get_property OUTPUT_VALUE $p_amp]
            set curr_state [get_property OUTPUT_VALUE $p_state]
            puts "Current Amplitude: $curr_amp"
            puts "Current State: $curr_state"
            
        } else {
            puts "Unknown command. Try: 's 1' or 'a 128'"
        }
    }

    puts "\nClosing connection..."
    close_hw_target
    close_hw_manager
    puts "Done!"
}

main
