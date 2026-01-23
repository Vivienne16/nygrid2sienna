using CSV
using DataFrames
using Statistics
using Glob
using Dates

"""
Calculate Marginal Emission Rate (MER) for each hourly comparison result.

This script loops through hourly comparison results and calculates MER
for each specific hour using only the comparison data from that hour's folder.

MER = Σ(ΔPower_i × EmissionFactor_i) / Σ(ΔPower_i)

where:
- ΔPower_i is the change in power output for generator i
- EmissionFactor_i is the emission factor for generator i (kg CO2/MWh)
"""

# Emission factors by fuel type (kg CO2/MWh)
# const EMISSION_FACTORS = Dict(
#     "Natural Gas" => 820.0,     # kg CO2/MWh for combined cycle
#     "Coal" => 2200.0,           # kg CO2/MWh for coal
#     "Oil" => 1800.0,            # kg CO2/MWh for oil
#     "Fuel Oil 2" => 1850.0,     # kg CO2/MWh for fuel oil 2 (distillate)
#     "Fuel Oil 6" => 1900.0,     # kg CO2/MWh for fuel oil 6 (residual)
#     "Kerosene" => 1900.0,       # kg CO2/MWh for kerosene
#     "Diesel" => 1900.0,         # kg CO2/MWh for diesel
#     "Nuclear" => 0.0,           # kg CO2/MWh for nuclear
#     "Hydro" => 0.0,             # kg CO2/MWh for hydro
#     "Wind" => 0.0,              # kg CO2/MWh for wind
#     "Solar" => 0.0,             # kg CO2/MWh for solar
#     "AggGen" => 850.0           # kg CO2/MWh for aggregated generators (Natural Gas + 30)
# )
const EMISSION_FACTORS = Dict(
    # "Natural Gas" => 820.0,     # kg CO2/MWh for combined cycle
    # "Coal" => 2200.0,           # kg CO2/MWh for coal
    # "Oil" => 1800.0,            # kg CO2/MWh for oil
    # "Fuel Oil 2" => 1850.0,     # kg CO2/MWh for fuel oil 2 (distillate)
    # "Fuel Oil 6" => 1900.0,     # kg CO2/MWh for fuel oil 6 (residual)
    # "Kerosene" => 1900.0,       # kg CO2/MWh for kerosene
    # "Diesel" => 1900.0,         # kg CO2/MWh for diesel
    "Nuclear" => 0.0,           # kg CO2/MWh for nuclear
    "Hydro" => 0.0,             # kg CO2/MWh for hydro
    "Wind" => 0.0,              # kg CO2/MWh for wind
    "Solar" => 0.0,             # kg CO2/MWh for solar
    "AggGen" => 0.06           # kg CO2/MWh for aggregated generators (Natural Gas + 30)
)

# Configuration
hourly_comparison_base = "comparison_bus65_vs_load_addition"
mer_results_base = "merged_hourly_mer_results_bus65_vs_load_addition"
!isdir(mer_results_base) && mkpath(mer_results_base)

function load_thermal_config()
    """Load thermal generator configuration with fuel types and emission factors"""
    config_path = "config/thermal_config.csv"
    
    if !isfile(config_path)
        @warn "Thermal config file not found: $config_path"
        return DataFrame()
    end
    
    df = CSV.read(config_path, DataFrame)
    
    # Add emission factors based on fuel type
    df.emission_factor = map(row -> row.emissionFactor * row.HeatRateLM_1, eachrow(df))
    
    return df
end

function load_agggen_config()
    """Load aggregated generator configuration with zones"""
    config_path = "config/agggen_config.csv"
    
    if !isfile(config_path)
        @warn "AggGen config file not found: $config_path"
        return DataFrame()
    end
    
    df = CSV.read(config_path, DataFrame)
    
    # Add emission factors for AggGens (Natural Gas + 30)
    df.emission_factor = map(name -> contains(name, "AggGen") ? EMISSION_FACTORS["AggGen"] : 0.0, df.Name)
    
    return df
end

function load_storage_intensity()
    """Load aggregated hourly storage intensity from baseline simulation"""
    intensity_path = "MERHourlySimulations_UC/baseline_simulation/aggregated_storage_intensity_hourly_UC.csv"
    
    if !isfile(intensity_path)
        @warn "Aggregated storage intensity file not found: $intensity_path"
        return DataFrame()
    end
    
    df = CSV.read(intensity_path, DataFrame)
    
    return df
end

