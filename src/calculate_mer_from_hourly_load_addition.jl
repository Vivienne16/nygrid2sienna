using CSV
using DataFrames
using Statistics
using Dates

"""
Calculate Marginal Emission Rate (MER) from hourly load addition simulations.

This script:
1. Loads pre-computed power differences from comparison_bus65_vs_load_addition
2. Computes MER for each hour based on the 1 MW load addition

MER = Σ(ΔPower_i × EmissionFactor_i) / ΔLoad

where:
- ΔPower_i is the change in power output for generator i (load_addition - baseline)
- EmissionFactor_i is the emission factor for generator i (kg CO2/MWh)
- ΔLoad is the load addition (1 MW)
"""

# Emission factors by fuel type (kg CO2/MWh)
const EMISSION_FACTORS = Dict(
    "Nuclear" => 0.0,           # kg CO2/MWh for nuclear
    "Hydro" => 0.0,             # kg CO2/MWh for hydro
    "Wind" => 0.0,              # kg CO2/MWh for wind
    "Solar" => 0.0,             # kg CO2/MWh for solar
    "AggGen" => 0.06           # kg CO2/MWh for aggregated generators
)

# Configuration
comparison_dir = "comparison_UC_nonreserve_pmin_vs_load_addition_newre"
mer_output_dir = "mer_results_hourly_load_addition_UC_nonreserve_pmin_newre"
load_addition_mw = 1.0  # 1 MW load addition

!isdir(mer_output_dir) && mkpath(mer_output_dir)

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
    
    # Add emission factors for AggGens
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

function find_hourly_comparison_dirs()
    """Find all hour directories in the comparison directory"""
    
    if !isdir(comparison_dir)
        error("Comparison directory not found: $comparison_dir")
    end
    
    # Look for hour_XX directories
    dirs = readdir(comparison_dir)
    hour_dirs = filter(d -> startswith(d, "hour_") && isdir(joinpath(comparison_dir, d)), dirs)
    
    # Extract hour numbers and sort
    hour_info = []
    for dir in hour_dirs
        match_result = match(r"hour_(\d+)", dir)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            full_path = joinpath(comparison_dir, dir)
            push!(hour_info, (hour=hour, dir_name=dir, path=full_path))
        end
    end
    
    # Sort by hour
    sort!(hour_info, by=x -> x.hour)
    
    return hour_info
end

function load_hourly_difference(hour_dir, filename)
    """Load a single difference CSV file from a specific hour directory"""
    
    filepath = joinpath(hour_dir, filename)
    
    if !isfile(filepath)
        return nothing
    end
    
    df = CSV.read(filepath, DataFrame)
    
    # Should only have one row (single timestep)
    if nrow(df) != 1
        @warn "Expected 1 row, got $(nrow(df)) rows in $filepath"
    end
    
    return df
end

function extract_generator_name(column_name)
    """Extract generator name from column name by removing '_diff' suffix"""
    return replace(column_name, "_diff" => "")
end

function aggregate_agggen_by_zone(diff_df, agggen_config)
    """Aggregate AggGen power differences by zone"""
    
    # Create zone lookup for AggGens
    zone_lookup = Dict(row.Name => row.Zone for row in eachrow(agggen_config))
    
    # Find all AggGen columns (with _diff suffix)
    agggen_cols = filter(col -> startswith(extract_generator_name(col), "AggGen") && 
                         endswith(col, "_diff") && col != "DateTime", names(diff_df))
    
    if isempty(agggen_cols)
        return diff_df, Dict{String, Float64}()
    end
    
    # Get unique zones
    zones = unique([zone_lookup[extract_generator_name(col)] for col in agggen_cols 
                   if haskey(zone_lookup, extract_generator_name(col))])
    
    # Create new DataFrame without individual AggGen columns
    new_df = select(diff_df, Not(agggen_cols))
    
    # Add aggregated zone columns
    zone_emission_factors = Dict{String, Float64}()
    
    for zone in zones
        zone_cols = filter(col -> haskey(zone_lookup, extract_generator_name(col)) && 
                          zone_lookup[extract_generator_name(col)] == zone, agggen_cols)
        
        if !isempty(zone_cols)
            # Sum power differences for this zone
            zone_col_name = "$(zone)_AggGen_diff"
            
            # Sum across zone columns (should only be 1 row)
            zone_sum = sum([coalesce(diff_df[1, col], 0.0) for col in zone_cols])
            new_df[!, zone_col_name] = [zone_sum]
            
            # Store emission factor for this zone (without _diff suffix)
            zone_emission_factors[replace(zone_col_name, "_diff" => "")] = EMISSION_FACTORS["AggGen"]
        end
    end
    
    return new_df, zone_emission_factors
