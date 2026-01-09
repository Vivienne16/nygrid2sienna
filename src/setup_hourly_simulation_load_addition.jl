"""
Hourly simulation script with load addition to bus 65.

This script runs hour-by-hour simulations using the baseline system,
adding 1 MW of load to bus 65 for each hour. Storage and generator initial
conditions are set from baseline results.

Usage:
    julia setup_hourly_simulation_load_addition.jl <hour>

Arguments:
    hour: Integer from 0-23 indicating which hour to simulate
"""

# Redirect temporary files to home directory to avoid /tmp space issues
ENV["TMPDIR"] = joinpath(homedir(), "tmp")
!isdir(ENV["TMPDIR"]) && mkpath(ENV["TMPDIR"])

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
    "MIPGap" => 5e-4
)

# Include utility scripts
include("parsing_utils.jl")
include("post_process.jl")

mer_run = true  # whether to include mer load
# Simulation configuration
load_year = 2019
baseline_system_path = "baseline_systems/nys2030_2019.json"
baseline_results_path = "MERHourlySimulations_UC_noreserve_newre/baseline_simulation"
if mer_run
    base_output_dir = "MERHourlySimulations_UC_noreserve_pmin_fixed_newre"
else
    base_output_dir = "BASEHourlySimulations_UC_noreserve_newre"
end

function load_baseline_system()
    """Load the baseline system from JSON file."""
    
    if !isfile(baseline_system_path)
        error("Baseline system file not found: $baseline_system_path")
    end
    
    println("Loading baseline system from: $baseline_system_path")
    sys = PSY.System(baseline_system_path)
    println("  Successfully loaded system with $(length(get_components(PSY.Bus, sys))) buses")
    
    return sys
end

function add_load_to_bus(sys, bus_id::String, load_mw::Float64, target_hour::Int)
    """Add a load to a specific bus at a specific hour (1-8760)."""
    
    println("Adding $(load_mw) MW load to bus $bus_id at hour $target_hour...")
    
    # Find the bus
    target_bus = nothing
    for bus in get_components(PSY.Bus, sys)
        if string(PSY.get_number(bus)) == bus_id
            target_bus = bus
            break
        end
    end
    
    if target_bus === nothing
        error("Bus with ID $bus_id not found in system")
    end
    
    println("  Found bus: $(PSY.get_name(target_bus)) (Number: $(PSY.get_number(target_bus)))")
    
    # Create a load time series with load only at the target hour, zero elsewhere
    timestamps = get_timestamp(load_year)
    load_values = zeros(length(timestamps))
    
    # Set load to 1.0 at the target hour (will be scaled by max_active_power)
    if target_hour >= 1 && target_hour <= length(timestamps)
        load_values[target_hour] = 1.0
    else
        error("Target hour $target_hour is out of range (1-$(length(timestamps)))")
    end
    
    load_ts = TimeArray(timestamps, load_values)
    
    # Create the load
    load_name = "AddedLoad_Bus$(bus_id)_Hour$(target_hour)_$(load_mw)MW"
    new_load = PSY.StandardLoad(
        name=load_name,
        available=true,
        bus=target_bus,
        base_power=100.0,
        max_constant_active_power=load_mw/100.0,  # Per unit on 100 MW base
    )
    
    PSY.add_component!(sys, new_load)
    
    # Add time series (1.0 at target hour, 0.0 elsewhere)
    PSY.add_time_series!(
        sys,
        new_load,
        PSY.SingleTimeSeries(
            "max_active_power",
            load_ts,
            scaling_factor_multiplier=PSY.get_max_active_power,
        )
    )
    
    println("  ✓ Successfully added load: $load_name (active only at hour $target_hour)")
    
    return sys
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

