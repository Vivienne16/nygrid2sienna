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
const SCRIPT_DIR = @__DIR__
include(joinpath(SCRIPT_DIR, "src", "parsing_utils.jl"))
include(joinpath(SCRIPT_DIR, "src", "post_process.jl"))

# Simulation configuration
load_year = 2019
base_output_dir = "MERHourlySimulations_UC_noreserve_newre"


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
    
    # Look for baseline system (hour 24) in baseline_systems directory  
    baseline_pattern = "baseline_systems/nys2030_$(load_year).json"
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

function setup_simulation_template(sys, interval, horizon)
    """Set up the simulation template for a given system."""
    
    # Add reserves to the system
    # add_reserves(sys; reg_reserve_frac=0.05, spinning_reserve_frac=0.1)
    
    # Transform time series data
    PSY.transform_single_time_series!(sys, Hour(horizon), Hour(interval))
    
    # Create unit commitment template
    template_uc = PSI.template_unit_commitment(; 
        network=NetworkModel(PSI.PTDFPowerModel, use_slacks=true, PTDF_matrix=PTDF(sys))
    )
    
    # Set device models
    set_device_model!(template_uc, DeviceModel(ThermalStandard, ThermalBasicUnitCommitment))
    set_device_model!(template_uc, StandardLoad, StaticPowerLoad)
    set_device_model!(template_uc, DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves))
    set_device_model!(template_uc, DeviceModel(Transformer2W, StaticBranch))
    set_device_model!(template_uc, DeviceModel(Line, StaticBranch))
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

    # Create temporary directory if it doesn't exist
    temp_dir = "MERsystems_temp"
    if !isdir(temp_dir)
        mkpath(temp_dir)
    end
    
    PSY.to_json(sys, joinpath(temp_dir, modified_filename), force=true)
    println("  Modified system saved to: $(joinpath(temp_dir, modified_filename))")
    
    return joinpath("MERsystems_temp", modified_filename)
end

function set_initial_storage_levels!(sys,baseline_results_path,initial_hour)
    """Set initial storage levels from baseline results for a given hour."""
    
    println("Setting initial storage levels for hour $(Dates.hour(initial_hour))...")
    
    results_dir = joinpath(baseline_results_path, "results")
    storage_file = joinpath(results_dir, "EnergyVariable__EnergyReservoirStorage_ED.csv")
    
    if isfile(storage_file)
        df = CSV.read(storage_file, DataFrame)
        matching_row = filter(row -> row.DateTime == initial_hour, df)
        
        if nrow(matching_row) == 0
            @warn "No matching row found for initial_hour: $initial_hour. Skipping storage initialization."
            return
        end
        
        for storage in get_components(EnergyReservoirStorage, sys)
            storage_name = PSY.get_name(storage)
            println("  Processing storage: $storage_name")
            
            initial_level = matching_row[1, storage_name]
            soc_max = PSY.get_storage_capacity(storage)
            PSY.set_initial_storage_capacity_level!(storage, initial_level/soc_max)
            println("    Set initial energy level to $initial_level kWh")
        end
    else
        @warn "EnergyVariable__EnergyReservoirStorage_ED.csv not found in $results_dir"
    end
end

function set_initial_thermal_states!(sys,baseline_results_path,initial_hour)
    """Set initial thermal generator states from baseline results for a given hour."""
    
    println("Setting initial thermal generator states for hour $(Dates.hour(initial_hour))...")
    
    results_dir = joinpath(baseline_results_path, "results")
    thermal_file = joinpath(results_dir, "ActivePowerVariable__ThermalStandard_ED.csv")
    
    if isfile(thermal_file)
        df = CSV.read(thermal_file, DataFrame)
        matching_row = filter(row -> row.DateTime == initial_hour, df)
        for gen in get_available_components(ThermalStandard, sys)
            gen_name = PSY.get_name(gen)
            println("  Processing generator: $gen_name")
            
            # Find matching time series 
            if nrow(matching_row) > 0
                initial_active_power = matching_row[1, gen_name]
                PSY.set_active_power!(gen, initial_active_power)
                println("    Set initial active power to $initial_active_power")
            else
                @warn "No matching time series found for generator: $gen_name"
            end
        end
    else
        @warn "ActivePowerVariable__ThermalStandard_ED.csv not found in $results_dir"
    end
end

