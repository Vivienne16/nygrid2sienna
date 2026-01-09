using CSV
using DataFrames
using Statistics

"""
Calculate aggregated storage intensity from storage charge/discharge data.

This script reads ActivePowerInVariable and ActivePowerOutVariable files for storage
and calculates a single aggregated carbon intensity for all storage units combined.
"""

# Configuration
RESULTS_DIR = "MERHourlySimulations_UC/baseline_simulation/results"

function find_storage_files(directory)
    """Find all storage-related power files in the directory"""
    files = readdir(directory)
    
    storage_in_files = filter(f -> startswith(f, "ActivePowerInVariable__") && 
                                  contains(f, "Storage"), files)
    storage_out_files = filter(f -> startswith(f, "ActivePowerOutVariable__") && 
                                   contains(f, "Storage"), files)
    thermal_files = filter(f -> startswith(f, "ActivePowerVariable__") && 
                                contains(f, "Thermal"), files)
    hydro_files = filter(f -> startswith(f, "ActivePowerVariable__") && 
                              contains(f, "Hydro"), files)
    renewable_files = filter(f -> startswith(f, "ActivePowerVariable__") && 
                                  contains(f, "Renewable"), files)
    
    return storage_in_files, storage_out_files, thermal_files, hydro_files, renewable_files
end

function load_thermal_emission_factors()
    """Load emission factors from config files for all generator types"""
    config_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/config"
    
    emission_factors = Dict{String, Float64}()
    
    # Load thermal emission factors
    thermal_config_path = joinpath(config_dir, "thermal_config.csv")
    if isfile(thermal_config_path)
        df = CSV.read(thermal_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.Name] = row.emissionFactor * row.HeatRateLM_1
        end
    end
    
    # Load hydro emission factors (all zero)
    hydro_config_path = joinpath(config_dir, "hydro_config.csv")
    if isfile(hydro_config_path)
        df = CSV.read(hydro_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.Name] = 0.0
        end
    end
    
    # Load wind emission factors (all zero)
    wind_config_path = joinpath(config_dir, "wind_config.csv")
    if isfile(wind_config_path)
        df = CSV.read(wind_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.name] = 0.0
        end
    end
    
    # Load solar PV emission factors (all zero)
    upv_config_path = joinpath(config_dir, "upv_config.csv")
    if isfile(upv_config_path)
        df = CSV.read(upv_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.name] = 0.0
        end
    end
    
    # Load distributed solar PV emission factors (all zero)
    dpv_config_path = joinpath(config_dir, "dpv_config.csv")
    if isfile(dpv_config_path)
        df = CSV.read(dpv_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.name] = 0.0
        end
    end
    
    # Load nuclear emission factors (all zero)
    nuclear_config_path = joinpath(config_dir, "nuclear_config.csv")
    if isfile(nuclear_config_path)
        df = CSV.read(nuclear_config_path, DataFrame)
        for row in eachrow(df)
            emission_factors[row.Name] = 0.0
        end
    end
    
    return emission_factors
end

function extract_generator_name(column_name)
    """Extract generator name from column name"""
    name = replace(column_name, r"^(ActivePower|Power)" => "")
    name = replace(name, r"__(ED|RT|DA)$" => "")
    return strip(name, ['_'])
end