end

function calculate_hourly_mer(
    thermal_diff, 
    renewable_diff,
    hydro_diff,
    storage_in_diff,
    storage_out_diff,
    thermal_config, 
    agggen_config,
    storage_intensity_df,
    hour
)
    """Calculate MER for a specific hour based on power differences"""
    
    if thermal_diff === nothing
        return nothing
    end
    
    # Create lookup dictionary for emission factors (thermal generators)
    emission_lookup = Dict(row.Name => row.emission_factor for row in eachrow(thermal_config))
    
    # Aggregate AggGen units by zone
    thermal_diff_agg, zone_emission_factors = aggregate_agggen_by_zone(thermal_diff, agggen_config)
    
    # Merge zone emission factors into the main lookup
    emission_lookup = merge(emission_lookup, zone_emission_factors)
    
    # Calculate marginal emission intensity for storage
    grid_emission_intensity = 0.4  # kg CO2/MWh (TODO: make this configurable)
    
    # Initialize tracking variables
    power_changes = Float64[]
    power_changes_name = String[]
    emissions_changes = Float64[]
    thermal_power_changes = Float64[]
    thermal_emissions_changes = Float64[]
    renewable_power_changes = Float64[]
    hydro_power_changes = Float64[]
    storage_power_changes = Float64[]
    storage_emissions_changes = Float64[]
    
    # Process thermal generation differences (single row)
    for col in names(thermal_diff_agg)
        if col != "DateTime" && endswith(col, "_diff")
            gen_name = extract_generator_name(col)
            power_change = thermal_diff_agg[1, col]
            
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
    if renewable_diff !== nothing
        for col in names(renewable_diff)
            if col != "DateTime" && endswith(col, "_diff")
                power_change = renewable_diff[1, col]
                if !ismissing(power_change) && abs(power_change) > 1e-6
                    push!(power_changes, power_change)
                    push!(power_changes_name, extract_generator_name(col))
                    push!(emissions_changes, 0.0)  # Zero emissions
                    push!(renewable_power_changes, power_change)
                end
            end
        end
    end
    
    # Process hydro generation differences (zero emissions)
    if hydro_diff !== nothing
        for col in names(hydro_diff)
            if col != "DateTime" && endswith(col, "_diff")
                power_change = hydro_diff[1, col]
                if !ismissing(power_change) && abs(power_change) > 1e-6
                    push!(power_changes, power_change)
                    push!(power_changes_name, extract_generator_name(col))
                    push!(emissions_changes, 0.0)  # Zero emissions
                    push!(hydro_power_changes, power_change)
                end
            end
        end
    end
    
    # Process storage charging/discharging effects
    storage_charge_map = Dict{String, Float64}()
    storage_discharge_map = Dict{String, Float64}()
    
    # Collect charging amounts
    if storage_in_diff !== nothing
        for col in names(storage_in_diff)
            if col != "DateTime" && endswith(col, "_diff")
                charge_change = storage_in_diff[1, col]
                if !ismissing(charge_change) && abs(charge_change) > 1e-6
                    storage_name = extract_generator_name(col)
                    storage_charge_map[storage_name] = charge_change
                end
            end
        end
    end
    
    # Collect discharging amounts
    if storage_out_diff !== nothing
        for col in names(storage_out_diff)
            if col != "DateTime" && endswith(col, "_diff")
                discharge_change = storage_out_diff[1, col]
                if !ismissing(discharge_change) && abs(discharge_change) > 1e-6
                    storage_name = extract_generator_name(col)
                    storage_discharge_map[storage_name] = discharge_change
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
        
        # Get storage intensity from CSV if available
        storage_intensity = grid_emission_intensity  # default fallback
        if !isempty(storage_intensity_df) && hour <= nrow(storage_intensity_df)
            intensity_col = "$(sname)_avg_intensity"
            if intensity_col in names(storage_intensity_df)
                intensity_val = storage_intensity_df[hour, intensity_col]
                if !ismissing(intensity_val) && !isnan(intensity_val) && intensity_val != 0.0
                    storage_intensity = intensity_val
                end
            end
        end
        
        # Calculate emissions: discharge uses stored intensity, charging uses grid intensity
        emissions_net = discharge_amt * storage_intensity - charge_amt * grid_emission_intensity
        
        if abs(net_storage) > 1e-9
            push!(power_changes, net_storage)
            push!(power_changes_name, sname)
            push!(emissions_changes, emissions_net)
            push!(storage_power_changes, net_storage)
            push!(storage_emissions_changes, emissions_net)
        end
    end
    
    # Calculate total changes
    total_power_change = sum(power_changes)
    total_emissions_change = sum(emissions_changes)
    total_thermal_power = sum(thermal_power_changes)
    total_thermal_emissions = sum(thermal_emissions_changes)
    total_renewable_power = sum(renewable_power_changes)
    total_hydro_power = sum(hydro_power_changes)
    total_storage_power = sum(storage_power_changes)
    total_storage_emissions = sum(storage_emissions_changes)
    
    # Calculate MER (emissions per MW of load addition)
    mer = abs(load_addition_mw) > 1e-6 ? total_emissions_change / load_addition_mw : 0.0
    
    # Return detailed results
    result = Dict(
        "hour" => hour,
        "datetime" => thermal_diff.DateTime[1],
        "mer_kg_co2_per_mwh" => mer,
        "load_addition_mw" => load_addition_mw,
        "total_power_change_mw" => total_power_change,
        "total_emissions_change_kg_co2" => total_emissions_change,
        "thermal_power_change_mw" => total_thermal_power,
        "thermal_emissions_change_kg_co2" => total_thermal_emissions,
        "renewable_power_change_mw" => total_renewable_power,
        "hydro_power_change_mw" => total_hydro_power,
        "storage_power_change_mw" => total_storage_power,
        "storage_emissions_change_kg_co2" => total_storage_emissions,
        "num_generators_changed" => length(power_changes)
    )
    
    return result