function extract_renewable_timeseries(baseline_results_path, hour_index::Int)
    """Extract renewable dispatch time series for a specific hour from baseline hourly results."""
    
    println("Extracting renewable dispatch time series for hour $hour_index from baseline hourly results")
    
    renewable_timeseries = Dict()
    
    # Read from the specific hour's baseline results
    hourly_results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/BASEHourlySimulations_UC_noreserve_newre/hour_$(hour_index)"
    results_dir = joinpath(hourly_results_dir, "results")
    renewable_power_file = joinpath(results_dir, "ActivePowerVariable__RenewableDispatch_ED.csv")
    
    if isfile(renewable_power_file)
        df = CSV.read(renewable_power_file, DataFrame)
        
        renewable_cols = filter(col -> col != "DateTime", names(df))
        
        if !isempty(renewable_cols)
            println("    Found $(length(renewable_cols)) renewable dispatch columns for hour $hour_index")
            
            for col in renewable_cols
                # Get the value for this specific hour
                renewable_timeseries[string(col)] = df[1, col]
            end
        end
    else
        @warn "ActivePowerVariable__RenewableDispatch_ED.csv not found for hour $hour_index"
    end
    
    return renewable_timeseries
end


function set_re_pmin!(sys, baseline_results_path, initial_hour, mer_run::Bool)
    """Set hydro generator pmin from baseline results for a given hour.
    
    If mer_run is false: No changes to hydro
    If mer_run is true: Adjust pmin to match baseline active power
    """
    
    println("Setting hydro generator pmin for hour $(Dates.hour(initial_hour))...")
    println("  MER run mode: $mer_run")
    
    if !mer_run
        println("  Non-MER run: Skipping hydro pmin adjustment")
        return
    end
    
    # Calculate the hour index (1-8760) from initial_hour
    year_start = DateTime(load_year, 1, 1, 0, 0, 0)
    hour_index = Int(Dates.value(initial_hour - year_start) / (1000 * 60 * 60)) + 1
    
    # Read from hourly baseline results
    hourly_results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/BASEHourlySimulations_UC_noreserve_newre/hour_$(hour_index)"
    results_dir = joinpath(hourly_results_dir, "results")
    re_file = joinpath(results_dir, "ActivePowerVariable__RenewableDispatch_ED.csv")
    
    println("  Reading from: $re_file")
    
    if isfile(re_file)
        df = CSV.read(re_file, DataFrame)
        matching_row = filter(row -> row.DateTime == initial_hour, df)
        
        if nrow(matching_row) == 0
            @warn "No matching row found for initial_hour: $initial_hour. Skipping hydro initialization."
            return
        end
        
        for re in get_available_components(RenewableDispatch, sys)
            re_name = PSY.get_name(re)
            
            if re_name in names(df)
                initial_power = matching_row[1, re_name]
                
                
                # MER run: Adjust pmin to baseline active power
                new_pmin = initial_power/100.0
                ts = get_time_series_array(SingleTimeSeries,re,"max_active_power")
                ts_val = values(ts)[hour_index]
                pmax = ts_val
                if new_pmin > pmax
                    new_pmin = pmax
                end
                PSY.set_ext!(re, Dict("Pmin" => new_pmin))

                println("    Set $re_name pmin adjusted from 0.0 to $(new_pmin) MW (pmax: $(pmax) MW)")
            end
        end
    else
        @warn "ActivePowerVariable__RenewableDispatch_ED.csv not found in $results_dir"
    end
end


function fix_renewable_to_baseline(sys, renewable_timeseries_hour, hour_id::Int, mer_run::Bool)
    """Fix RenewableDispatch generators to baseline values similar to hydro."""
    
    if !mer_run
        println("Non-MER run: Skipping renewable dispatch adjustment")
        return sys
    end
    
    println("Setting RenewableDispatch pmin to baseline values for hour $hour_id...")
    
    renewable_generators = get_components(RenewableDispatch, sys)
    
    for ren in renewable_generators
        ren_name = PSY.get_name(ren)
        println("  Processing renewable: $ren_name")
        
        # Find matching value for this hour
        matching_value = nothing
        for (ts_name, value) in renewable_timeseries_hour
            if ts_name == ren_name
                matching_value = value
                break
            end
        end
        
        if matching_value !== nothing
            original_pmin = PSY.get_active_power_limits(ren).min
            pmax = PSY.get_active_power_limits(ren).max
            
            # Set pmin to baseline active power
            new_pmin = max(matching_value / PSY.get_base_power(ren), original_pmin)
            if new_pmin > pmax
                new_pmin = pmax
            end
            PSY.set_active_power_limits!(ren, PSY.MinMax((new_pmin, pmax)))
            println("    Set $ren_name pmin adjusted from $(original_pmin * PSY.get_base_power(ren)) to $(new_pmin * PSY.get_base_power(ren)) MW")
        else
            println("    Warning: No matching value found for $ren_name")
        end
    end
    
    return sys