function calculate_aggregated_storage_intensity_hourly(storage_in_df, storage_out_df, thermal_df, hydro_df, renewable_df, emission_factors)
    """Calculate aggregated storage intensity hour by hour for all storage units combined"""
    
    timesteps_per_hour = 1  # Assume hourly data
    
    # Calculate number of complete hours
    max_timesteps = min(nrow(storage_in_df), nrow(storage_out_df))
    
    println("Debug: Data dimensions:")
    println("  Storage in: $(nrow(storage_in_df)) rows")
    println("  Storage out: $(nrow(storage_out_df)) rows")
    
    if !isempty(thermal_df)
        max_timesteps = min(max_timesteps, nrow(thermal_df))
        println("  Thermal: $(nrow(thermal_df)) rows")
    end
    if !isempty(hydro_df)
        max_timesteps = min(max_timesteps, nrow(hydro_df))
        println("  Hydro: $(nrow(hydro_df)) rows")
    end
    if !isempty(renewable_df)
        max_timesteps = min(max_timesteps, nrow(renewable_df))
        println("  Renewable: $(nrow(renewable_df)) rows")
    end
    
    num_hours = div(max_timesteps, timesteps_per_hour)
    
    println("  Max timesteps: $max_timesteps")
    println("  Number of hours: $num_hours")
    
    # Initialize tracking for aggregated storage (start empty at hour 0)
    aggregated_tracking = Dict(
        "energy" => 0.0,      # Total energy stored across all units (MWh)
        "carbon" => 0.0,      # Total carbon stored across all units (kg CO2)
        "avg_intensity" => 0.0  # Current average intensity
    )
    
    # Initialize hourly results DataFrame
    results = DataFrame()
    
    # Create hour timestamps
    hour_timestamps = []
    for hour in 1:num_hours
        timestep = (hour - 1) * timesteps_per_hour + 1
        push!(hour_timestamps, storage_in_df[timestep, 1])
    end
    results[!, names(storage_in_df)[1]] = hour_timestamps
    
    # Initialize result columns for aggregated storage
    results[!, "aggregated_energy_stored"] = zeros(Float64, num_hours)
    results[!, "aggregated_carbon_stored"] = zeros(Float64, num_hours)
    results[!, "aggregated_avg_intensity"] = zeros(Float64, num_hours)
    results[!, "aggregated_charge_amount"] = zeros(Float64, num_hours)
    results[!, "aggregated_discharge_amount"] = zeros(Float64, num_hours)
    results[!, "aggregated_net_change"] = zeros(Float64, num_hours)
    results[!, "grid_intensity"] = zeros(Float64, num_hours)
    
    # Process each hour
    for hour in 1:num_hours
        start_timestep = (hour - 1) * timesteps_per_hour + 1
        end_timestep = hour * timesteps_per_hour
        
        # Calculate average grid intensity for this hour
        hour_total_power = 0.0
        hour_total_emissions = 0.0
        
        for timestep in start_timestep:end_timestep
            total_power = 0.0
            total_emissions = 0.0
            
            # Process thermal generation (excluding AggGen)
            if !isempty(thermal_df) && timestep <= nrow(thermal_df)
                row = thermal_df[timestep, :]
                for col in names(thermal_df)
                    if col == names(thermal_df)[1]  # Skip timestamp column
                        continue
                    end
                    
                    gen_name = extract_generator_name(col)
                    
                    # Skip generators with "AggGen" in the name
                    if contains(gen_name, "AggGen")
                        continue
                    end
                    
                    power = row[col]
                    
                    if !ismissing(power) && abs(power) > 1e-6 && power > 0
                        if !haskey(emission_factors, gen_name)
                            # Skip generators not in config (like imports)
                            if contains(lowercase(gen_name), "import")
                                println("  Skipping import generator: $gen_name")
                                continue
                            else
                                error("Emission factor not found for generator: $gen_name")
                            end
                        end
                        
                        emission_factor = emission_factors[gen_name]
                        total_power += power
                        total_emissions += power * emission_factor
                    end
                end
            end
            
            # Process hydro generation (zero emissions)
            if !isempty(hydro_df) && timestep <= nrow(hydro_df)
                row = hydro_df[timestep, :]
                for col in names(hydro_df)
                    if col == names(hydro_df)[1]
                        continue
                    end
                    
                    power = row[col]
                    if !ismissing(power) && power > 0
                        total_power += power
                    end
                end
            end
            
            # Process renewable generation (zero emissions)
            if !isempty(renewable_df) && timestep <= nrow(renewable_df)
                row = renewable_df[timestep, :]
                for col in names(renewable_df)
                    if col == names(renewable_df)[1]
                        continue
                    end
                    
                    power = row[col]
                    if !ismissing(power) && power > 0
                        total_power += power
                    end
                end
            end
            
            hour_total_power += total_power
            hour_total_emissions += total_emissions
        end
        
        # Calculate average grid intensity for the hour
        hour_grid_intensity = hour_total_emissions / hour_total_power
        
        # Aggregate charge and discharge across all storage units for this hour
        hour_total_charge = 0.0
        hour_total_discharge = 0.0
        
        for timestep in start_timestep:end_timestep
            # Sum all charging
            if timestep <= nrow(storage_in_df)
                for col in names(storage_in_df)
                    if col != names(storage_in_df)[1]  # Skip timestamp
                        charge_val = storage_in_df[timestep, col]
                        if !ismissing(charge_val)
                            hour_total_charge += charge_val
                        end
                    end
                end
            end
            
            # Sum all discharging
            if timestep <= nrow(storage_out_df)
                for col in names(storage_out_df)
                    if col != names(storage_out_df)[1]  # Skip timestamp
                        discharge_val = storage_out_df[timestep, col]
                        if !ismissing(discharge_val)
                            hour_total_discharge += discharge_val
                        end
                    end
                end
            end
        end
        
        # Update aggregated storage tracking
        # Handle charging: add energy and carbon with weighted average intensity
        if hour_total_charge > 0
            if aggregated_tracking["energy"] > 0
                # Weight average: existing carbon + new carbon
                old_carbon = aggregated_tracking["carbon"]
                new_carbon = hour_total_charge * hour_grid_intensity
                total_energy = aggregated_tracking["energy"] + hour_total_charge
                
                aggregated_tracking["energy"] = total_energy
                aggregated_tracking["carbon"] = old_carbon + new_carbon
            else
                # First charge: just add the carbon
                aggregated_tracking["energy"] = hour_total_charge
                aggregated_tracking["carbon"] = hour_total_charge * hour_grid_intensity
            end
        end
        
        # Handle discharging: remove energy and proportional carbon
        if hour_total_discharge > 0 && aggregated_tracking["energy"] > 0
            # Use current stored intensity
            current_intensity = aggregated_tracking["carbon"] / aggregated_tracking["energy"]
            
            # Remove proportional carbon and energy
            carbon_discharged = min(hour_total_discharge * current_intensity, aggregated_tracking["carbon"])
            energy_discharged = min(hour_total_discharge, aggregated_tracking["energy"])
            
            aggregated_tracking["energy"] -= energy_discharged
            aggregated_tracking["carbon"] -= carbon_discharged
        end
        
        # Update average intensity
        aggregated_tracking["avg_intensity"] = aggregated_tracking["energy"] > 0 ? 
                                               aggregated_tracking["carbon"] / aggregated_tracking["energy"] : 0.0
        
        # Store hourly results
        results[hour, "aggregated_energy_stored"] = aggregated_tracking["energy"]
        results[hour, "aggregated_carbon_stored"] = aggregated_tracking["carbon"]
        results[hour, "aggregated_avg_intensity"] = aggregated_tracking["avg_intensity"]
        results[hour, "aggregated_charge_amount"] = hour_total_charge
        results[hour, "aggregated_discharge_amount"] = hour_total_discharge
        results[hour, "aggregated_net_change"] = hour_total_discharge - hour_total_charge
        results[hour, "grid_intensity"] = hour_grid_intensity
    end
    
    return results, aggregated_tracking