function load_hourly_power_differences(hour_dir)
    """Load all power difference CSV files from a specific hourly comparison directory"""
    
    if !isdir(hour_dir)
        error("Hour directory not found: $hour_dir")
    end
    
    # Get all difference CSV files for this hour
    diff_files = filter(f -> endswith(f, "_differences.csv"), readdir(hour_dir))
    
    power_diffs = Dict()
    
    for file in diff_files
        filepath = joinpath(hour_dir, file)
        df = CSV.read(filepath, DataFrame)
        
        # Extract the type from filename - remove hour suffix
        # e.g., "ActivePowerVariable__ThermalStandard_hour_1_differences.csv" 
        # -> "ActivePowerVariable__ThermalStandard_ED"
        file_type = replace(file, r"_hour_\d+_differences\.csv$" => "_ED")
        power_diffs[file_type] = df
        
        println("  Loaded: $file ($(nrow(df)) rows, $(ncol(df)) columns)")
    end
    
    return power_diffs
end

function extract_generator_name(column_name)
    """Extract generator name from column name by removing '_diff' suffix"""
    return replace(column_name, "_diff" => "")
end

function aggregate_agggen_by_zone(thermal_df, agggen_config)
    """Aggregate AggGen power differences by zone"""
    
    # Create zone lookup for AggGens
    zone_lookup = Dict(row.Name => row.Zone for row in eachrow(agggen_config))
    
    # Find all AggGen columns
    agggen_cols = filter(col -> startswith(extract_generator_name(col), "AggGen"), 
                        filter(col -> endswith(col, "_diff"), names(thermal_df)))
    
    if isempty(agggen_cols)
        return thermal_df, Dict{String, Float64}()
    end
    
    # Get unique zones
    zones = unique([zone_lookup[extract_generator_name(col)] for col in agggen_cols if haskey(zone_lookup, extract_generator_name(col))])
    
    # Create new DataFrame without individual AggGen columns
    new_df = select(thermal_df, Not(agggen_cols))
    
    # Add aggregated zone columns
    zone_emission_factors = Dict{String, Float64}()
    
    for zone in zones
        zone_cols = filter(col -> haskey(zone_lookup, extract_generator_name(col)) && 
                          zone_lookup[extract_generator_name(col)] == zone, agggen_cols)
        
        if !isempty(zone_cols)
            # Sum power differences for this zone
            zone_col_name = "$(zone)_AggGen_diff"
            new_df[!, zone_col_name] = sum(eachcol(thermal_df[!, zone_cols]))
            
            # Store emission factor for this zone
            zone_emission_factors[replace(zone_col_name, "_diff" => "")] = EMISSION_FACTORS["AggGen"]
            
            println("    Aggregated $(length(zone_cols)) AggGen units in zone $zone")
        end
    end
    
    return new_df, zone_emission_factors
end

