
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROBES.FILE {C:/Users/dagab/Desktop/KAREN/uOttaHack_FPGA/fpga_top/fpga_top.runs/impl_1/fpga_top.ltx} [current_hw_device]
set_property FULL_PROBES.FILE {C:/Users/dagab/Desktop/KAREN/uOttaHack_FPGA/fpga_top/fpga_top.runs/impl_1/fpga_top.ltx} [current_hw_device]
refresh_hw_device [current_hw_device]

set vios [get_hw_vios]
foreach vio $vios {
    set probes [get_hw_probes -of_objects $vio]
    foreach p $probes {
        set pname [get_property NAME $p]
        if {[string match "*state*" $pname]} {
            set_property OUTPUT_VALUE 0 $p
            commit_hw_vio $p
            puts "State set to 0"
        }
    }
}

close_hw_target
close_hw_manager
