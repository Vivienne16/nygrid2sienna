using CSV
using DataFrames
using Statistics

"""
Calculate Marginal Emission Rate (MER) from power generation differences.

MER = Σ(ΔPower_i × EmissionFactor_i) / Σ(ΔPower_i)

where:
- ΔPower_i is the change in power output for generator i
- EmissionFactor_i is the emission factor for generator i (kg CO2/MWh)
"""

# Emission factors by fuel type (kg CO2/MWh)
# Source: EPA eGRID, typical values for different fuel types
const EMISSION_FACTORS = Dict(
    "Natural Gas" => 820.0,     # kg CO2/MWh for combined cycle
    "Coal" => 2200.0,           # kg CO2/MWh for coal
    "Oil" => 1800.0,            # kg CO2/MWh for oil
    "Fuel Oil 2" => 1850.0,     # kg CO2/MWh for fuel oil 2 (distillate)
    "Fuel Oil 6" => 1900.0,     # kg CO2/MWh for fuel oil 6 (residual)
    "Kerosene" => 1900.0,       # kg CO2/MWh for kerosene
    "Diesel" => 1900.0,         # kg CO2/MWh for diesel
    "Nuclear" => 0.0,           # kg CO2/MWh for nuclear
    "Hydro" => 0.0,             # kg CO2/MWh for hydro
    "Wind" => 0.0,              # kg CO2/MWh for wind
    "Solar" => 0.0,             # kg CO2/MWh for solar
    "AggGen" => 850.0           # kg CO2/MWh for aggregated generators (Natural Gas + 30)
)

# Storage discharge emission intensity (kg CO2/MWh)
STORAGE_DISCHARGE_EMISSION_FACTOR = 620.0

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

function load_power_differences()
    """Load all power difference CSV files from comparison_results directory"""
    results_dir = "comparison_results"
    
    if !isdir(results_dir)
        error("Results directory not found: $results_dir")
    end
    
    # Get all difference CSV files
    diff_files = filter(f -> endswith(f, "_differences.csv"), readdir(results_dir))
    
    power_diffs = Dict()
    
    for file in diff_files
        filepath = joinpath(results_dir, file)
        df = CSV.read(filepath, DataFrame)
        
        # Extract the type from filename
        file_type = replace(file, "_differences.csv" => "")
        power_diffs[file_type] = df
        
        println("Loaded: $file ($(nrow(df)) rows, $(ncol(df)) columns)")
    end
    
    return power_diffs
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
            
            println("Aggregated $(length(zone_cols)) AggGen units in zone $zone")
        end
    end
    
    return new_df, zone_emission_factors
end

function extract_generator_name(column_name)
    """Extract generator name from column name by removing '_diff' suffix"""
    return replace(column_name, "_diff" => "")
end