end

function convert_generators_to_loads(sys, generator_timeseries)
    """Convert generators to negative loads in the system."""
    
    println("Converting generators to loads...")
    
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
    
    return sys
end

function setup_simulation_template(sys)
    """Set up the simulation template for a given system."""
    
    # Add reserves to the system
    # add_reserves(sys; reg_reserve_frac=0.05, spinning_reserve_frac=0.1)
    
    # Transform time series data
    horizon = 1
    interval = 1
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
            end
        end
    else
        @warn "ActivePowerOutVariable__EnergyReservoirStorage_ED.csv not found in $results_dir"
    end
    
    println("Successfully extracted $(length(storage_timeseries)) storage time series")
    
    return storage_timeseries
end

function fix_storage_to_baseline(sys, storage_timeseries, hour)
    """Fix storage charge/discharge to baseline values by converting to loads."""
    
    println("Fixing storage to baseline values for hour $hour...")
    
    storage_units = collect(get_components(EnergyReservoirStorage, sys))
    
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
            net_discharge_ts = discharge_ts .- charge_ts
            
            # Convert to load: positive net discharge becomes negative load (supplying power)
            load_ts = -net_discharge_ts
            
            load_name = "$(storage_name)_fixed"
            
            # Ensure time series length matches
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
                        load_ts_data,
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
            
            println("    ✓ Created fixed load: $load_name")
        else
            @warn "  Could not find charge/discharge time series for $storage_name"
        end
    end
    
    # Remove all storage units
    for storage in storage_units
        PSY.remove_component!(sys, storage)
        println("  Removed storage: $(PSY.get_name(storage))")
    end
    
    return sys
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
            
            if storage_name in names(df)
                initial_level = matching_row[1, storage_name]
                soc_max = PSY.get_storage_capacity(storage)
                PSY.set_initial_storage_capacity_level!(storage, initial_level/soc_max)
                println("    Set initial energy level for $storage_name to $initial_level kWh")
            end
        end
    else
        @warn "EnergyVariable__EnergyReservoirStorage_ED.csv not found in $results_dir"
    end
end

function set_initial_thermal_states!(sys, baseline_results_path, initial_hour, mer_run::Bool)
    """Set initial thermal generator states from baseline results for a given hour.
    
    If mer_run is false: Only set generator status (on/off)
    If mer_run is true: Set status and adjust pmin to match baseline active power
    """
    
    println("Setting initial thermal generator states for hour $(Dates.hour(initial_hour))...")
    println("  MER run mode: $mer_run")
    
    # Calculate the hour index (1-8760) from initial_hour
    year_start = DateTime(load_year, 1, 1, 0, 0, 0)
    hour_index = Int(Dates.value(initial_hour - year_start) / (1000 * 60 * 60)) + 1
    
    # Read from hourly baseline results
    hourly_results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/BASEHourlySimulations_UC_noreserve_newre/hour_$(hour_index)"
    results_dir = joinpath(hourly_results_dir, "results")
    thermal_file = joinpath(results_dir, "ActivePowerVariable__ThermalStandard_ED.csv")
    
    println("  Reading from: $thermal_file")
    
    if isfile(thermal_file)
        df = CSV.read(thermal_file, DataFrame)
        matching_row = filter(row -> row.DateTime == initial_hour, df)
        
        if nrow(matching_row) == 0
            @warn "No matching row found for initial_hour: $initial_hour. Skipping thermal initialization."
            return
        end
        
        for gen in get_available_components(ThermalStandard, sys)
            gen_name = PSY.get_name(gen)
            
            if gen_name in names(df)
                initial_power = matching_row[1, gen_name]
                original_pmin = PSY.get_active_power_limits(gen).min
                
                if !mer_run
                    # Non-MER run: Only set status
                    if initial_power > original_pmin
                        PSY.set_status!(gen, true)
                        println("    Set $gen_name to ON")
                    else
                        PSY.set_status!(gen, false)
                        println("    Set $gen_name to OFF")
                    end
                else
                    # MER run: Set status and adjust pmin to baseline active power
                    if initial_power >= original_pmin
                        PSY.set_status!(gen, true)
                        # Set pmin to at least the baseline active power
                        new_pmin = max(initial_power, original_pmin)
                        PSY.set_active_power!(gen, new_pmin)
                        pmax = PSY.get_active_power_limits(gen).max
                        if new_pmin > pmax
                            new_pmin = pmax
                        end
                        PSY.set_active_power_limits!(gen, PSY.MinMax((new_pmin, pmax)))
                        PSY.set_must_run!(gen, true)
                        println("    Set $gen_name to ON (pmin adjusted from $(original_pmin) to $(new_pmin * PSY.get_base_power(gen)) MW)")
                    else
                        if initial_power >0
                            PSY.set_must_run!(gen, true)
                            PSY.set_status!(gen, true)
                            new_pmin = max(initial_power, original_pmin)
                            pmax = PSY.get_active_power_limits(gen).max
                            if new_pmin > pmax
                                new_pmin = pmax
                            end
                            PSY.set_active_power!(gen, new_pmin)
                        else
                            PSY.set_status!(gen, false)
                            println("    Set $gen_name to OFF")
                        end
                    end
                end
            end
        end
    else
        @warn "ActivePowerVariable__ThermalStandard_ED.csv not found in $results_dir"
    end