end

function save_results(results, output_dir="storage_intensity_results")
    """Save aggregated storage intensity analysis results"""
    
    # Create output directory
    if !isdir(output_dir)
        mkdir(output_dir)
    end
    
    # Save hourly results
    hourly_file = joinpath(output_dir, "aggregated_storage_intensity_hourly.csv")
    CSV.write(hourly_file, results)
    
    # Calculate and save summary statistics
    summary_stats = DataFrame(
        metric = [
            "final_energy_stored",
            "final_carbon_stored",
            "final_avg_intensity",
            "average_intensity",
            "total_charge_mwh",
            "total_discharge_mwh",
            "net_discharge_mwh",
            "mean_grid_intensity"
        ],
        value = [
            last(results[!, "aggregated_energy_stored"]),
            last(results[!, "aggregated_carbon_stored"]),
            last(results[!, "aggregated_avg_intensity"]),
            mean(filter(!isnan, results[!, "aggregated_avg_intensity"])),
            sum(results[!, "aggregated_charge_amount"]),
            sum(results[!, "aggregated_discharge_amount"]),
            sum(results[!, "aggregated_net_change"]),
            mean(results[!, "grid_intensity"])
        ]
    )
    
    summary_file = joinpath(output_dir, "aggregated_storage_intensity_summary.csv")
    CSV.write(summary_file, summary_stats)
    
    return summary_stats
end

# Main execution
storage_in_files, storage_out_files, thermal_files, hydro_files, renewable_files = find_storage_files(RESULTS_DIR)

println("Debug: Found files:")
println("  Storage in: $storage_in_files")
println("  Storage out: $storage_out_files")
println("  Thermal: $thermal_files")
println("  Hydro: $hydro_files")  
println("  Renewable: $renewable_files")

emission_factors = load_thermal_emission_factors()

storage_in_file = joinpath(RESULTS_DIR, storage_in_files[1])
storage_out_file = joinpath(RESULTS_DIR, storage_out_files[1])

storage_in_df = CSV.read(storage_in_file, DataFrame)
storage_out_df = CSV.read(storage_out_file, DataFrame)

thermal_df = DataFrame()
hydro_df = DataFrame()
renewable_df = DataFrame()

if !isempty(thermal_files)
    thermal_file = joinpath(RESULTS_DIR, thermal_files[1])
    thermal_df = CSV.read(thermal_file, DataFrame)
end

if !isempty(hydro_files)
    hydro_file = joinpath(RESULTS_DIR, hydro_files[1])
    hydro_df = CSV.read(hydro_file, DataFrame)
end

if !isempty(renewable_files)
    renewable_file = joinpath(RESULTS_DIR, renewable_files[1])
    renewable_df = CSV.read(renewable_file, DataFrame)
end

results, final_tracking = calculate_aggregated_storage_intensity_hourly(storage_in_df, storage_out_df, thermal_df, hydro_df, renewable_df, emission_factors)

summary_stats = save_results(results)

println("\n" * "="^80)
println("AGGREGATED STORAGE INTENSITY SUMMARY")
println("="^80)
println(summary_stats)
println("="^80)

CSV.write("/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation/aggregated_storage_intensity_hourly_UC.csv", results)
println("\nResults saved to: /home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation/aggregated_storage_intensity_hourly_UC.csv")
