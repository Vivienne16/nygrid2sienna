"""
Script to convert renewable energy time series profiles from absolute power values
to capacity factors by normalizing with the original ratings from the config files.

This creates new profile files with '_cf' suffix (capacity factor) that can be used
with any rating configuration, not just the original ratings.

Usage:
    julia convert_renewable_profiles_to_capacity_factors.jl [year1] [year2] ...
    
    If no years specified, defaults to 2019
    
Example:
    julia convert_renewable_profiles_to_capacity_factors.jl 2019 2020 2021
"""

using CSV
using DataFrames

# Function to convert a renewable profile to capacity factors
function convert_to_capacity_factor(profile_file, config_file, output_file, resource_type)
    println("\n" * "="^70)
    println("Converting $resource_type profile to capacity factors")
    println("="^70)
    println("Input profile: $profile_file")
    println("Config file: $config_file")
    println("Output file: $output_file")
    
    # Read the config file to get original ratings
    config_df = CSV.read(config_file, DataFrame)
    println("\nLoaded $(nrow(config_df)) $(resource_type) generators from config")
    
    # Read the profile file (transposed format with bus IDs in first column)
    profile_raw = CSV.read(profile_file, DataFrame, header=false)
    
    println("\nOriginal profile dimensions: $(nrow(profile_raw)) rows × $(ncol(profile_raw)) columns")
    
    # Verify that config and profile have same number of rows
    if nrow(config_df) != nrow(profile_raw)
        error("Mismatch: config has $(nrow(config_df)) rows but profile has $(nrow(profile_raw)) rows")
    end
    
    # First column contains the bus IDs, rest are time series values
    bus_ids = profile_raw.Column1
    
    # Create a new DataFrame for capacity factors
    cf_data = DataFrame()
    cf_data.Column1 = bus_ids  # Keep the bus IDs in first column
    
    # Convert each time series to capacity factor
    for col_idx in 2:ncol(profile_raw)
        col_name = names(profile_raw)[col_idx]
        
        # Process each bus (row) - match by row position with config
        cf_column = Float64[]
        
        for row_idx in 1:nrow(profile_raw)
            value = profile_raw[row_idx, col_name]
            original_rating = config_df[row_idx, :rating]
            
            # Convert to capacity factor (value between 0 and 1)
            if original_rating > 0
                cf_value = value / original_rating
                # Clamp to [0, 1] range to handle any numerical issues
                cf_value = min(max(cf_value, 0.0), 1.0)
            else
                cf_value = 0.0
            end
            
            push!(cf_column, cf_value)
        end
        
        cf_data[!, col_name] = cf_column
    end
    
    # Write the capacity factor profile
    CSV.write(output_file, cf_data, header=false)
    
    println("\n✓ Conversion complete!")
    println("  - Converted buses: $(length(bus_ids))")
    println("  - Time steps: $(ncol(profile_raw) - 1)")
    println("  - Output saved to: $output_file")
    
    # Show some statistics
    # Sample the first row (excluding bus ID column) to show CF range
    sample_row = Vector(cf_data[1, 2:end])
    println("\nCapacity factor statistics for first bus ($(bus_ids[1])):")
    println("  - Min CF: $(round(minimum(sample_row), digits=4))")
    println("  - Max CF: $(round(maximum(sample_row), digits=4))")
    println("  - Mean CF: $(round(sum(sample_row) / length(sample_row), digits=4))")
end

# Main execution
function main()
    # Get years from command line arguments, default to 2019
    years = if length(ARGS) > 0
        [parse(Int, arg) for arg in ARGS]
    else
        [2019]
    end
    
    println("\n" * "="^70)
    println("RENEWABLE PROFILE TO CAPACITY FACTOR CONVERTER")
    println("="^70)
    println("Processing years: $(join(years, ", "))")
    
    for year in years
        println("\n\n" * "█"^70)
        println("█  PROCESSING YEAR: $year")
        println("█"^70)
        
        # Convert Wind profiles
        wind_profile = "wind_profile/Wind$(year).csv"
        wind_config = "config/wind_config.csv"
        wind_output = "wind_profile/Wind$(year)_cf.csv"
        
        if isfile(wind_profile) && isfile(wind_config)
            convert_to_capacity_factor(wind_profile, wind_config, wind_output, "Wind")
        else
            @warn "Skipping Wind $year: missing files"
        end
        
        # Convert UPV profiles
        upv_profile = "upv_profile/solarUPV$(year).csv"
        upv_config = "config/upv_config.csv"
        upv_output = "upv_profile/solarUPV$(year)_cf.csv"
        
        if isfile(upv_profile) && isfile(upv_config)
            convert_to_capacity_factor(upv_profile, upv_config, upv_output, "UPV")
        else
            @warn "Skipping UPV $year: missing files"
        end
        
        # Convert DPV profiles
        dpv_profile = "dpv_profile/solarDPV$(year).csv"
        dpv_config = "config/dpv_config.csv"
        dpv_output = "dpv_profile/solarDPV$(year)_cf.csv"
        
        if isfile(dpv_profile) && isfile(dpv_config)
            convert_to_capacity_factor(dpv_profile, dpv_config, dpv_output, "DPV")
        else
            @warn "Skipping DPV $year: missing files"
        end
    end
    
    println("\n\n" * "="^70)
    println("✓ ALL CONVERSIONS COMPLETE!")
    println("="^70)
    println("\nThe capacity factor files have been created with '_cf' suffix.")
    println("You can now use these files with any rating configuration in your")
    println("config files (e.g., wind_config_2030.csv) and the time series will")
    println("automatically scale to match the specified ratings.")
    println("\nNext steps:")
    println("  1. Update your parsing code to use *_cf.csv files instead")
    println("  2. Multiply capacity factors by the new ratings from 2030 configs")
    println("="^70)
end

# Run the main function
main()
