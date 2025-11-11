"""
Batch simulation script for 25 systems: 24 hourly MER systems + 1 baseline system.

This script runs power system simulations for all 25 systems created by 
create_hourly_mer_systems.jl:
- 24 hourly systems (0-23): Each has MER load added at specific hour of every day  
- 1 baseline system (24): No MER modifications for comparison

The script will:
1. Find all system files in MERsystems/ directory
2. Run simulation for each system (hours 0-24)
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
using Gurobi
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

function get_env()
    while true
        try
            return Gurobi.Env()
        catch e
            retrytime = rand()*60
            println("No Gurobi licenses available, retrying in $retrytime seconds")
            sleep(retrytime)
        end
    end
end
const GRB_ENV = get_env()
solver = optimizer_with_attributes(
    () -> Gurobi.Optimizer(GRB_ENV),
    "TimeLimit" => 10000.0,     # Set the maximum solver time (in seconds)
    "OutputFlag" => 1,          # Enable logging to console
    "Threads" => 8,             # Set the number of solver threads to use
    "MIPGap" => 1e-3            # Set the relative MIP gap tolerance
)
# Include utility scripts
include("src/parsing_utils.jl")
include("src/post_process.jl")

# Simulation configuration
load_year = 2019
base_output_dir = "MERHourlySimulations"
interval = 24
horizon = 24
steps = 365

# Solver configuration
# solver = optimizer_with_attributes(
#     HiGHS.Optimizer,
#     "time_limit" => 600.0,     # 10 minutes max per simulation
#     "log_to_console" => true,  
#     "mip_abs_gap" => 5e-3,      
# )

function find_hourly_systems()
    """Find all hourly system JSON files including baseline system."""
    
    # Look for MER systems (hours 0-23) in MERsystems directory
    mer_pattern = "MERsystems/mer_hourly_*_nys2030_$(load_year).json"
    mer_files = glob(mer_pattern, ".")
    
    # Look for baseline system (hour 24) in MERsystems directory  
    baseline_pattern = "MERsystems/baseline_nys2030_$(load_year).json"
    baseline_files = glob(baseline_pattern, ".")
    
    println("Debug: Looking for MER pattern: $mer_pattern")
    println("Debug: Found $(length(mer_files)) MER files:")
    for file in mer_files
        println("  - $file")
    end
    
    println("Debug: Looking for baseline pattern: $baseline_pattern")
    println("Debug: Found $(length(baseline_files)) baseline files:")
    for file in baseline_files
        println("  - $file")
    end
    
    # Extract hour numbers and sort
    system_files = []
    
    # Process MER system files (hours 0-23)
    for file in mer_files
        # Extract hour from filename (e.g., "MERsystems/mer_hourly_15_nys2030_2019.json" -> 15)
        regex_pattern = Regex("MERsystems/mer_hourly_(\\d+)_nys2030_$(load_year)\\.json")
        match_result = match(regex_pattern, file)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            push!(system_files, (hour=hour, filename=file))
            println("Debug: Matched MER hour $hour from file: $file")
        else
            println("Debug: No match for MER file: $file")
        end
    end
    
    # Process baseline system file (hour 24)
    for file in baseline_files
        # Baseline system corresponds to hour 24
        push!(system_files, (hour=24, filename=file))
        println("Debug: Added baseline system as hour 24: $file")
    end
    
    # Sort by hour
    sort!(system_files, by=x -> x.hour)
    
    println("Debug: Total systems found: $(length(system_files))")
    
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

function extract_generator_timeseries(baseline_results_path)
    """Extract all generator time series from baseline simulation results."""
    
    println("Extracting generator time series from: $baseline_results_path")
    
    # Read the generator output CSV files
    results_dir = joinpath(baseline_results_path, "results")
    
    # Look for the specific ActivePowerVariable file for ThermalStandard generators
    gen_power_file = joinpath(results_dir, "ActivePowerVariable__ThermalStandard_ED.csv")
    
    generator_timeseries = Dict()
    
    if isfile(gen_power_file)
        println("  Processing: $gen_power_file")
        df = CSV.read(gen_power_file, DataFrame)
        
        # Extract all generator columns (excluding DateTime)
        all_gen_cols = filter(col -> col != "DateTime" && (occursin("AggGen", col) || occursin("import", col)), names(df))
        
        if !isempty(all_gen_cols)
            println("    Found $(length(all_gen_cols)) generator columns: $(all_gen_cols)")
            
            for col in all_gen_cols
                # Extract time series for this generator
                timeseries = df[!, col]
                generator_timeseries[string(col)] = timeseries
                println("    Extracted $(length(timeseries)) time points for $col")
            end
        else
            println("    No generator columns found in file")
        end
    else
        @warn "ActivePowerVariable__ThermalStandard_ED.csv not found in $results_dir"
    end
    
    if isempty(generator_timeseries)
        @warn "No generator time series found in baseline results!"
    else
        println("Successfully extracted $(length(generator_timeseries)) generator time series")
    end
    
    return generator_timeseries
end

function convert_generators_to_loads(system_filename, generator_timeseries, hour)
    """Convert generators to negative loads in a system file."""
    
    println("Converting generators to loads for hour $hour system...")
    
    # Load the system
    sys = PSY.System(system_filename)
    
    # Get all thermal generators from the system
    thermal_generators = get_components(ThermalStandard, sys)
    
    generators_to_remove = []
    loads_to_add = []
    
    for gen in thermal_generators
        gen_name = PSY.get_name(gen)
        
        println("  Processing generator: $gen_name")
        
        # Get the bus for this generator
        bus = PSY.get_bus(gen)
        
        # Find matching time series from baseline results
        matching_ts = nothing
        for (ts_name, ts_data) in generator_timeseries
            if ts_name == gen_name
                matching_ts = ts_data
                println("    Matched time series: $ts_name")
                break
            end
        end
        
        if matching_ts !== nothing
            # Create negative load (generator output becomes load)
            load_name = "$(gen_name)_as_load"
            
            # Convert positive generation to negative load
            negative_load_ts = -matching_ts
            
            # Create load time series
            if length(negative_load_ts) != length(get_timestamp(load_year))
                # Pad or truncate negative_load_ts to match expected length
                expected_length = length(get_timestamp(load_year))
                if length(negative_load_ts) < expected_length
                    # Pad with zeros if too short
                    padding = zeros(expected_length - length(negative_load_ts))
                    negative_load_ts = vcat(negative_load_ts, padding)
                    println("    Padded time series from $(length(matching_ts)) to $expected_length points")
                elseif length(negative_load_ts) > expected_length
                    # Truncate if too long
                    negative_load_ts = negative_load_ts[1:expected_length]
                    println("    Truncated time series from $(length(matching_ts)) to $expected_length points")
                end
                @warn "Time series length mismatch for generator $gen_name: expected 8760, got $(length(negative_load_ts))"
            end
            load_ts_data = TimeArray(get_timestamp(load_year), negative_load_ts)
            
            # Create new load component

            new_load = PSY.StandardLoad(
                name=load_name,                         # Set the name for the new component
                available=true,                    # Mark the component as available
                bus=bus,                           # Assign the bus to the component
                base_power=100.0,                  # Base power of the load component (in kW)
                max_constant_active_power=maximum(abs.(negative_load_ts))/100.0,  # Maximum constant active power of the load component (scaled from the maximum of the load time series)
            )

            PSY.add_component!(sys, new_load)
            # Add time series to load

            if maximum(abs.(negative_load_ts)) == 0.0
                PSY.add_time_series!(
                    sys,
                    new_load,
                    PSY.SingleTimeSeries(
                        "max_active_power",
                        TimeArray(get_timestamp(load_year), negative_load_ts),
                        scaling_factor_multiplier=PSY.get_max_active_power,
                    )
                )
            else
                PSY.add_time_series!(
                    sys,
                    new_load,
                    PSY.SingleTimeSeries(
                        "max_active_power",
                        TimeArray(get_timestamp(load_year), negative_load_ts / maximum(abs.(negative_load_ts))),
                        scaling_factor_multiplier=PSY.get_max_active_power,
                    )
                )
            end
            
            # Mark generator for removal and load for addition
            push!(generators_to_remove, gen)
            
            println("    ✓ Prepared conversion: $gen_name -> $load_name")
        else
            @warn "No matching time series found for generator: $gen_name"
        end
    end
    
    # Remove generators and add loads
    for gen in generators_to_remove
        PSY.remove_component!(sys, gen)
        println("  Removed generator: $(PSY.get_name(gen))")
    end
    
    
    # Save modified system to temporary file
    if hour == 24
        modified_filename = "temp_baseline_converted.json"
    else
        modified_filename = "temp_mer_hour_$(hour)_converted.json"
    end

    PSY.to_json(sys, joinpath("MERsystems", modified_filename), force=true)
    println("  Modified system saved to: $modified_filename")
    
    return joinpath("MERsystems", modified_filename)
end

function run_simulation_for_hour(hour, filename, output_dir)
    """Run simulation for a specific hour's system."""
    
    if hour == 24
        println("\\n" * "="^60)
        println("RUNNING SIMULATION FOR BASELINE SYSTEM (HOUR 24)")
        println("System file: $filename")
        println("="^60)
    else
        println("\\n" * "="^60)
        println("RUNNING SIMULATION FOR HOUR $hour")
        println("System file: $filename")
        println("="^60)
    end
    
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
        if hour == 24
            sim_name = "baseline_simulation"
        else
            sim_name = "hour_$(hour)_simulation"
        end
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
        
        if hour == 24
            println("✓ Baseline simulation completed successfully!")
        else
            println("✓ Simulation for hour $hour completed successfully!")
        end
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
    """Run simulations: baseline first, then 24 hourly MER systems with converted generators."""
    
    println("\\n" * "="^80)
    println("BATCH SIMULATION: 1 BASELINE + 24 MER (with generator conversion)")
    println("="^80)
    
    # Find all system files
    system_files = find_hourly_systems()
    
    if isempty(system_files)
        error("No system files found! Make sure to run create_hourly_mer_systems.jl first and check the MERsystems/ directory.")
    end
    
    # Separate baseline from MER systems
    baseline_files = filter(s -> s.hour == 24, system_files)
    mer_files = filter(s -> s.hour != 24, system_files)
    
    # Sort MER files by hour
    sort!(mer_files, by=x -> x.hour)
    
    println("Found $(length(system_files)) system files:")
    println("  Baseline systems: $(length(baseline_files))")
    println("  MER systems: $(length(mer_files))")
    
    if isempty(baseline_files)
        error("No baseline system found! Need baseline system to extract generator time series.")
    end
    
    # Create base output directory
    if !ispath(base_output_dir)
        mkpath(base_output_dir)
    end
    
    simulation_results = []
    
    # STEP 1: Run baseline simulation first
    println("\\n" * "="^80)
    println("STEP 1: RUNNING BASELINE SIMULATION")
    println("="^80)
    
    baseline_info = baseline_files[1]
    baseline_output_dir = joinpath(base_output_dir, "baseline")
    if !ispath(baseline_output_dir)
        mkpath(baseline_output_dir)
    end
    
    println("Running baseline simulation...")
    baseline_result = run_simulation_for_hour(baseline_info.hour, baseline_info.filename, baseline_output_dir)
    push!(simulation_results, baseline_result)
    
    if baseline_result.status != "success"
        error("Baseline simulation failed! Cannot proceed with generator conversion. Error: $(baseline_result.error)")
    end
    
    println("✓ Baseline simulation completed successfully!")
    baseline_results_path = baseline_result.results_path
    
    # STEP 2: Extract generator time series from baseline results
    println("\\n" * "="^80)
    println("STEP 2: EXTRACTING GENERATOR TIME SERIES FROM BASELINE")
    println("="^80)
    
    generator_timeseries = extract_generator_timeseries(baseline_results_path)
    
    # STEP 3: Run MER simulations with converted generators
    println("\\n" * "="^80)
    println("STEP 3: RUNNING MER SIMULATIONS WITH CONVERTED GENERATORS")
    println("="^80)
    
    total_mer_systems = length(mer_files)
    for (i, sys_info) in enumerate(mer_files)
        hour = sys_info.hour
        filename = sys_info.filename
        
        println("\\n--- Processing MER system for hour $hour - $i of $total_mer_systems ---")
        
        # Create hour-specific output directory
        hour_output_dir = joinpath(base_output_dir, "hour_$(lpad(hour, 2, '0'))")
        if !ispath(hour_output_dir)
            mkpath(hour_output_dir)
        end
        
        # Convert generators to loads in this system
        modified_filename = convert_generators_to_loads(filename, generator_timeseries, hour)
        
        # Run simulation with modified system
        result = run_simulation_for_hour(hour, modified_filename, hour_output_dir)
        push!(simulation_results, result)
        
        # Clean up temporary file
        if isfile(modified_filename)
            rm(modified_filename)
            println("  Cleaned up temporary file: $modified_filename")
        end
        
        # Print progress
        successful = length(filter(r -> r.status == "success", simulation_results))
        println("Progress: $successful/$(i+1) simulations completed successfully")
    end
    
    # Generate summary
    println("\\n" * "="^80)
    println("SIMULATION SUMMARY")
    println("="^80)
    
    successful_sims = filter(r -> r.status == "success", simulation_results)
    failed_sims = filter(r -> r.status == "failed", simulation_results)
    
    println("Successfully completed: $(length(successful_sims))/$(length(simulation_results)) simulations")
    
    # Separate baseline from MER systems for reporting
    baseline_sims = filter(r -> r.hour == 24, successful_sims)
    mer_sims = filter(r -> r.hour != 24, successful_sims)
    
    if !isempty(baseline_sims)
        println("Baseline system: ✓ Completed")
    end
    println("MER systems completed: $(length(mer_sims))/24")
    
    if !isempty(failed_sims)
        println("Failed simulations:")
        for sim in failed_sims
            if sim.hour == 24
                println("  Baseline (Hour 24): $(sim.error)")
            else
                println("  Hour $(sim.hour): $(sim.error)")
            end
        end
    end
    
    println("\\nSuccessful simulations:")
    println("Hour | Type      | Results Path | Buses | Loads | Generators")
    println("-"^75)
    for sim in successful_sims
        sim_type = sim.hour == 24 ? "Baseline" : "MER+Conv"
        println("$(lpad(sim.hour, 4)) | $(rpad(sim_type, 9)) | $(sim.results_path) | $(lpad(sim.buses, 5)) | $(lpad(sim.loads, 5)) | $(lpad(sim.generators, 10))")
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
    
    total_expected = 1 + length(mer_files)  # baseline + MER systems
    if length(successful_sims) == total_expected
        println("\\n🎉 All $(total_expected) simulations completed successfully!")
        println("   - 1 baseline simulation")
        println("   - $(length(mer_sims)) MER simulations with converted generators")
    else
        println("\\n⚠️  $(length(successful_sims)) out of $(total_expected) simulations completed successfully.")
        baseline_success = !isempty(filter(r -> r.hour == 24, successful_sims))
        mer_success_count = length(filter(r -> r.hour != 24, successful_sims))
        println("   - Baseline: $(baseline_success ? "✓" : "✗")")
        println("   - MER systems: $mer_success_count/24 completed")
    end
    
    println("="^80)
    
    return simulation_results
end

# Test function to check system discovery
function test_system_discovery()
    """Test function to see what systems are found."""
    println("Testing system discovery...")
    systems = find_hourly_systems()
    println("Found $(length(systems)) systems:")
    for sys in systems
        println("  Hour $(sys.hour): $(sys.filename)")
    end
    return systems
end

run_all_hourly_simulations()