end

function set_hydro_pmin!(sys, baseline_results_path, initial_hour, mer_run::Bool)
    """Set hydro generator pmin from baseline results for a given hour.
    
    If mer_run is false: No changes to hydro
    If mer_run is true: Adjust pmin to match baseline active power
    """
    
    println("Setting hydro generator pmin for hour $(Dates.hour(initial_hour))...")
    println("  MER run mode: $mer_run")
    
    if !mer_run
        println("  Non-MER run: Skipping hydro pmin adjustment")
        return
    end
    
    # Calculate the hour index (1-8760) from initial_hour
    year_start = DateTime(load_year, 1, 1, 0, 0, 0)
    hour_index = Int(Dates.value(initial_hour - year_start) / (1000 * 60 * 60)) + 1
    
    # Read from hourly baseline results
    hourly_results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/BASEHourlySimulations_UC_noreserve_newre/hour_$(hour_index)"
    results_dir = joinpath(hourly_results_dir, "results")
    hydro_file = joinpath(results_dir, "ActivePowerVariable__HydroDispatch_ED.csv")
    
    println("  Reading from: $hydro_file")
    
    if isfile(hydro_file)
        df = CSV.read(hydro_file, DataFrame)
        matching_row = filter(row -> row.DateTime == initial_hour, df)
        
        if nrow(matching_row) == 0
            @warn "No matching row found for initial_hour: $initial_hour. Skipping hydro initialization."
            return
        end
        
        for hydro in get_available_components(HydroDispatch, sys)
            hydro_name = PSY.get_name(hydro)
            
            if hydro_name in names(df)
                initial_power = matching_row[1, hydro_name]
                original_pmin = PSY.get_active_power_limits(hydro).min
                pmax = PSY.get_active_power_limits(hydro).max
                
                # MER run: Adjust pmin to baseline active power
                new_pmin = max(initial_power, original_pmin)
                new_pmax = PSY.get_active_power_limits(hydro).max
                if new_pmin > new_pmax
                    new_pmin = new_pmax
                end
                PSY.set_active_power_limits!(hydro, PSY.MinMax((new_pmin, new_pmax)))

                println("    Set $hydro_name pmin adjusted from $(original_pmin) to $(new_pmin) MW (pmax: $(pmax) MW)")
            end
        end
    else
        @warn "ActivePowerVariable__HydroDispatch_ED.csv not found in $results_dir"
    end
end