function calculate_hourly_mer(power_diffs, thermal_config, agggen_config, storage_intensity_df, hour)
    """Calculate MER for a specific hour using its power differences"""
    
    # Create lookup dictionary for emission factors (thermal generators)
    emission_lookup = Dict(row.Name => row.emission_factor for row in eachrow(thermal_config))
    
    results = DataFrame()
    
    # Process thermal generation differences
    if haskey(power_diffs, "ActivePowerVariable__ThermalStandard_ED_ED")
        thermal_df = power_diffs["ActivePowerVariable__ThermalStandard_ED_ED"]

        # Aggregate AggGen units by zone
        println("    Aggregating AggGen units by zone...")
        thermal_df_agg, zone_emission_factors = aggregate_agggen_by_zone(thermal_df, agggen_config)
        
        # Merge zone emission factors into the main lookup
        emission_lookup = merge(emission_lookup, zone_emission_factors)
        
        # Get timestamp column (first column should be DateTime)
        time_col = names(thermal_df_agg)[1]
        results[!, time_col] = thermal_df_agg[!, time_col]
        
        # Calculate MER for each timestep
        mer_values = Float64[]
        total_power_change = Float64[]
        total_emissions_change = Float64[]
        thermal_power_change = Float64[]
        thermal_emissions_change = Float64[]
        storage_power_change = Float64[]
        storage_emissions_change = Float64[]
        
        for (i, row) in enumerate(eachrow(thermal_df_agg))
            power_changes = Float64[]
            power_changes_name = String[]
            emissions_changes = Float64[]
            thermal_power_changes = Float64[]
            thermal_emissions_changes = Float64[]
            storage_power_changes = Float64[]
            storage_emissions_changes = Float64[]
            
            # Process thermal generation differences (fossil fuels + nuclear)
            for col in names(thermal_df_agg)
                if endswith(col, "_diff") && col != time_col
                    gen_name = extract_generator_name(col)
                    power_change = row[col]
                    
                    # Skip if missing or zero
                    if ismissing(power_change) || abs(power_change) < 1e-6
                        continue
                    end
                    
                    # Get emission factor for this generator/zone
                    emission_factor = get(emission_lookup, gen_name, 0.0)
                    emission_change = power_change * emission_factor
                    
                    push!(power_changes, power_change)
                    push!(power_changes_name, gen_name)
                    push!(emissions_changes, emission_change)
                    push!(thermal_power_changes, power_change)
                    push!(thermal_emissions_changes, emission_change)
                end
            end
            
            # Process renewable generation differences (wind, solar - zero emissions)
            if haskey(power_diffs, "ActivePowerVariable__RenewableDispatch_ED_ED")
                renewable_df = power_diffs["ActivePowerVariable__RenewableDispatch_ED_ED"]
                if i <= nrow(renewable_df)
                    renewable_row = renewable_df[i, :]
                    for col in names(renewable_df)
                        if endswith(col, "_diff") && col != time_col
                            power_change = renewable_row[col]
                            if !ismissing(power_change) && abs(power_change) > 1e-6
                                push!(power_changes, power_change)
                                push!(power_changes_name, extract_generator_name(col))
                                push!(emissions_changes, 0.0)  # Zero emissions
                                push!(thermal_power_changes, power_change)
                                push!(thermal_emissions_changes, 0.0)
                            end
                        end
                    end
                end
            end
            
            # Process hydro generation differences (zero emissions)
            if haskey(power_diffs, "ActivePowerVariable__HydroDispatch_ED_ED")
                hydro_df = power_diffs["ActivePowerVariable__HydroDispatch_ED_ED"]
                if i <= nrow(hydro_df)
                    hydro_row = hydro_df[i, :]
                    for col in names(hydro_df)
                        if endswith(col, "_diff") && col != time_col
                            power_change = hydro_row[col]
                            if !ismissing(power_change) && abs(power_change) > 1e-6
                                push!(power_changes, power_change)
                                push!(power_changes_name, extract_generator_name(col))
                                push!(emissions_changes, 0.0)  # Zero emissions
                                push!(thermal_power_changes, power_change)
                                push!(thermal_emissions_changes, 0.0)
                            end
                        end
                    end
                end
            end
            
            # Calculate marginal emission intensity
            total_thermal_power_change = sum(thermal_power_changes)
            total_thermal_emission_change = sum(thermal_emissions_changes)
            
            # grid_emission_intensity = abs(total_thermal_power_change) > 1e-6 ? 
            #                         total_thermal_emission_change / total_thermal_power_change : 
            #                         mean([v for v in values(emission_lookup) if v > 0])
            grid_emission_intensity = 0.4 #TODO: FIX
            # Add storage charging/discharging effects
            storage_charge_map = Dict{String, Float64}()
            storage_discharge_map = Dict{String, Float64}()

            # Collect charging amounts
            if haskey(power_diffs, "ActivePowerInVariable__EnergyReservoirStorage_ED_ED")
                storage_in_df = power_diffs["ActivePowerInVariable__EnergyReservoirStorage_ED_ED"]
                if i <= nrow(storage_in_df)
                    storage_row = storage_in_df[i, :]
                    for col in names(storage_in_df)
                        if endswith(col, "_diff") && col != time_col
                            charge_change = storage_row[col]
                            if !ismissing(charge_change) && abs(charge_change) > 1e-6
                                storage_name = extract_generator_name(col)
                                storage_charge_map[storage_name] = get(storage_charge_map, storage_name, 0.0) + charge_change
                            end
                        end
                    end
                end
            end

            # Collect discharging amounts
            if haskey(power_diffs, "ActivePowerOutVariable__EnergyReservoirStorage_ED_ED")
                storage_out_df = power_diffs["ActivePowerOutVariable__EnergyReservoirStorage_ED_ED"]
                if i <= nrow(storage_out_df)
                    storage_row = storage_out_df[i, :]
                    for col in names(storage_out_df)
                        if endswith(col, "_diff") && col != time_col
                            discharge_change = storage_row[col]
                            if !ismissing(discharge_change) && abs(discharge_change) > 1e-6
                                storage_name = extract_generator_name(col)
                                storage_discharge_map[storage_name] = get(storage_discharge_map, storage_name, 0.0) + discharge_change
                            end
                        end
                    end
                end
            end

            # Process storage net effects
            storage_units = union(keys(storage_charge_map), keys(storage_discharge_map))
            for sname in storage_units
                charge_amt = get(storage_charge_map, sname, 0.0)
                discharge_amt = get(storage_discharge_map, sname, 0.0)
                net_storage = discharge_amt - charge_amt
                
                # Get storage intensity from CSV for this timestep if available
                storage_intensity = grid_emission_intensity  # default fallback
                if !isempty(storage_intensity_df) && i <= nrow(storage_intensity_df)
                    # Look for the avg_intensity column for this storage unit
                    intensity_col = "$(sname)_avg_intensity"
                    if intensity_col in names(storage_intensity_df)
                        intensity_val = storage_intensity_df[i, intensity_col]
                        if !ismissing(intensity_val) && !isnan(intensity_val)
                            if intensity_val == 0.0
                                intensity_val = grid_emission_intensity
                            end
                            storage_intensity = intensity_val
                        end
                    end
                end
                
                emissions_net = discharge_amt * storage_intensity - charge_amt * grid_emission_intensity
                # emissions_net = net_storage * storage_intensity
                if abs(net_storage) > 1e-9
                    push!(power_changes, net_storage)
                    push!(emissions_changes, emissions_net)
                    push!(storage_power_changes, net_storage)
                    push!(storage_emissions_changes, emissions_net)
                end
            end
            
            # Calculate MER for this timestep
            total_power = sum(power_changes)
            total_emissions = sum(emissions_changes)
            thermal_power = sum(thermal_power_changes)
            thermal_emissions = sum(thermal_emissions_changes)
            storage_power = sum(storage_power_changes)
            storage_emissions = sum(storage_emissions_changes)
            
            mer = abs(total_power) > 1e-6 ? total_emissions / total_power : 0.0
            
            push!(mer_values, mer)
            push!(total_power_change, total_power)
            push!(total_emissions_change, total_emissions)
            push!(thermal_power_change, thermal_power)
            push!(thermal_emissions_change, thermal_emissions)
            push!(storage_power_change, storage_power)
            push!(storage_emissions_change, storage_emissions)
        end
        
        results.mer_kg_co2_per_mwh = mer_values
        results.thermal_power_change_mw = thermal_power_change
        results.thermal_emissions_change_kg_co2 = thermal_emissions_change
        results.net_storage_change_mw = storage_power_change
        results.storage_emissions_change_kg_co2 = storage_emissions_change
    else
        # If no thermal data, create empty results
        results = DataFrame(
            DateTime = DateTime[],
            mer_kg_co2_per_mwh = Float64[],
            thermal_power_change_mw = Float64[],
            thermal_emissions_change_kg_co2 = Float64[],
            net_storage_change_mw = Float64[],
            storage_emissions_change_kg_co2 = Float64[]
        )
    end
    
    return results