function run_simulation_for_hour(hour, filename, output_dir, interval, horizon, steps, day_id, baseline_results_path)
    """Run simulation for a specific hour's system."""
    initial_time = DateTime(load_year, 1, 1)
    if day_id > 1
        initial_time = DateTime(load_year, 1, 1) + Day(day_id - 1) + Hour(0)
    end
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
        for re in get_available_components(RenewableDispatch, sys)
            re_name = PSY.get_name(re)
            
            
            PSY.set_ext!(re, Dict("Pmin" => -10.0))

            
        end
        # Verify system loaded correctly
        num_buses = length(get_components(Bus, sys))
        num_loads = length(get_components(StandardLoad, sys))
        num_generators = length(get_components(Generator, sys))
        if hour < 24
            initial_hour = initial_time - Hour(1)
            set_initial_storage_levels!(sys,baseline_results_path,initial_hour)  # Set initial storage levels to 50% for MER systems
            set_initial_thermal_states!(sys,baseline_results_path,initial_hour)    # Set initial thermal states to 50% for MER systems
        end
        println("System loaded successfully:")
        println("  - Buses: $num_buses")
        println("  - Loads: $num_loads")
        println("  - Generators: $num_generators")
        
        # Setup simulation template
        println("Setting up simulation template...")
        template_uc = setup_simulation_template(sys, interval, horizon)
        
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
            sim_name = "hour_$(hour)_$(day_id)"
        end
        sim = Simulation(
            name=sim_name,
            steps=steps,
            models=models,
            sequence=sequence,
            simulation_folder=output_dir,
            initial_time=initial_time
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
        model = get_simulation_model(sim, :UC)
        PSI.compute_conflict!(model.internal.container)
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

function run_baseline_simulation()
    """Run the baseline simulation and return the results path."""
    
    println("\\n" * "="^80)
    println("RUNNING BASELINE SIMULATION")
    println("="^80)
    
    # Define simulation parameters first
    interval = 24
    horizon = 24
    steps = 365
    
    # Find baseline system file
    system_files = find_hourly_systems()
    
    if isempty(system_files)
        error("No system files found! Make sure to run create_hourly_mer_systems.jl first and check the MERsystems/ directory.")
    end
    
    # Separate baseline from MER systems
    baseline_files = filter(s -> s.hour == 24, system_files)
    baseline_info = baseline_files[1]
    baseline_output_dir = joinpath(base_output_dir)
    if !ispath(baseline_output_dir)
        mkpath(baseline_output_dir)
    end
    println("Running baseline simulation...")
    baseline_result = run_simulation_for_hour(baseline_info.hour, baseline_info.filename, baseline_output_dir, interval, horizon, steps, 0,"")
    
    if baseline_result.status != "success"
        error("Baseline simulation failed! Cannot proceed with generator conversion. Error: $(baseline_result.error)")
    end
    
    println("✓ Baseline simulation completed successfully!")
    baseline_results_path = baseline_result.results_path

    return baseline_results_path
end


function run_mer_simulations(baseline_results_path)
    """Run 24 hourly MER systems with converted generators."""
    
    println("\\n" * "="^80)
    println("BATCH SIMULATION: 1 BASELINE + 24 MER (with generator conversion)")
    println("="^80)
    
    # Find all system files
    system_files = find_hourly_systems()
    
    if isempty(system_files)
        error("No system files found! Make sure to run create_hourly_mer_systems.jl first and check the MERsystems/ directory.")
    end
    
    mer_files = filter(s -> s.hour != 24, system_files)
    sort!(mer_files, by=x -> x.hour)
    
    generator_timeseries = extract_generator_timeseries(baseline_results_path)

    total_mer_systems = length(mer_files)
    for (i, sys_info) in enumerate(mer_files)
        hour = sys_info.hour
        filename = sys_info.filename
        
        println("\\n--- Processing MER system for hour $hour - $i of $total_mer_systems ---")
        
        # Create hour-specific output directory
        hour_output_dir = joinpath(base_output_dir, "hour_$(hour)")
        if !ispath(hour_output_dir)
            mkpath(hour_output_dir)
        end
        
        # Convert generators to loads in this system
        modified_filename = convert_generators_to_loads(filename, generator_timeseries, hour)
        interval = 24
        horizon = 24
        steps = 1
        day_list = collect(1:365)
        for day_id in day_list
            # Run simulation with modified system
            result = run_simulation_for_hour(hour, modified_filename, hour_output_dir, interval, horizon, steps, day_id,baseline_results_path)
        end

        # Clean up temporary file
        if isfile(modified_filename)
            rm(modified_filename)
            println("  Cleaned up temporary file: $modified_filename")
        end
        
    end
    return
end



baseline_results_path = run_baseline_simulation()
# baseline_results_path = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_test/baseline_simulation"
# run_mer_simulations(baseline_results_path)
# result = SimulationResults("/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC_noreserve/baseline_simulation"; ignore_status=true)
# results_uc = get_decision_problem_results(result, "UC")
# variables = PSI.read_realized_variables(results_uc)
# export_results_csv(results_uc, variables, "ED", joinpath(result.path, "results"))