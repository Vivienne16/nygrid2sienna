using CSV
using DataFrames
using Statistics

"""
Calculate accumulated storage intensity from storage charge/discharge data.

This script reads ActivePowerInVariable and ActivePowerOutVariable files for storage
and calculates the accumulated carbon intensity based on charging/discharging patterns.
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
            # Map fuel type to emission factor
            
            emission_factors[row.Name] = row.emissionFactor * row.HeatRateLM_1  # Default to natural gas
            
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
    # Remove common suffixes and prefixes
    name = replace(column_name, r"^(ActivePower|Power)" => "")
    name = replace(name, r"__(ED|RT|DA)$" => "")
    return strip(name, ['_'])
end

function calculate_grid_intensity(thermal_df, hydro_df, renewable_df, emission_factors, timestep)
    """Calculate grid emission intensity for a specific timestep based on all generation"""
    total_power = 0.0
    total_emissions = 0.0
    
    # Process thermal generation
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
                # Check if generator is in emission factors
                if !haskey(emission_factors, gen_name)
                    error("Emission factor not found for generator: $gen_name")
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
            if col == names(hydro_df)[1]  # Skip timestamp column
                continue
            end
            
            power = row[col]
            if !ismissing(power) && power > 0
                total_power += power
                # total_emissions += 0 (hydro has zero emissions)
            end
        end
    end
    
    # Process renewable generation (zero emissions)
    if !isempty(renewable_df) && timestep <= nrow(renewable_df)
        row = renewable_df[timestep, :]
        for col in names(renewable_df)
            if col == names(renewable_df)[1]  # Skip timestamp column
                continue
            end
            
            power = row[col]
            if !ismissing(power) && power > 0
                total_power += power
                # total_emissions += 0 (renewables have zero emissions)
            end
        end
    end
    
    return total_emissions / total_power
end

function calculate_storage_intensity_hourly(storage_in_df, storage_out_df, thermal_df, hydro_df, renewable_df, emission_factors)
    """Calculate accumulated storage intensity hour by hour"""
    
    # Determine timesteps per hour based on data resolution
    # Most common: 1 = hourly, 4 = 15-min, 12 = 5-min
    timesteps_per_hour = 1  # Assume hourly data
    
    # Track missing thermal generators
    missing_thermal_gens = Set{String}()
    found_thermal_gens = Set{String}()
    
    # Check thermal generators against config
    if !isempty(thermal_df)
        for col in names(thermal_df)
            if col != names(thermal_df)[1]  # Skip timestamp column
                gen_name = extract_generator_name(col)
                if haskey(emission_factors, gen_name)
                    push!(found_thermal_gens, gen_name)
                else
                    push!(missing_thermal_gens, gen_name)
                end
            end
        end
        
        if !isempty(missing_thermal_gens)
            println("Warning: Thermal generators not found in config:")
            for gen in missing_thermal_gens
                agg_status = contains(gen, "AggGen") ? " (AggGen - using natural gas)" : " (using default natural gas)"
                println("  - $gen$agg_status")
            end
        end
        
        println("Found $(length(found_thermal_gens)) thermal generators in config")
        println("Missing $(length(missing_thermal_gens)) thermal generators from config")
    end
    
    # Get storage unit names from column names
    storage_units = Set{String}()
    
    for col in names(storage_in_df)
        if col != names(storage_in_df)[1]  # Skip timestamp
            unit_name = extract_generator_name(col)
            push!(storage_units, unit_name)
        end
    end
    
    for col in names(storage_out_df)
        if col != names(storage_out_df)[1]  # Skip timestamp
            unit_name = extract_generator_name(col)
            push!(storage_units, unit_name)
        end
    end
    
    # Calculate number of complete hours
    max_timesteps = min(nrow(storage_in_df), nrow(storage_out_df))
    
    println("Debug: Data dimensions:")
    println("  Storage in: $(nrow(storage_in_df)) rows")
    println("  Storage out: $(nrow(storage_out_df)) rows")
    
    # Check the first few timestamps to understand time resolution
    println("  First few timestamps:")
    for i in 1:min(5, nrow(storage_in_df))
        println("    Row $i: $(storage_in_df[i, 1])")
    end
    
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
    println("  Timesteps per hour: $timesteps_per_hour")
    println("  Number of hours: $num_hours")
    
    # Initialize tracking for each storage unit (start empty at hour 0)
    storage_tracking = Dict{String, Dict{String, Float64}}()
    for unit in storage_units
        storage_tracking[unit] = Dict(
            "energy" => 0.0,      # Total energy stored (MWh)
            "carbon" => 0.0,      # Total carbon stored (kg CO2)
            "avg_intensity" => 0.0  # Current average intensity
        )
    end
    
    # Initialize hourly results DataFrame
    results = DataFrame()
    
    # Create hour timestamps (take first timestamp of each hour)
    hour_timestamps = []
    for hour in 1:num_hours
        timestep = (hour - 1) * timesteps_per_hour + 1
        push!(hour_timestamps, storage_in_df[timestep, 1])
    end
    results[!, names(storage_in_df)[1]] = hour_timestamps
    
    # Initialize result columns
    for unit in storage_units
        results[!, "$(unit)_energy_stored"] = zeros(Float64, num_hours)
        results[!, "$(unit)_carbon_stored"] = zeros(Float64, num_hours)
        results[!, "$(unit)_avg_intensity"] = zeros(Float64, num_hours)
        results[!, "$(unit)_charge_amount"] = zeros(Float64, num_hours)
        results[!, "$(unit)_discharge_amount"] = zeros(Float64, num_hours)
        results[!, "$(unit)_net_change"] = zeros(Float64, num_hours)
    end
    
    # Process each hour
    for hour in 1:num_hours
        start_timestep = (hour - 1) * timesteps_per_hour + 1
        end_timestep = hour * timesteps_per_hour
        
        # Calculate average grid intensity for this hour
        hour_total_power = 0.0
        hour_total_emissions = 0.0
        
        for timestep in start_timestep:end_timestep
            # Calculate grid intensity for this timestep
            total_power = 0.0
            total_emissions = 0.0
            
            # Process thermal generation
            if !isempty(thermal_df) && timestep <= nrow(thermal_df)
                row = thermal_df[timestep, :]
                for col in names(thermal_df)
                    if col == names(thermal_df)[1]  # Skip timestamp column
                        continue
                    end
                    
                    gen_name = extract_generator_name(col)
                    power = row[col]
                    
                    if !ismissing(power) && abs(power) > 1e-6 && power > 0
                        # Check if generator is in emission factors, if not and has "AggGen" assume natural gas
                        emission_factor = if haskey(emission_factors, gen_name)
                            emission_factors[gen_name]
                        elseif contains(gen_name, "AggGen")
                            0.5  # Natural gas intensity for aggregated generators
                        else
                            0.5  # Default to natural gas
                        end
                        
                        total_power += power
                        total_emissions += power * emission_factor
                    end
                end
            end
            
            # Process hydro generation (zero emissions)
            if !isempty(hydro_df) && timestep <= nrow(hydro_df)
                row = hydro_df[timestep, :]
                for col in names(hydro_df)
                    if col == names(hydro_df)[1]  # Skip timestamp column
                        continue
                    end
                    
                    power = row[col]
                    if !ismissing(power) && power > 0
                        total_power += power
                        # total_emissions += 0 (hydro has zero emissions)
                    end
                end
            end
            
            # Process renewable generation (zero emissions)
            if !isempty(renewable_df) && timestep <= nrow(renewable_df)
                row = renewable_df[timestep, :]
                for col in names(renewable_df)
                    if col == names(renewable_df)[1]  # Skip timestamp column
                        continue
                    end
                    
                    power = row[col]
                    if !ismissing(power) && power > 0
                        total_power += power
                        # total_emissions += 0 (renewables have zero emissions)
                    end
                end
            end
            
            hour_total_power += total_power
            hour_total_emissions += total_emissions
        end
        
        # Calculate average grid intensity for the hour
        hour_grid_intensity =  hour_total_emissions / hour_total_power
        
        # Process each storage unit for this hour
        for unit in storage_units
            # Sum charge and discharge amounts for the hour
            hour_charge = 0.0
            hour_discharge = 0.0
            
            for timestep in start_timestep:end_timestep
                # Get charging amount
                charge_col = findfirst(col -> contains(extract_generator_name(col), unit), names(storage_in_df))
                if !isnothing(charge_col) && timestep <= nrow(storage_in_df)
                    charge_val = storage_in_df[timestep, charge_col]
                    if !ismissing(charge_val)
                        hour_charge += charge_val
                    end
                end
                
                # Get discharging amount
                discharge_col = findfirst(col -> contains(extract_generator_name(col), unit), names(storage_out_df))
                if !isnothing(discharge_col) && timestep <= nrow(storage_out_df)
                    discharge_val = storage_out_df[timestep, discharge_col]
                    if !ismissing(discharge_val)
                        hour_discharge += discharge_val
                    end
                end
            end
            
            # Update storage tracking for this unit
            unit_data = storage_tracking[unit]
            
            # Handle charging: add energy and carbon with weighted average intensity
            if hour_charge > 0
                if unit_data["energy"] > 0
                    # Weight average: existing carbon + new carbon
                    old_carbon = unit_data["carbon"]
                    new_carbon = hour_charge * hour_grid_intensity
                    total_energy = unit_data["energy"] + hour_charge
                    
                    unit_data["energy"] = total_energy
                    unit_data["carbon"] = old_carbon + new_carbon
                else
                    # First charge: just add the carbon
                    unit_data["energy"] = hour_charge
                    unit_data["carbon"] = hour_charge * hour_grid_intensity
                end
            end
            
            # Handle discharging: remove energy and proportional carbon
            if hour_discharge > 0 && unit_data["energy"] > 0
                # Use current stored intensity
                current_intensity = unit_data["carbon"] / unit_data["energy"]
                
                # Remove proportional carbon and energy
                carbon_discharged = min(hour_discharge * current_intensity, unit_data["carbon"])
                energy_discharged = min(hour_discharge, unit_data["energy"])
                
                unit_data["energy"] -= energy_discharged
                unit_data["carbon"] -= carbon_discharged
            end
            
            # Update average intensity
            unit_data["avg_intensity"] = unit_data["energy"] > 0 ? 
                                        unit_data["carbon"] / unit_data["energy"] : 0.0
            
            # Store hourly results
            results[hour, "$(unit)_energy_stored"] = unit_data["energy"]
            results[hour, "$(unit)_carbon_stored"] = unit_data["carbon"]
            results[hour, "$(unit)_avg_intensity"] = unit_data["avg_intensity"]
            results[hour, "$(unit)_charge_amount"] = hour_charge
            results[hour, "$(unit)_discharge_amount"] = hour_discharge
            results[hour, "$(unit)_net_change"] = hour_discharge - hour_charge
        end
    end
    
    return results, storage_tracking
end

function save_results(results, output_dir="storage_intensity_results")
    """Save storage intensity analysis results"""
    
    # Create output directory
    if !isdir(output_dir)
        mkdir(output_dir)
    end
    
    # Save hourly results
    hourly_file = joinpath(output_dir, "storage_intensity_hourly.csv")
    CSV.write(hourly_file, results)
    
    # Calculate and save summary statistics
    summary_stats = DataFrame()
    
    storage_units = []
    for col in names(results)
        if endswith(col, "_avg_intensity")
            unit = replace(col, "_avg_intensity" => "")
            push!(storage_units, unit)
        end
    end
    
    for unit in storage_units
        energy_col = "$(unit)_energy_stored"
        intensity_col = "$(unit)_avg_intensity"
        charge_col = "$(unit)_charge_amount"
        discharge_col = "$(unit)_discharge_amount"
        
        if all(c -> c in names(results), [energy_col, intensity_col, charge_col, discharge_col])
            final_energy = last(results[!, energy_col])
            avg_intensity = mean(filter(!isnan, results[!, intensity_col]))
            final_intensity = last(results[!, intensity_col])
            total_charge = sum(results[!, charge_col])
            total_discharge = sum(results[!, discharge_col])
            
            push!(summary_stats, (
                unit = unit,
                final_energy_stored = final_energy,
                average_intensity = avg_intensity,
                final_intensity = final_intensity,
                total_charge_mwh = total_charge,
                total_discharge_mwh = total_discharge,
                net_discharge_mwh = total_discharge - total_charge
            ))
        end
    end
    
    summary_file = joinpath(output_dir, "storage_intensity_summary.csv")
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

results, final_tracking = calculate_storage_intensity_hourly(storage_in_df, storage_out_df, thermal_df, hydro_df, renewable_df, emission_factors)

summary_stats = save_results(results)

CSV.write("/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation/storage_intensity_hourly_UC.csv", results)