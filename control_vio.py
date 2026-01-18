#!/usr/bin/env python3
"""
KAREN VIO Controller - Python Script
Controls the FPGA waveform via Vivado's hw_server
"""

import subprocess
import sys
import time

class VivadoVIOController:
    def __init__(self):
        self.vivado_path = "C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"
        
    def send_tcl_command(self, tcl_code):
        """Execute a TCL command via Vivado batch mode"""
        cmd = [
            self.vivado_path,
            "-mode", "batch",
            "-source", "control_vio_cmd.tcl"
        ]
        
        # Write TCL to temp file
        with open("control_vio_cmd.tcl", "w") as f:
            f.write(tcl_code)
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.stdout, result.stderr
    
    def set_state(self, state_value):
        """Set the state (0=Idle, 1=Listen, 2=Neutral, 3=Angry)"""
        tcl = f"""
        open_hw_manager
        connect_hw_server -url localhost:3121
        current_hw_target [lindex [get_hw_targets] 0]
        open_hw_target
        current_hw_device [lindex [get_hw_devices] 0]
        refresh_hw_device [current_hw_device]
        
        set vio [lindex [get_hw_vios] 0]
        set_property OUTPUT_VALUE {state_value} [get_hw_probes probe_out1 -of_objects $vio]
        commit_hw_vio $vio
        
        close_hw_target
        close_hw_manager
        """
        print(f"Setting state to {state_value}...")
        stdout, stderr = self.send_tcl_command(tcl)
        if "ERROR" in stderr:
            print(f"Error: {stderr}")
        else:
            print(f"✓ State set to {state_value}")
    
    def set_amplitude(self, amp_value):
        """Set the amplitude (0-255)"""
        tcl = f"""
        open_hw_manager
        connect_hw_server -url localhost:3121
        current_hw_target [lindex [get_hw_targets] 0]
        open_hw_target
        current_hw_device [lindex [get_hw_devices] 0]
        refresh_hw_device [current_hw_device]
        
        set vio [lindex [get_hw_vios] 0]
        set_property OUTPUT_VALUE {amp_value} [get_hw_probes probe_out0 -of_objects $vio]
        commit_hw_vio $vio
        
        close_hw_target
        close_hw_manager
        """
        print(f"Setting amplitude to {amp_value}...")
        stdout, stderr = self.send_tcl_command(tcl)
        if "ERROR" in stderr:
            print(f"Error: {stderr}")
        else:
            print(f"✓ Amplitude set to {amp_value}")

def main():
    controller = VivadoVIOController()
    
    print("=" * 50)
    print("    KAREN VIO CONTROLLER (Python)")
    print("=" * 50)
    print("\nCommands:")
    print("  s <0-3>    : Set state")
    print("  a <0-255>  : Set amplitude")
    print("  q          : Quit")
    print()
    
    while True:
        try:
            cmd = input("> ").strip().split()
            if not cmd:
                continue
                
            if cmd[0] in ['q', 'quit', 'exit']:
                break
            elif cmd[0] == 's':
                state = int(cmd[1]) if len(cmd) > 1 else int(input("State (0-3): "))
                controller.set_state(state)
            elif cmd[0] == 'a':
                amp = int(cmd[1]) if len(cmd) > 1 else int(input("Amplitude (0-255): "))
                controller.set_amplitude(amp)
            else:
                print("Unknown command")
        except (ValueError, IndexError) as e:
            print(f"Invalid input: {e}")
        except KeyboardInterrupt:
            print("\nExiting...")
            break

if __name__ == "__main__":
    main()