end

function calculate_summary_statistics(mer_results, hour)
    """Calculate summary statistics for MER for a specific hour"""
    
    # Filter out zero MER values for statistics
    non_zero_mer = filter(x -> abs(x) > 1e-6, mer_results.mer_kg_co2_per_mwh)
    
    if isempty(non_zero_mer)
        @warn "No non-zero MER values found for hour $hour"
        return Dict("hour" => hour, "error" => "No non-zero MER values")
    end
    
    # Check if thermal and storage columns exist
    has_thermal = all(col -> col in names(mer_results), ["thermal_power_change_mw", "thermal_emissions_change_kg_co2"])
    has_storage = all(col -> col in names(mer_results), ["net_storage_change_mw", "storage_emissions_change_kg_co2"])
    
    # Calculate total power and emissions
    total_power_change = zeros(nrow(mer_results))
    total_emissions_change = zeros(nrow(mer_results))
    
    if has_thermal
        total_power_change .+= mer_results.thermal_power_change_mw
        total_emissions_change .+= mer_results.thermal_emissions_change_kg_co2
    end
    
    if has_storage
        total_power_change .+= mer_results.net_storage_change_mw
        total_emissions_change .+= mer_results.storage_emissions_change_kg_co2
    end
    
    stats = Dict(
        "hour" => hour,
        "mean_mer" => mean(non_zero_mer),
        "median_mer" => median(non_zero_mer),
        "std_mer" => std(non_zero_mer),
        "min_mer" => minimum(non_zero_mer),
        "max_mer" => maximum(non_zero_mer),
        "q25_mer" => quantile(non_zero_mer, 0.25),
        "q75_mer" => quantile(non_zero_mer, 0.75),
        "total_timesteps" => nrow(mer_results),
        "non_zero_timesteps" => length(non_zero_mer),
        "total_power_change_gwh" => sum(total_power_change) / 1000,
        "total_emissions_change_tonnes_co2" => sum(total_emissions_change) / 1000
    )
    
    # Add thermal breakdown
    if has_thermal
        stats["thermal_power_change_gwh"] = sum(mer_results.thermal_power_change_mw) / 1000
        stats["thermal_emissions_change_tonnes_co2"] = sum(mer_results.thermal_emissions_change_kg_co2) / 1000
    else
        stats["thermal_power_change_gwh"] = 0.0
        stats["thermal_emissions_change_tonnes_co2"] = 0.0
    end
    
    # Add storage breakdown
    if has_storage
        stats["net_storage_change_gwh"] = sum(mer_results.net_storage_change_mw) / 1000
        stats["storage_emissions_change_tonnes_co2"] = sum(mer_results.storage_emissions_change_kg_co2) / 1000
    else
        stats["net_storage_change_gwh"] = 0.0
        stats["storage_emissions_change_tonnes_co2"] = 0.0
    end
    
    return stats
