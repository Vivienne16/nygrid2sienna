"""
Batch simulation script for 24 hourly systems.

This script runs power system simulations for all 24 hourly systems
created by create_hourly_mer_systems.jl. Each system has different
load patterns for specific hours of every day.

The script will:
1. Find all hourly system files
2. Run simulation for each system
3. Save results with hour-specific naming
4. Generate summary statistics
"""

using Revise
using PowerSimulations
using Dates
using Logging
using PowerGraphics
using PowerSystems
using TimeSeries
using JuMP
using HiGHS
using StorageSystemsSimulations
using HydroPowerSimulations
using DataFrames
using CSV
using Glob

# Set up constants
const PSI = PowerSimulations
const PSY = PowerSystems
const PG = PowerGraphics
const SSS = StorageSystemsSimulations

# Include utility scripts
include("parsing_utils.jl")
include("post_process.jl")

# Simulation configuration
load_year = 2019
base_output_dir = "HourlySimulations"
interval = 24
horizon = 24
steps = 1

# Solver configuration
solver = optimizer_with_attributes(
    HiGHS.Optimizer,
    "time_limit" => 600.0,     # 10 minutes max per simulation
    "log_to_console" => true,  
    "mip_abs_gap" => 5e-3,      
)

function find_hourly_systems()
    """Find all hourly system JSON files."""
    pattern = "mer_hourly_*_nys2030_$(load_year).json"
    files = glob(pattern, ".")
    
    println("Debug: Looking for pattern: $pattern")
    println("Debug: Found $(length(files)) files:")
    for file in files
        println("  - $file")
    end
    
    # Extract hour numbers and sort
    system_files = []
    for file in files
        # Extract hour from filename (e.g., "mer_hourly_15_nys2030_2019.json" -> 15)
        # Create the regex pattern with proper interpolation
        regex_pattern = Regex("mer_hourly_(\\d+)_nys2030_$(load_year)\\.json")
        match_result = match(regex_pattern, file)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            push!(system_files, (hour=hour, filename=file))
            println("Debug: Matched hour $hour from file: $file")
        else
            println("Debug: No match for file: $file")
        end
    end
    
    # Sort by hour
    sort!(system_files, by=x -> x.hour)
    
    return system_files
end

function setup_simulation_template(sys)
    """Set up the simulation template for a given system."""
    
    # Add reserves to the system
    add_reserves(sys; reg_reserve_frac=0.05, spinning_reserve_frac=0.1)
    
    # Transform time series data
    PSY.transform_single_time_series!(sys, Hour(horizon), Hour(interval))
    
    # Create unit commitment template
    template_uc = PSI.template_unit_commitment(; 
        network=NetworkModel(PSI.DCPPowerModel, use_slacks=true, PTDF_matrix=PTDF(sys))
    )
    
    # Set device models
    set_device_model!(template_uc, DeviceModel(ThermalStandard, ThermalDispatchNoMin))
    set_device_model!(template_uc, StandardLoad, StaticPowerLoad)
    set_device_model!(template_uc, DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves))
    set_device_model!(template_uc, DeviceModel(Transformer2W, StaticBranch; use_slacks=true))
    set_device_model!(template_uc, DeviceModel(Line, StaticBranch; use_slacks=true))
    set_device_model!(template_uc, TwoTerminalHVDCLine, HVDCTwoTerminalLossless)
    set_device_model!(template_uc, RenewableNonDispatch, FixedOutput)
    set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template_uc, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template_uc, ServiceModel(TransmissionInterface, ConstantMaxInterfaceFlow))
    
    return template_uc
end