function calculate_mer_by_timestep(power_diffs, thermal_config, agggen_config)
    """Calculate MER for each timestep"""
    
    # Create lookup dictionary for emission factors (thermal generators)
    emission_lookup = Dict(row.Name => row.emission_factor for row in eachrow(thermal_config))
    
    results = DataFrame()
    
    # Process thermal generation differences
    if haskey(power_diffs, "ActivePowerVariable__ThermalStandard_ED")
        thermal_df = power_diffs["ActivePowerVariable__ThermalStandard_ED"]
        
        # Aggregate AggGen units by zone
        println("Aggregating AggGen units by zone...")
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
        storage_charge_emissions = Float64[]  # Emissions from charging (absorbed from grid)
        storage_discharge_emissions = Float64[]  # Emissions from discharging (released to grid)
        total_storage_charge = Float64[]
        total_storage_discharge = Float64[]
        
        for (i, row) in enumerate(eachrow(thermal_df_agg))
            power_changes = Float64[]
            emissions_changes = Float64[]
            thermal_power_changes = Float64[]
            thermal_emissions_changes = Float64[]
            storage_power_changes = Float64[]
            storage_emissions_changes = Float64[]
            timestep_storage_charge_emissions = 0.0
            timestep_storage_discharge_emissions = 0.0
            
            # Process thermal generation differences
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
                    push!(emissions_changes, emission_change)
                    push!(thermal_power_changes, power_change)
                    push!(thermal_emissions_changes, emission_change)
                end
            end
            
            # Calculate marginal emission intensity based on the actual power and emission changes
            # This represents the emission intensity of the marginal generation mix for this timestep
            total_thermal_power_change = sum(thermal_power_changes)
            total_thermal_emission_change = sum(thermal_emissions_changes)
            
            grid_emission_intensity = abs(total_thermal_power_change) > 1e-6 ? 
                                    total_thermal_emission_change / total_thermal_power_change : 
                                    mean([v for v in values(emission_lookup) if v > 0])
            
            # Add storage charging/discharging effects
            # We'll collect per-storage-unit charge and discharge and then merge to a single net
            storage_charge = 0.0
            storage_discharge = 0.0
            storage_charge_map = Dict{String, Float64}()
            storage_discharge_map = Dict{String, Float64}()

            # Collect charging amounts (positive = charging increases demand)
            if haskey(power_diffs, "ActivePowerInVariable__EnergyReservoirStorage_ED")
                storage_in_df = power_diffs["ActivePowerInVariable__EnergyReservoirStorage_ED"]
                if i <= nrow(storage_in_df)
                    storage_row = storage_in_df[i, :]
                    for col in names(storage_in_df)
                        if endswith(col, "_diff") && col != time_col
                            charge_change = storage_row[col]
                            if !ismissing(charge_change) && abs(charge_change) > 1e-6
                                storage_name = extract_generator_name(col)
                                storage_charge_map[storage_name] = get(storage_charge_map, storage_name, 0.0) + charge_change
                                storage_charge += charge_change
                                timestep_storage_charge_emissions += charge_change * grid_emission_intensity
                            end
                        end
                    end
                end
            end

            # Collect discharging amounts (positive = discharging increases output)
            if haskey(power_diffs, "ActivePowerOutVariable__EnergyReservoirStorage_ED")
                storage_out_df = power_diffs["ActivePowerOutVariable__EnergyReservoirStorage_ED"]
                if i <= nrow(storage_out_df)
                    storage_row = storage_out_df[i, :]
                    for col in names(storage_out_df)
                        if endswith(col, "_diff") && col != time_col
                            discharge_change = storage_row[col]
                            if !ismissing(discharge_change) && abs(discharge_change) > 1e-6
                                storage_name = extract_generator_name(col)
                                storage_discharge_map[storage_name] = get(storage_discharge_map, storage_name, 0.0) + discharge_change
                                storage_discharge += discharge_change
                                timestep_storage_discharge_emissions += discharge_change * STORAGE_DISCHARGE_EMISSION_FACTOR
                            end
                        end
                    end
                end
            end

            # Merge charge/discharge per storage unit into a single net effect
            storage_units = union(keys(storage_charge_map), keys(storage_discharge_map))
            for sname in storage_units
                charge_amt = get(storage_charge_map, sname, 0.0)
                discharge_amt = get(storage_discharge_map, sname, 0.0)
                # net positive = net discharging (reduces demand); negative = net charging (increases demand)
                net_storage = discharge_amt - charge_amt

                # emissions: charging uses grid marginal intensity, discharging uses configurable emission factor
                # net positive emissions = net discharging emissions; negative = net charging emissions
                emissions_net = discharge_amt * STORAGE_DISCHARGE_EMISSION_FACTOR - charge_amt * grid_emission_intensity

                # push single net effect for this storage unit
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
            push!(storage_charge_emissions, timestep_storage_charge_emissions)
            push!(storage_discharge_emissions, timestep_storage_discharge_emissions)
            push!(total_storage_charge, storage_charge)
            push!(total_storage_discharge, storage_discharge)
        end
        
        results.mer_kg_co2_per_mwh = mer_values
        results.thermal_power_change_mw = thermal_power_change
        results.thermal_emissions_change_kg_co2 = thermal_emissions_change
        results.net_storage_change_mw = total_storage_discharge .- total_storage_charge  # discharge - charge
        results.storage_emissions_change_kg_co2 = storage_emissions_change
    else
        # If no thermal data, create empty results with simplified columns
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