end

function save_hourly_mer_results(mer_results, stats, hour, output_dir)
    """Save MER calculation results for a specific hour"""
    
    # Create output directory if needed
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    # Save timestep-level results
    timestep_file = joinpath(output_dir, "mer_hour_$(lpad(hour, 2, '0'))_by_timestep.csv")
    CSV.write(timestep_file, mer_results)
    
    # Save summary statistics for this hour
    stats_df = DataFrame(
        metric = collect(keys(stats)),
        value = collect(values(stats))
    )
    
    stats_file = joinpath(output_dir, "mer_hour_$(lpad(hour, 2, '0'))_summary.csv")
    CSV.write(stats_file, stats_df)
    
    return timestep_file, stats_file
end

function find_hourly_comparison_dirs()
    """Find all hourly comparison directories"""
    
    if !isdir(hourly_comparison_base)
        error("Hourly comparison base directory not found: $hourly_comparison_base")
    end
    
    # Look for hour_XX directories
    dirs = readdir(hourly_comparison_base)
    hour_dirs = filter(d -> startswith(d, "hour_") && isdir(joinpath(hourly_comparison_base, d)), dirs)
    
    # Extract hour numbers and sort
    hour_info = []
    for dir in hour_dirs
        match_result = match(r"hour_(\d+)", dir)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            full_path = joinpath(hourly_comparison_base, dir)
            push!(hour_info, (hour=hour, dir_name=dir, path=full_path))
        end
    end
    
    # Sort by hour
    sort!(hour_info, by=x -> x.hour)
    
    return hour_info
end

function filter_by_hour_of_day(df, target_hour)
    """Filter dataframe to only include rows where the hour of day matches target_hour"""
    
    # Assume first column is DateTime
    time_col = names(df)[1]
    
    # Filter rows where hour matches
    filtered_df = filter(row -> Dates.hour(row[time_col]) == target_hour, df)
    
    return filtered_df
end

