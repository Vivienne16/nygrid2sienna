"""
Parallel simulation script for individual MER hourly systems.

This script is designed to be run in parallel using Slurm. Each job processes
a single hour of MER data.

Usage:
    julia setup_mer_simulation_hourly_parallel.jl <hour> <baseline_results_path>

Arguments:
    hour: Integer from 0-23 indicating which hourly MER system to simulate
    baseline_results_path: Path to the baseline simulation results directory
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
    "TimeLimit" => 10000.0,
    "OutputFlag" => 1,
    "Threads" => 8,
    "MIPGap" => 1e-3
)

# Include utility scripts
include("parsing_utils.jl")
include("post_process.jl")

# Simulation configuration
load_year = 2019
base_output_dir = "MERHourlySimulations_UC"

function find_system_for_hour(hour::Int)
    """Find the system file for a specific hour."""
    
    if hour < 0 || hour > 23
        error("Hour must be between 0 and 23, got: $hour")
    end
    
    # Look for MER system file for this hour
    mer_pattern = "MERsystems/mer_hourly_$(hour)_nys2030_$(load_year).json"
    mer_files = glob(mer_pattern, ".")
    
    if isempty(mer_files)
        error("No system file found for hour $hour. Expected: $mer_pattern")
    end
    
    println("Found system file for hour $hour: $(mer_files[1])")
    return mer_files[1]
end

function setup_simulation_template(sys)
    """Set up the simulation template for a given system."""
    
    # Add reserves to the system
    add_reserves(sys; reg_reserve_frac=0.05, spinning_reserve_frac=0.1)
    
    # Transform time series data
    horizon = 24
    interval = 24
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
    
    results_dir = joinpath(baseline_results_path, "results")
    gen_power_file = joinpath(results_dir, "ActivePowerVariable__ThermalStandard_ED.csv")
    
    generator_timeseries = Dict()
    
    if isfile(gen_power_file)
        println("  Processing: $gen_power_file")
        df = CSV.read(gen_power_file, DataFrame)
        
        all_gen_cols = filter(col -> col != "DateTime" && (occursin("AggGen", col) || occursin("import", col)), names(df))
        
        if !isempty(all_gen_cols)
            println("    Found $(length(all_gen_cols)) generator columns")
            
            for col in all_gen_cols
                timeseries = df[!, col]
                generator_timeseries[string(col)] = timeseries
            end
        end
    else
        @warn "ActivePowerVariable__ThermalStandard_ED.csv not found in $results_dir"
    end
    
    return generator_timeseries
end

function extract_storage_timeseries(baseline_results_path)
    """Extract all storage charge/discharge time series from baseline simulation results."""
    
    println("Extracting storage time series from: $baseline_results_path")
    
    results_dir = joinpath(baseline_results_path, "results")
    
    storage_timeseries = Dict()
    
    # Extract storage charging (ActivePowerInVariable)
    storage_in_file = joinpath(results_dir, "ActivePowerInVariable__EnergyReservoirStorage_ED.csv")
    if isfile(storage_in_file)
        println("  Processing: $storage_in_file")
        df = CSV.read(storage_in_file, DataFrame)
        
        storage_cols = filter(col -> col != "DateTime", names(df))
        
        if !isempty(storage_cols)
            println("    Found $(length(storage_cols)) storage charging columns")
            
            for col in storage_cols
                timeseries = df[!, col]
                storage_timeseries["$(col)_charge"] = timeseries
                println("    Extracted charging time series for $col")
            end
        end
    else
        @warn "ActivePowerInVariable__EnergyReservoirStorage_ED.csv not found in $results_dir"
    end
    
    # Extract storage discharging (ActivePowerOutVariable)
    storage_out_file = joinpath(results_dir, "ActivePowerOutVariable__EnergyReservoirStorage_ED.csv")
    if isfile(storage_out_file)
        println("  Processing: $storage_out_file")
        df = CSV.read(storage_out_file, DataFrame)
        
        storage_cols = filter(col -> col != "DateTime", names(df))
        
        if !isempty(storage_cols)
            println("    Found $(length(storage_cols)) storage discharging columns")
            
            for col in storage_cols
                timeseries = df[!, col]
                storage_timeseries["$(col)_discharge"] = timeseries
                println("    Extracted discharging time series for $col")
            end
        end
    else
        @warn "ActivePowerOutVariable__EnergyReservoirStorage_ED.csv not found in $results_dir"
    end
    
    if isempty(storage_timeseries)
        @warn "No storage time series found in baseline results!"
    else
        println("Successfully extracted $(length(storage_timeseries)) storage time series")
    end
    
    return storage_timeseries
end

function convert_storage_to_loads(system_filename, storage_timeseries, hour)
    """Convert storage units to loads (net discharge = discharge - charge)."""
    
    println("Converting storage to loads for hour $hour system...")
    
    sys = PSY.System(system_filename)
    storage_units = get_components(EnergyReservoirStorage, sys)
    
    storage_to_remove = []
    
    for storage in storage_units
        storage_name = PSY.get_name(storage)
        println("  Processing storage: $storage_name")
        
        bus = PSY.get_bus(storage)
        
        # Find matching charge and discharge time series
        charge_ts = nothing
        discharge_ts = nothing
        
        for (ts_name, ts_data) in storage_timeseries
            if contains(ts_name, storage_name) && contains(ts_name, "_charge")
                charge_ts = ts_data
            elseif contains(ts_name, storage_name) && contains(ts_name, "_discharge")
                discharge_ts = ts_data
            end
        end
        
        if charge_ts !== nothing && discharge_ts !== nothing
            # Calculate net discharge (discharge - charge)
            # Negative values mean net charging, positive means net discharging
            net_discharge_ts = discharge_ts .- charge_ts
            
            # Convert to load: positive net discharge becomes negative load (supplying power)
            load_ts = -net_discharge_ts
            
            load_name = "$(storage_name)_as_load"
            
            if length(load_ts) != length(get_timestamp(load_year))
                expected_length = length(get_timestamp(load_year))
                if length(load_ts) < expected_length
                    padding = zeros(expected_length - length(load_ts))
                    load_ts = vcat(load_ts, padding)
                elseif length(load_ts) > expected_length
                    load_ts = load_ts[1:expected_length]
                end
            end
            
            load_ts_data = TimeArray(get_timestamp(load_year), load_ts)
            
            new_load = PSY.StandardLoad(
                name=load_name,
                available=true,
                bus=bus,
                base_power=100.0,
                max_constant_active_power=maximum(abs.(load_ts))/100.0,
            )
            
            PSY.add_component!(sys, new_load)
            
            if maximum(abs.(load_ts)) == 0.0
                PSY.add_time_series!(
                    sys,
                    new_load,
                    PSY.SingleTimeSeries(
                        "max_active_power",
                        TimeArray(get_timestamp(load_year), load_ts),
                        scaling_factor_multiplier=PSY.get_max_active_power,
                    )
                )
            else
                PSY.add_time_series!(
                    sys,
                    new_load,
                    PSY.SingleTimeSeries(
                        "max_active_power",
                        TimeArray(get_timestamp(load_year), load_ts / maximum(abs.(load_ts))),
                        scaling_factor_multiplier=PSY.get_max_active_power,
                    )
                )
            end
            
            push!(storage_to_remove, storage)
            println("    ✓ Prepared conversion: $storage_name -> $load_name")
        else
            if charge_ts === nothing
                println("    ⚠ No charge time series found for $storage_name")
            end
            if discharge_ts === nothing
                println("    ⚠ No discharge time series found for $storage_name")
            end
        end
    end
    
    # Remove storage units
    for storage in storage_to_remove
        PSY.remove_component!(sys, storage)
        println("  Removed storage: $(PSY.get_name(storage))")
    end
    
    # Save modified system
    if hour == 24
        modified_filename = "temp_baseline_storage_converted.json"
    else
        modified_filename = "temp_mer_hour_$(hour)_storage_converted.json"
    end
    
    PSY.to_json(sys, joinpath("MERsystems", modified_filename), force=true)
    println("  Modified system saved to: $modified_filename")
    
    return joinpath("MERsystems", modified_filename)
end

function convert_generators_to_loads(system_filename, generator_timeseries, hour)
    """Convert generators to negative loads in a system file."""
    
    println("Converting generators to loads for hour $hour system...")
    
    sys = PSY.System(system_filename)
    thermal_generators = get_components(ThermalStandard, sys)
    
    generators_to_remove = []
    
    for gen in thermal_generators
        gen_name = PSY.get_name(gen)
        println("  Processing generator: $gen_name")
        
        bus = PSY.get_bus(gen)
        
        matching_ts = nothing
        for (ts_name, ts_data) in generator_timeseries
            if ts_name == gen_name
                matching_ts = ts_data
                break
            end
        end
        
        if matching_ts !== nothing
            load_name = "$(gen_name)_as_load"
            negative_load_ts = -matching_ts
            
            if length(negative_load_ts) != length(get_timestamp(load_year))
                expected_length = length(get_timestamp(load_year))
                if length(negative_load_ts) < expected_length
                    padding = zeros(expected_length - length(negative_load_ts))
                    negative_load_ts = vcat(negative_load_ts, padding)
                elseif length(negative_load_ts) > expected_length
                    negative_load_ts = negative_load_ts[1:expected_length]
                end
            end
            
            load_ts_data = TimeArray(get_timestamp(load_year), negative_load_ts)
            
            new_load = PSY.StandardLoad(
                name=load_name,
                available=true,
                bus=bus,
                base_power=100.0,
                max_constant_active_power=maximum(abs.(negative_load_ts))/100.0,
            )
            
            PSY.add_component!(sys, new_load)
            
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
            
            push!(generators_to_remove, gen)
            println("    ✓ Prepared conversion: $gen_name -> $load_name")
        end
    end
    
    for gen in generators_to_remove
        PSY.remove_component!(sys, gen)
        println("  Removed generator: $(PSY.get_name(gen))")
    end
    
    modified_filename = "temp_mer_hour_$(hour)_converted.json"
    PSY.to_json(sys, joinpath("MERsystems", modified_filename), force=true)
    println("  Modified system saved to: $modified_filename")
    
    return joinpath("MERsystems", modified_filename)
end

function set_initial_storage_levels!(sys, baseline_results_path, initial_hour)
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

function set_initial_thermal_states!(sys, baseline_results_path, initial_hour)
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
    
    println("\\n" * "="^60)
    println("RUNNING SIMULATION FOR HOUR $hour, DAY $day_id")
    println("System file: $filename")
    println("="^60)
    
    try
        println("Loading system...")
        sys = System(filename)
        
        num_buses = length(get_components(Bus, sys))
        num_loads = length(get_components(StandardLoad, sys))
        num_generators = length(get_components(Generator, sys))
        
        initial_hour = initial_time - Hour(1)
        set_initial_storage_levels!(sys, baseline_results_path, initial_hour)
        set_initial_thermal_states!(sys, baseline_results_path, initial_hour)
        
        println("System loaded successfully:")
        println("  - Buses: $num_buses")
        println("  - Loads: $num_loads")
        println("  - Generators: $num_generators")
        
        println("Setting up simulation template...")
        template_uc = setup_simulation_template(sys)
        
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
        
        sequence = SimulationSequence(models=models, ini_cond_chronology=InterProblemChronology())
        
        sim_name = "hour_$(hour)_$(day_id)"
        sim = Simulation(
            name=sim_name,
            steps=steps,
            models=models,
            sequence=sequence,
            simulation_folder=output_dir,
            initial_time=initial_time
        )
        
        println("Building simulation...")
        build!(sim, serialize=true)
        
        println("Executing simulation...")
        execute!(sim, enable_progress_bar=true)
        
        println("Processing results...")
        results = SimulationResults(sim; ignore_status=true)
        results_uc = get_decision_problem_results(results, "UC")
        set_system!(results_uc, sys)
        
        variables = PSI.read_realized_variables(results_uc)
        export_results_csv(results_uc, variables, "ED", joinpath(results.path, "results"))
        
        println("✓ Simulation for hour $hour, day $day_id completed successfully!")
        println("  Results saved to: $(results.path)")
        
        return (
            hour = hour,
            day = day_id,
            status = "success", 
            results_path = results.path,
            buses = num_buses,
            loads = num_loads,
            generators = num_generators
        )
        
    catch e
        println("✗ Error running simulation for hour $hour, day $day_id:")
        println("  Error: $e")
        @warn "Simulation failed for hour $hour, day $day_id" exception=e
        
        return (
            hour = hour,
            day = day_id,
            status = "failed", 
            error = string(e),
            results_path = nothing,
            buses = 0,
            loads = 0,
            generators = 0
        )
    end
end

function main()
    """Main function to run simulation for a single hour."""
    
    # Parse command line arguments
    if length(ARGS) < 1
        error("Usage: julia setup_mer_simulation_hourly_parallel.jl <hour>")
    end
    
    hour = parse(Int, ARGS[1])
    baseline_results_path = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation"
    
    println("="^80)
    println("MER HOURLY SIMULATION - HOUR $hour")
    println("Baseline results: $baseline_results_path")
    println("="^80)
    
    # Find system file for this hour
    system_file = find_system_for_hour(hour)
    
    # Extract generator time series from baseline
    generator_timeseries = extract_generator_timeseries(baseline_results_path)
    
    # Create hour-specific output directory
    hour_output_dir = joinpath(base_output_dir, "hour_$(hour)")
    if !ispath(hour_output_dir)
        mkpath(hour_output_dir)
    end
    
    # Convert generators to loads
    modified_filename = convert_generators_to_loads(system_file, generator_timeseries, hour)
    
    # Run simulation for all days
    interval = 24
    horizon = 24
    steps = 1
    day_list = collect(1:365)
    
    results = []
    for day_id in day_list
        result = run_simulation_for_hour(hour, modified_filename, hour_output_dir, interval, horizon, steps, day_id, baseline_results_path)
        push!(results, result)
    end
    
    # Clean up temporary file
    if isfile(modified_filename)
        rm(modified_filename)
        println("Cleaned up temporary file: $modified_filename")
    end
    
    # Summary
    successful = count(r -> r.status == "success", results)
    failed = count(r -> r.status == "failed", results)
    
    println("\\n" * "="^80)
    println("HOUR $hour SIMULATION COMPLETE")
    println("  Total days: $(length(results))")
    println("  Successful: $successful")
    println("  Failed: $failed")
    println("="^80)
    
    return results
end

# Run main function
main()