function calculate_summary_statistics(mer_results)
    """Calculate summary statistics for MER"""
    
    # Filter out zero MER values for statistics
    non_zero_mer = filter(x -> abs(x) > 1e-6, mer_results.mer_kg_co2_per_mwh)
    
    if isempty(non_zero_mer)
        @warn "No non-zero MER values found"
        return Dict()
    end
    
    # Check if thermal and storage columns exist
    has_thermal = all(col -> col in names(mer_results), ["thermal_power_change_mw", "thermal_emissions_change_kg_co2"])
    has_storage = all(col -> col in names(mer_results), ["net_storage_change_mw", "storage_emissions_change_kg_co2"])
    
    # Calculate total power and emissions from thermal + storage
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
        "mean_mer" => mean(non_zero_mer),
        "median_mer" => median(non_zero_mer),
        "std_mer" => std(non_zero_mer),
        "min_mer" => minimum(non_zero_mer),
        "max_mer" => maximum(non_zero_mer),
        "q25_mer" => quantile(non_zero_mer, 0.25),
        "q75_mer" => quantile(non_zero_mer, 0.75),
        "total_timesteps" => nrow(mer_results),
        "non_zero_timesteps" => length(non_zero_mer),
        "total_power_change_gwh" => sum(total_power_change) / 1000,  # Convert to GWh
        "total_emissions_change_tonnes_co2" => sum(total_emissions_change) / 1000  # Convert to tonnes
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

function save_mer_results(mer_results, stats, output_dir="mer_results")
    """Save MER calculation results"""
    
    # Create output directory
    if !isdir(output_dir)
        mkdir(output_dir)
    end
    
    # Save timestep-level results
    timestep_file = joinpath(output_dir, "mer_by_timestep.csv")
    CSV.write(timestep_file, mer_results)
    println("Saved timestep MER results: $timestep_file")
    
    # Save summary statistics
    stats_df = DataFrame(
        metric = collect(keys(stats)),
        value = collect(values(stats))
    )
    
    stats_file = joinpath(output_dir, "mer_summary_stats.csv")
    CSV.write(stats_file, stats_df)
    println("Saved MER summary statistics: $stats_file")
    
    # Print summary to console
    println("\n" * "="^60)
    println("MARGINAL EMISSION RATE (MER) SUMMARY")
    println("="^60)
    println("Mean MER: $(round(stats["mean_mer"], digits=2)) kg CO₂/MWh")
    println("Median MER: $(round(stats["median_mer"], digits=2)) kg CO₂/MWh")
    println("Standard Deviation: $(round(stats["std_mer"], digits=2)) kg CO₂/MWh")
    println("Range: $(round(stats["min_mer"], digits=2)) - $(round(stats["max_mer"], digits=2)) kg CO₂/MWh")
    println("25th-75th Percentile: $(round(stats["q25_mer"], digits=2)) - $(round(stats["q75_mer"], digits=2)) kg CO₂/MWh")
    println("\nData Coverage:")
    println("Total timesteps: $(Int(stats["total_timesteps"]))")
    println("Non-zero MER timesteps: $(Int(stats["non_zero_timesteps"]))")
    println("\nTotal Changes:")
    println("Total power change: $(round(stats["total_power_change_gwh"], digits=2)) GWh")
    println("Total emissions change: $(round(stats["total_emissions_change_tonnes_co2"], digits=2)) tonnes CO₂")
    println("\nThermal Generation:")
    println("Thermal power change: $(round(stats["thermal_power_change_gwh"], digits=2)) GWh")
    println("Thermal emissions change: $(round(stats["thermal_emissions_change_tonnes_co2"], digits=2)) tonnes CO₂")
    println("\nStorage System:")
    println("Net storage change (discharge - charge): $(round(stats["net_storage_change_gwh"], digits=2)) GWh")
    println("Storage emissions change: $(round(stats["storage_emissions_change_tonnes_co2"], digits=2)) tonnes CO₂")
    println("="^60)
    
    return timestep_file, stats_file
end

# Main execution
thermal_config = load_thermal_config()
agggen_config = load_agggen_config()


# Load power differences
println("Loading power difference data...")
power_diffs = load_power_differences()

if isempty(power_diffs)
    error("No power difference data loaded")
end

# Calculate MER
println("Calculating MER by timestep...")
mer_results = calculate_mer_by_timestep(power_diffs, thermal_config, agggen_config)

if nrow(mer_results) == 0
    error("No MER results calculated")
end

# Calculate summary statistics
println("Calculating summary statistics...")
stats = calculate_summary_statistics(mer_results)

# Save results
println("Saving results...")
save_mer_results(mer_results, stats)

println("MER calculation complete!")

