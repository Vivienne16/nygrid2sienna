"""
Utility functions for comparing baseline and MER systems.

This script provides functions to load and compare baseline systems
with MER-modified systems, highlighting the differences in load profiles
and system characteristics.
"""

using PowerSystems
using DataFrames
using CSV
using Statistics
using Plots
using TimeSeries

const PSY = PowerSystems

"""
Load and compare two power systems (baseline vs MER).
"""
function compare_systems(baseline_file, mer_file)
    println("="^80)
    println("COMPARING BASELINE AND MER SYSTEMS")
    println("="^80)
    
    # Load systems
    println("Loading systems...")
    baseline_sys = PSY.System(baseline_file)
    mer_sys = PSY.System(mer_file)
    
    # Get basic system info
    baseline_info = get_system_info(baseline_sys, "Baseline")
    mer_info = get_system_info(mer_sys, "MER Modified")
    
    # Compare system components
    compare_system_components(baseline_info, mer_info)
    
    # Compare load profiles
    compare_load_profiles(baseline_sys, mer_sys)
    
    return baseline_sys, mer_sys
end

"""
Get basic information about a power system.
"""
function get_system_info(sys, system_name)
    info = Dict()
    info["name"] = system_name
    info["buses"] = length(get_components(PSY.Bus, sys))
    info["loads"] = length(get_components(PSY.StandardLoad, sys))
    info["thermal_gens"] = length(get_components(PSY.ThermalStandard, sys))
    info["renewable_gens"] = length(get_components(PSY.RenewableDispatch, sys)) + 
                            length(get_components(PSY.RenewableNonDispatch, sys))
    info["storage"] = length(get_components(PSY.GenericBattery, sys))
    info["total_gens"] = length(get_components(PSY.Generator, sys))
    
    # Calculate total installed capacity
    info["total_capacity"] = sum([PSY.get_max_active_power(g) for g in get_components(PSY.Generator, sys)])
    
    return info
end

"""
Compare components between two systems.
"""
function compare_system_components(baseline_info, mer_info)
    println("\nSYSTEM COMPONENT COMPARISON")
    println("-"^50)
    println("Component Type    | Baseline | MER Modified | Difference")
    println("-"^50)
    
    components = ["buses", "loads", "thermal_gens", "renewable_gens", "storage", "total_gens"]
    component_names = ["Buses", "Loads", "Thermal Gens", "Renewable Gens", "Storage", "Total Gens"]
    
    for (comp, name) in zip(components, component_names)
        baseline_val = baseline_info[comp]
        mer_val = mer_info[comp]
        diff = mer_val - baseline_val
        diff_str = diff == 0 ? "Same" : string(diff)
        println("$(rpad(name, 17)) | $(lpad(baseline_val, 8)) | $(lpad(mer_val, 12)) | $(lpad(diff_str, 10))")
    end
    
    # Compare total capacity
    baseline_cap = round(baseline_info["total_capacity"], digits=2)
    mer_cap = round(mer_info["total_capacity"], digits=2)
    cap_diff = round(mer_cap - baseline_cap, digits=2)
    cap_diff_str = cap_diff == 0.0 ? "Same" : string(cap_diff)
    println("$(rpad("Total Capacity", 17)) | $(lpad(baseline_cap, 8)) | $(lpad(mer_cap, 12)) | $(lpad(cap_diff_str, 10))")
end

"""
Compare load profiles between baseline and MER systems.
"""
function compare_load_profiles(baseline_sys, mer_sys)
    println("\n\nLOAD PROFILE COMPARISON")
    println("-"^50)
    
    # Get all loads from both systems
    baseline_loads = get_components(PSY.StandardLoad, baseline_sys)
    mer_loads = get_components(PSY.StandardLoad, mer_sys)
    
    println("Total loads in baseline system: $(length(baseline_loads))")
    println("Total loads in MER system: $(length(mer_loads))")
    
    # Compare load magnitudes for each bus
    load_differences = []
    
    for baseline_load in baseline_loads
        load_name = PSY.get_name(baseline_load)
        
        # Find corresponding load in MER system
        mer_load = nothing
        for ml in mer_loads
            if PSY.get_name(ml) == load_name
                mer_load = ml
                break
            end
        end
        
        if mer_load !== nothing
            baseline_ts = PSY.get_time_series_array(PSY.SingleTimeSeries, baseline_load, "max_active_power")
            mer_ts = PSY.get_time_series_array(PSY.SingleTimeSeries, mer_load, "max_active_power")
            
            # Calculate differences
            diff_ts = mer_ts - baseline_ts
            max_diff = maximum(diff_ts)
            total_diff = sum(diff_ts)
            
            if max_diff > 0.001  # Only report if there's a significant difference
                push!(load_differences, (name=load_name, max_diff=max_diff, total_diff=total_diff))
            end
        end
    end
    
    # Report differences
    if isempty(load_differences)
        println("No significant differences found in load profiles.")
    else
        println("\nLoad differences found:")
        println("Load Name | Max Hourly Diff | Total Diff")
        println("-"^40)
        for diff in load_differences
            println("$(rpad(diff.name, 9)) | $(lpad(round(diff.max_diff, digits=3), 15)) | $(lpad(round(diff.total_diff, digits=2), 10))")
        end
    end
end

"""
Create a summary report comparing systems.
"""
function create_comparison_report(baseline_file, mer_file, output_file="system_comparison_report.txt")
    # Redirect output to file
    open(output_file, "w") do f
        redirect_stdout(f) do
            compare_systems(baseline_file, mer_file)
        end
    end
    
    println("Comparison report saved to: $output_file")
    
    # Also display summary on screen
    baseline_sys = PSY.System(baseline_file)
    mer_sys = PSY.System(mer_file)
    
    baseline_loads = length(get_components(PSY.StandardLoad, baseline_sys))
    mer_loads = length(get_components(PSY.StandardLoad, mer_sys))
    
    println("\nQUICK COMPARISON SUMMARY:")
    println("Baseline file: $baseline_file")
    println("MER file: $mer_file")
    println("Load count - Baseline: $baseline_loads, MER: $mer_loads")
    println("Detailed report: $output_file")
end

"""
Example usage function.
"""
function run_comparison_example()
    println("="^80)
    println("SYSTEM COMPARISON EXAMPLE")
    println("="^80)
    
    # Example file names (adjust these to your actual files)
    baseline_file = "baseline_nys2030_2019.json"
    mer_file = "mer_hourly_12_nys2030_2019.json"
    
    if isfile(baseline_file) && isfile(mer_file)
        println("Found both system files, running comparison...")
        baseline_sys, mer_sys = compare_systems(baseline_file, mer_file)
        
        # Create detailed report
        create_comparison_report(baseline_file, mer_file)
        
    else
        println("System files not found. Expected files:")
        println("- $baseline_file")
        println("- $mer_file")
        println()
        println("Please create these systems first using:")
        println("1. include(\"src/create_baseline_system.jl\")")
        println("2. create_baseline_system()")
        println("3. include(\"src/create_hourly_mer_systems.jl\")")
        println("4. create_system_with_hourly_mer(12)")
    end
end

# Example usage when run directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_comparison_example()
end