end

function process_single_hour(hour_path, hour, thermal_config, agggen_config, storage_intensity_df)
    """Process a single hour: load differences, compute MER"""
    
    # Load difference files (already computed)
    thermal_diff = load_hourly_difference(hour_path, "ActivePowerVariable__ThermalStandard_ED_hour_$(hour)_differences.csv")
    renewable_diff = load_hourly_difference(hour_path, "ActivePowerVariable__RenewableDispatch_ED_hour_$(hour)_differences.csv")
    hydro_diff = load_hourly_difference(hour_path, "ActivePowerVariable__HydroDispatch_ED_hour_$(hour)_differences.csv")
    storage_in_diff = load_hourly_difference(hour_path, "ActivePowerInVariable__EnergyReservoirStorage_ED_hour_$(hour)_differences.csv")
    storage_out_diff = load_hourly_difference(hour_path, "ActivePowerOutVariable__EnergyReservoirStorage_ED_hour_$(hour)_differences.csv")
    
    # Calculate MER
    mer_result = calculate_hourly_mer(
        thermal_diff,
        renewable_diff,
        hydro_diff,
        storage_in_diff,
        storage_out_diff,
        thermal_config,
        agggen_config,
        storage_intensity_df,
        hour
    )
    
    return mer_result
end

function run_mer_calculations()
    """Run MER calculations for all available hours"""
    
    println("="^80)
    println("MER CALCULATION FROM HOURLY LOAD ADDITION SIMULATIONS")
    println("="^80)
    println("Comparison directory: $comparison_dir")
    println("Load addition: $load_addition_mw MW")
    println("Output directory: $mer_output_dir")
    println()
    
    # Load configuration once
    println("Loading configuration files...")
    thermal_config = load_thermal_config()
    agggen_config = load_agggen_config()
    storage_intensity_df = load_storage_intensity()
    println("  ✓ Configuration loaded")
    println()
    
    # Find available hours in comparison directory
    hour_dirs = find_hourly_comparison_dirs()
    
    println("Found $(length(hour_dirs)) comparison hour directories")
    println()
    
    if isempty(hour_dirs)
        error("No comparison hours found in $comparison_dir")
    end
    
    # Process each hour
    all_results = []
    successful_count = 0
    failed_count = 0
    
    for (i, hour_info) in enumerate(hour_dirs)
        hour = hour_info.hour
        hour_path = hour_info.path
        
        print("Processing hour $hour ($i of $(length(hour_dirs)))... ")
        
        try
            result = process_single_hour(hour_path, hour, thermal_config, agggen_config, storage_intensity_df)
            
            if result !== nothing
                push!(all_results, result)
                successful_count += 1
                println("✓ MER = $(round(result["mer_kg_co2_per_mwh"], digits=3)) kg CO2/MWh")
            else
                failed_count += 1
                println("✗ Failed")
            end
            
        catch e
            failed_count += 1
            println("✗ Error: $e")
            @warn "Failed to process hour $hour" exception=e
        end
    end
    
    println()
    println("="^80)
    println("PROCESSING SUMMARY")
    println("="^80)
    println("Total hours processed: $(length(hour_dirs))")
    println("Successful: $successful_count")
    println("Failed: $failed_count")
    println()
    
    if isempty(all_results)
        error("No successful MER calculations")
    end
    
    # Convert results to DataFrame
    results_df = DataFrame(all_results)
    
    # Sort by hour
    sort!(results_df, :hour)
    
    # Save detailed results
    detailed_output = joinpath(mer_output_dir, "mer_by_hour_detailed.csv")
    CSV.write(detailed_output, results_df)
    println("✓ Detailed results saved to: $detailed_output")
    
    # Calculate summary statistics
    println()
    println("="^80)
    println("MER STATISTICS")
    println("="^80)
    
    non_zero_mer = filter(x -> abs(x) > 1e-6, results_df.mer_kg_co2_per_mwh)
    
    if !isempty(non_zero_mer)
        println("Mean MER:     $(round(mean(non_zero_mer), digits=3)) kg CO2/MWh")
        println("Median MER:   $(round(median(non_zero_mer), digits=3)) kg CO2/MWh")
        println("Std Dev:      $(round(std(non_zero_mer), digits=3)) kg CO2/MWh")
        println("Min MER:      $(round(minimum(non_zero_mer), digits=3)) kg CO2/MWh")
        println("Max MER:      $(round(maximum(non_zero_mer), digits=3)) kg CO2/MWh")
        println("25th percentile: $(round(quantile(non_zero_mer, 0.25), digits=3)) kg CO2/MWh")
        println("75th percentile: $(round(quantile(non_zero_mer, 0.75), digits=3)) kg CO2/MWh")
        println()
        println("Total emissions change: $(round(sum(results_df.total_emissions_change_kg_co2)/1000, digits=3)) tonnes CO2")
        println("  Thermal:   $(round(sum(results_df.thermal_emissions_change_kg_co2)/1000, digits=3)) tonnes CO2")
        println("  Storage:   $(round(sum(results_df.storage_emissions_change_kg_co2)/1000, digits=3)) tonnes CO2")
    end
    
    # Save summary statistics
    summary_stats = DataFrame(
        metric = ["mean_mer", "median_mer", "std_mer", "min_mer", "max_mer", 
                 "q25_mer", "q75_mer", "total_hours", "successful_hours",
                 "total_emissions_tonnes_co2", "thermal_emissions_tonnes_co2", 
                 "storage_emissions_tonnes_co2"],
        value = [
            mean(non_zero_mer),
            median(non_zero_mer),
            std(non_zero_mer),
            minimum(non_zero_mer),
            maximum(non_zero_mer),
            quantile(non_zero_mer, 0.25),
            quantile(non_zero_mer, 0.75),
            length(hour_dirs),
            successful_count,
            sum(results_df.total_emissions_change_kg_co2)/1000,
            sum(results_df.thermal_emissions_change_kg_co2)/1000,
            sum(results_df.storage_emissions_change_kg_co2)/1000
        ]
    )
    
    summary_output = joinpath(mer_output_dir, "mer_summary_statistics.csv")
    CSV.write(summary_output, summary_stats)
    println("✓ Summary statistics saved to: $summary_output")
    
    println()
    println("="^80)
    println("🎉 MER calculation completed successfully!")
    println("="^80)
    
    return results_df, summary_stats
end

# Run MER calculations if script is executed directly

results_df, summary_stats = run_mer_calculations()