function run_simulation_for_hour(hour::Int, sys, output_dir, interval, horizon, steps, baseline_results_path)
    """Run simulation for a specific hour."""
    
    println("\\n" * "="^70)
    println("Running simulation for Hour $hour")
    println("="^70)
    
    try
        # Calculate initial time for this hour (hour is 1-8760)
        year_start = DateTime(load_year, 1, 1, 0, 0, 0)
        initial_time = year_start + Hour(hour - 1)
        
        println("Initial time: $initial_time")
        if mer_run
        # Set initial conditions from baseline
            set_initial_storage_levels!(sys, baseline_results_path, initial_time)
            set_initial_thermal_states!(sys, baseline_results_path, initial_time, mer_run)
            set_hydro_pmin!(sys, baseline_results_path, initial_time, mer_run)
        end
        # set_re_pmin!(sys, baseline_results_path, initial_time, mer_run)
        # Set up simulation template
        template_uc = setup_simulation_template(sys)
        
        # Print system summary
        num_buses = length(get_components(PSY.Bus, sys))
        num_loads = length(get_components(PSY.StandardLoad, sys))
        num_generators = length(get_components(PSY.ThermalStandard, sys))
        num_storage = length(get_components(EnergyReservoirStorage, sys))
        
        println("System summary:")
        println("  Buses: $num_buses")
        println("  Loads: $num_loads")
        println("  Generators: $num_generators")
        println("  Storage: $num_storage")
        
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
        
        sequence = SimulationSequence(models=models, ini_cond_chronology=InterProblemChronology())
        
        sim_name = "hour_$(hour)"
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
        
        println("✓ Simulation for hour $hour completed successfully!")
        println("  Results saved to: $(results.path)")
        
        return (
            hour = hour,
            status = "success", 
            results_path = results.path,
            buses = num_buses,
            loads = num_loads,
            generators = num_generators,
            storage = num_storage
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
            generators = 0,
            storage = 0
        )
    end
end

function main(start_hour::Int, end_hour::Int)
    """Main function to run simulation for hours from start_hour to end_hour."""
    
    println("="^80)
    println("HOURLY SIMULATION WITH LOAD ADDITION")
    println("Baseline system: $baseline_system_path")
    println("Baseline results: $baseline_results_path")
    println("Load addition: 1 MW to bus 65 for each hour in hour_list")
    println("Hour range: $start_hour to $end_hour")
    println("="^80)
    
    # Extract generator and storage time series from baseline
    generator_timeseries = extract_generator_timeseries(baseline_results_path)
    storage_timeseries = extract_storage_timeseries(baseline_results_path)
    
    # Create base output directory
    if !ispath(base_output_dir)
        mkpath(base_output_dir)
    end
    
    # Run simulation for all hours
    interval = 1
    horizon = 1
    steps = 1
    hour_list = collect(start_hour:end_hour)
    
    results = []
    for hour_id in hour_list
        println("\n" * "="^80)
        println("Processing hour $hour_id of $(length(hour_list))")
        println("="^80)
        
        # Load baseline system fresh for each hour
        sys = load_baseline_system()
        
        if mer_run
            # Add 1 MW load to bus 65 for this specific hour
            sys = add_load_to_bus(sys, "65", 1.0, hour_id)
        end
       
        
        # Convert AggGen generators to loads
        sys = convert_generators_to_loads(sys, generator_timeseries)
        
        # Extract renewable data for this specific hour and fix to baseline
        # renewable_timeseries_hour = extract_renewable_timeseries(baseline_results_path, hour_id)
        # sys = fix_renewable_to_baseline(sys, renewable_timeseries_hour, hour_id, mer_run)
        
        # Fix storage to baseline values
        sys = fix_storage_to_baseline(sys, storage_timeseries, hour_id)
        
        # Create hour-specific output directory
        hour_output_dir = base_output_dir
        if !ispath(hour_output_dir)
            mkpath(hour_output_dir)
        end
        
        result = run_simulation_for_hour(hour_id, sys, hour_output_dir, interval, horizon, steps, baseline_results_path)
        push!(results, result)
    end
    
    # Summary
    successful = count(r -> r.status == "success", results)
    failed = count(r -> r.status == "failed", results)
    
    println("\\n" * "="^80)
    println("ALL HOURLY SIMULATIONS COMPLETE")
    println("  Total hours: $(length(results))")
    println("  Successful: $successful")
    println("  Failed: $failed")
    println("="^80)
    
    return results
end

# Parse command line arguments
if length(ARGS) >= 2
    start_hour = parse(Int, ARGS[1])
    end_hour = parse(Int, ARGS[2])
    println("Running hours $start_hour to $end_hour")
    main(start_hour, end_hour)
else
    error("Usage: julia setup_hourly_simulation_load_addition.jl <start_hour> <end_hour>")
end