function run_all_hourly_mer_calculations()
    """Run MER calculations for all hourly comparison results"""
    
    println("="^80)
    println("BATCH MER CALCULATION FOR HOURLY COMPARISON RESULTS")
    println("="^80)
    println("Hourly comparison base: $hourly_comparison_base")
    println("Output directory: $mer_results_base")
    println()
    
    # Load configuration once
    thermal_config = load_thermal_config()
    agggen_config = load_agggen_config()
    storage_intensity_df = load_storage_intensity()
    
    # Find all hourly comparison directories
    hour_dirs = find_hourly_comparison_dirs()
    
    if isempty(hour_dirs)
        error("No hourly comparison directories found in $hourly_comparison_base")
    end
    
    println("Found $(length(hour_dirs)) hourly comparison directories:")
    for hour_info in hour_dirs
        println("  Hour $(hour_info.hour): $(hour_info.path)")
    end
    println()
    
    # Create main output directory
    if !isdir(mer_results_base)
        mkpath(mer_results_base)
    end
    
    # Process each hour
    all_results = []
    all_stats = []
    all_filtered_results = []  # Store filtered results for combining
    total_hours = length(hour_dirs)
    
    for (i, hour_info) in enumerate(hour_dirs)
        current_hour = hour_info.hour
        hour_dir = hour_info.path
        
        println("--- Processing Hour $current_hour ($i of $total_hours) ---")
        
        try
            # Load power differences for this hour
            println("  Loading power differences for hour $current_hour...")
            power_diffs = load_hourly_power_differences(hour_dir)
            
            if isempty(power_diffs)
                println("  ⚠️  No power difference data found for hour $current_hour")
                continue
            end
            
            # Calculate MER for this hour
            println("  Calculating MER for hour $current_hour...")
            mer_results = calculate_hourly_mer(power_diffs, thermal_config, agggen_config, storage_intensity_df, current_hour)
            
            if nrow(mer_results) == 0
                println("  ⚠️  No MER results calculated for hour $current_hour")
                continue
            end
            
            # Filter results to only include rows matching this hour of day
            println("  Filtering results to hour $current_hour of day...")
            filtered_results = filter_by_hour_of_day(mer_results, current_hour)
            println("    Original rows: $(nrow(mer_results)), Filtered rows: $(nrow(filtered_results))")
            
            if nrow(filtered_results) == 0
                println("  ⚠️  No results remain after filtering for hour $current_hour")
                continue
            end
            
            # Calculate summary statistics on filtered results
            println("  Calculating summary statistics for hour $current_hour...")
            stats = calculate_summary_statistics(filtered_results, current_hour)
            
            # Save results
            println("  Saving results for hour $current_hour...")
            timestep_file, stats_file = save_hourly_mer_results(filtered_results, stats, current_hour, mer_results_base)
            
            println("  ✓ Hour $current_hour completed successfully!")
            println("    Timestep results: $timestep_file")
            println("    Summary stats: $stats_file")
            
            push!(all_results, mer_results)
            push!(all_stats, stats)
            push!(all_filtered_results, filtered_results)
            
        catch e
            println("  ✗ Error processing hour $current_hour:")
            println("    Error: $e")
            @warn "MER calculation failed for hour $current_hour" exception=e
        end
        
        println()
    end
    
    # Combine all filtered results and sort by time
    if !isempty(all_filtered_results)
        println("="^80)
        println("COMBINING AND SORTING RESULTS")
        println("="^80)
        
        println("Combining $(length(all_filtered_results)) hourly results...")
        combined_results = vcat(all_filtered_results...)
        
        println("  Total combined rows: $(nrow(combined_results))")
        
        # Sort by DateTime (first column)
        time_col = names(combined_results)[1]
        println("  Sorting by $time_col...")
        sort!(combined_results, time_col)
        
        # Save combined results
        combined_file = joinpath(mer_results_base, "all_hours_mer_combined_by_timestep_storagehourly.csv")
        CSV.write(combined_file, combined_results)
        println("  ✓ Combined and sorted results saved to: $combined_file")
        println()
    end
    
    # Generate overall summary
    println("="^80)
    println("MER CALCULATION SUMMARY")
    println("="^80)
    
    successful_hours = length(all_stats)
    println("Successfully processed: $successful_hours/$total_hours hours")
    
    if successful_hours > 0
        println("\\nMER Statistics by Hour:")
        println("Hour | Mean MER | Median MER | Min MER | Max MER | Non-Zero Steps")
        println("-"^70)
        
        for stats in all_stats
            if haskey(stats, "mean_mer")
                println("$(lpad(stats["hour"], 4)) | $(lpad(round(stats["mean_mer"], digits=1), 8)) | $(lpad(round(stats["median_mer"], digits=1), 10)) | $(lpad(round(stats["min_mer"], digits=1), 7)) | $(lpad(round(stats["max_mer"], digits=1), 7)) | $(lpad(stats["non_zero_timesteps"], 13))")
            end
        end
        
        # Save combined summary
        summary_df = DataFrame(all_stats)
        combined_summary_file = joinpath(mer_results_base, "all_hours_mer_summary.csv")
        CSV.write(combined_summary_file, summary_df)
        println("\\nCombined summary saved to: $combined_summary_file")
    end
    
    if successful_hours == total_hours
        println("\\n🎉 All hourly MER calculations completed successfully!")
    else
        println("\\n⚠️  $successful_hours out of $total_hours calculations completed successfully.")
    end
    
    println("="^80)
    
    return all_results, all_stats
end

# Run MER calculations if script is executed directly

mer_results, mer_stats = run_all_hourly_mer_calculations()