function run_simulation_for_hour(hour, filename, output_dir)
    """Run simulation for a specific hour's system."""
    
    println("\\n" * "="^60)
    println("RUNNING SIMULATION FOR HOUR $hour")
    println("System file: $filename")
    println("="^60)
    
    try
        # Load system
        println("Loading system...")
        sys = System(filename)
        
        # Verify system loaded correctly
        num_buses = length(get_components(Bus, sys))
        num_loads = length(get_components(StandardLoad, sys))
        num_generators = length(get_components(Generator, sys))
        
        println("System loaded successfully:")
        println("  - Buses: $num_buses")
        println("  - Loads: $num_loads")
        println("  - Generators: $num_generators")
        
        # Setup simulation template
        println("Setting up simulation template...")
        template_uc = setup_simulation_template(sys)
        
        # Create simulation models
        models = SimulationModels(
            decision_models=[
                DecisionModel(
                    template_uc,
                    sys,
                    name="UC",
                    optimizer=solver,
                    initialize_model=false,
                    optimizer_solve_log_print=true,
                    check_numerical_bounds=true,
                    warm_start=true,
                    store_variable_names=true,
                ),
            ],
        )
        
        # Create simulation sequence
        sequence = SimulationSequence(models=models, ini_cond_chronology=InterProblemChronology())
        
        # Create simulation object
        sim_name = "hour_$(hour)_simulation"
        sim = Simulation(
            name=sim_name,
            steps=steps,
            models=models,
            sequence=sequence,
            simulation_folder=output_dir,
        )
        
        # Build and execute simulation
        println("Building simulation...")
        build!(sim, serialize=true)
        
        println("Executing simulation...")
        execute!(sim, enable_progress_bar=true)
        
        # Process results
        println("Processing results...")
        results = SimulationResults(sim; ignore_status=true)
        results_uc = get_decision_problem_results(results, "UC")
        set_system!(results_uc, sys)
        
        # Read variables and export
        variables = PSI.read_realized_variables(results_uc)
        export_results_csv(results_uc, variables, "ED", joinpath(results.path, "results"))
        
        println("✓ Simulation for hour $hour completed successfully!")
        println("  Results saved to: $(results.path)")
        
        return (
            hour = hour,
            status = "success", 
            results_path = results.path,
            buses = num_buses,
            loads = num_loads,
            generators = num_generators
        )
        
    catch e
        println("✗ Error running simulation for hour $hour:")
        println("  Error: $e")
        @warn "Simulation failed for hour $hour" exception=e
        
        return (
            hour = hour,
            status = "failed", 
            error = string(e),
            results_path = nothing,
            buses = 0,
            loads = 0,
            generators = 0
        )
    end
end

function run_all_hourly_simulations()
    """Run simulations for all 24 hourly systems."""
    
    println("\\n" * "="^80)
    println("BATCH SIMULATION FOR 24 HOURLY SYSTEMS")
    println("="^80)
    
    # Find all system files
    system_files = find_hourly_systems()
    
    if isempty(system_files)
        error("No hourly system files found! Make sure to run create_hourly_mer_systems.jl first.")
    end
    
    println("Found $(length(system_files)) hourly system files:")
    for sys_info in system_files
        println("  Hour $(sys_info.hour): $(sys_info.filename)")
    end
    
    # Create base output directory
    if !ispath(base_output_dir)
        mkpath(base_output_dir)
    end
    
    # Run simulations
    simulation_results = []
    total_systems = length(system_files)
    
    for (i, sys_info) in enumerate(system_files)
        hour = sys_info.hour
        filename = sys_info.filename
        
        println("\\n--- Processing system $i of $total_systems (Hour $hour) ---")
        
        # Create hour-specific output directory
        hour_output_dir = joinpath(base_output_dir, "hour_$(lpad(hour, 2, '0'))")
        if !ispath(hour_output_dir)
            mkpath(hour_output_dir)
        end
        
        # Run simulation
        result = run_simulation_for_hour(hour, filename, hour_output_dir)
        push!(simulation_results, result)
        
        # Print progress
        successful = length(filter(r -> r.status == "success", simulation_results))
        println("Progress: $successful/$i simulations completed successfully")
    end
    
    # Generate summary
    println("\\n" * "="^80)
    println("SIMULATION SUMMARY")
    println("="^80)
    
    successful_sims = filter(r -> r.status == "success", simulation_results)
    failed_sims = filter(r -> r.status == "failed", simulation_results)
    
    println("Successfully completed: $(length(successful_sims))/$(total_systems) simulations")
    if !isempty(failed_sims)
        println("Failed simulations:")
        for sim in failed_sims
            println("  Hour $(sim.hour): $(sim.error)")
        end
    end
    
    println("\\nSuccessful simulations:")
    println("Hour | Results Path | Buses | Loads | Generators")
    println("-"^70)
    for sim in successful_sims
        println("$(lpad(sim.hour, 4)) | $(sim.results_path) | $(lpad(sim.buses, 5)) | $(lpad(sim.loads, 5)) | $(lpad(sim.generators, 10))")
    end
    
    # Save summary to CSV
    summary_df = DataFrame([
        (hour = r.hour, status = r.status, results_path = get(r, :results_path, ""), 
         buses = get(r, :buses, 0), loads = get(r, :loads, 0), generators = get(r, :generators, 0))
        for r in simulation_results
    ])
    
    summary_file = joinpath(base_output_dir, "simulation_summary.csv")
    CSV.write(summary_file, summary_df)
    println("\\nSummary saved to: $summary_file")
    
    if length(successful_sims) == total_systems
        println("\\n🎉 All hourly simulations completed successfully!")
    else
        println("\\n⚠️  $(length(successful_sims)) out of $(total_systems) simulations completed successfully.")
    end
    
    println("="^80)
    
    return simulation_results
end

run_all_hourly_simulations()