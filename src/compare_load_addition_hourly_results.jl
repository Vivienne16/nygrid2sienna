using CSV
using DataFrames
using Statistics
using Glob
using Dates

"""
Compare two sets of hourly simulations: baseline and load addition.

Each hourly simulation (hour_1 to hour_8760) contains a single hour of results.
This script compares the baseline hourly simulations with the load addition hourly simulations,
then merges all hours into a combined comparison.
"""

# Configuration
baseline_hourly_dir = "BASEHourlySimulations_UC_noreserve_newre"  # Baseline hourly simulations
load_addition_hourly_dir = "MERHourlySimulations_UC_noreserve_pmin_fixed_newre"  # Load addition hourly simulations
output_base_dir = "comparison_UC_nonreserve_pmin_vs_load_addition_newre"

!isdir(output_base_dir) && mkpath(output_base_dir)

# Get all ActivePower*Variable files
function get_activepower_files(directory)
    files = readdir(directory)
    return filter(f -> startswith(f, "ActivePowerVariable__") || 
                      startswith(f, "ActivePowerInVariable__") || 
                      startswith(f, "ActivePowerOutVariable__"), files)
end

# Find hourly simulation directories (hour_1 to hour_8760)
function find_hourly_simulation_dirs(base_dir, label)
    """Find all hourly simulation directories."""
    
    if !isdir(base_dir)
        error("Hourly simulations base directory not found: $base_dir")
    end
    
    println("Searching for hourly simulation directories in $label: $base_dir")
    
    # Look for hour_X directories
    dirs = readdir(base_dir)
    hour_dirs = filter(d -> occursin(r"^hour_\d+$", d) && isdir(joinpath(base_dir, d)), dirs)
    
    println("  Found $(length(hour_dirs)) potential hour directories")
    
    # Extract hour numbers and find results
    hour_info = []
    for dir in hour_dirs
        match_result = match(r"hour_(\d+)", dir)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            full_path = joinpath(base_dir, dir)
            
            # Find results directory within this hour directory
            results_dir = find_results_directory(full_path)
            
            if results_dir !== nothing
                push!(hour_info, (hour=hour, dir_name=dir, dir_path=full_path, results_path=results_dir))
            else
                @warn "    Hour $hour: No results directory found in $full_path"
            end
        end
    end
    
    # Sort by hour
    sort!(hour_info, by=x -> x.hour)
    
    println("Successfully identified $(length(hour_info)) hourly simulation directories with results in $label")
    
    return hour_info
end

function find_results_directory(hour_dir)
    """Find the results directory within a hour directory."""
    
    # Pattern 1: Direct results directory
    if isdir(joinpath(hour_dir, "results"))
        return joinpath(hour_dir, "results")
    end
    
    # Pattern 2: Look for simulation subdirectory with results
    subdirs = filter(d -> isdir(joinpath(hour_dir, d)), readdir(hour_dir))
    for subdir in subdirs
        subdir_path = joinpath(hour_dir, subdir)
        if isdir(joinpath(subdir_path, "results"))
            return joinpath(subdir_path, "results")
        end
    end
    
    return nothing
end

# Compare a single file between two hourly results
function compare_single_file(baseline_file, load_addition_file, hour, output_dir, filename)
    """Compare a single variable file between baseline hourly and load addition hourly results."""
    
    if !isfile(baseline_file)
        @warn "Baseline hourly file not found: $baseline_file"
        return nothing
    end
    
    if !isfile(load_addition_file)
        @warn "Load addition hourly file not found: $load_addition_file"
        return nothing
    end
    
    # Read files
    df_baseline = CSV.read(baseline_file, DataFrame)
    df_load_addition = CSV.read(load_addition_file, DataFrame)
    
    # Both should have exactly 1 row
    if nrow(df_baseline) != 1
        @warn "Baseline hourly result should have 1 row but has $(nrow(df_baseline)) rows"
        return nothing
    end
    
    if nrow(df_load_addition) != 1
        @warn "Load addition hourly result should have 1 row but has $(nrow(df_load_addition)) rows"
        return nothing
    end
    
    # Create difference DataFrame
    diff_df = DataFrame()
    diff_df[!, "DateTime"] = df_baseline[!, "DateTime"]
    
    # Compare all columns except DateTime
    common_cols = intersect(names(df_baseline), names(df_load_addition))
    non_time_cols = filter(col -> col != "DateTime", common_cols)
    
    for col in non_time_cols
        baseline_val = df_baseline[1, col]
        load_addition_val = df_load_addition[1, col]
        
        if eltype(df_baseline[!, col]) <: Number && eltype(df_load_addition[!, col]) <: Number
            if ismissing(baseline_val) || ismissing(load_addition_val)
                diff_df[!, "$(col)_diff"] = [missing]
            else
                raw_diff = float(load_addition_val) - float(baseline_val)
                # Set to 0 if absolute difference is less than 1e-4
                diff_df[!, "$(col)_diff"] = [abs(raw_diff) < 1e-4 ? 0.0 : raw_diff]
            end
        else
            # Non-numeric: boolean indicating match
            diff_df[!, "$(col)_match"] = [baseline_val == load_addition_val]
        end
    end
    
    # Save difference file
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    diff_filename = joinpath(output_dir, replace(filename, r"\.csv$" => "_hour_$(hour)_differences.csv"))
    CSV.write(diff_filename, diff_df)
    
    return diff_df
end

# Compare all files for a specific hour
function compare_hour_results(baseline_results_dir, load_addition_results_dir, hour, output_dir)
    """Compare baseline hourly results with load addition hourly results for a single hour."""
    
    println("  Comparing hour $hour results")
    
    # Get list of ActivePower files from baseline
    baseline_files = get_activepower_files(baseline_results_dir)
    
    if isempty(baseline_files)
        @warn "No ActivePower files found in baseline hourly directory"
        return Dict(), 0, 0
    end
    
    println("    Found $(length(baseline_files)) ActivePower files in baseline hourly")
    
    # Compare each file
    results = Dict()
    files_with_diffs = 0
    total_files = 0
    
    for filename in baseline_files
        baseline_file = joinpath(baseline_results_dir, filename)
        load_addition_file = joinpath(load_addition_results_dir, filename)
        
        if !isfile(load_addition_file)
            @warn "    Load addition hourly file not found: $load_addition_file"
            continue
        end
        
        total_files += 1
        
        diff_df = compare_single_file(baseline_file, load_addition_file, hour, output_dir, filename)
        
        if diff_df !== nothing
            # Check if there are any non-zero differences
            has_diffs = false
            for col in names(diff_df)
                if endswith(col, "_diff") && !all(ismissing.(diff_df[!, col])) && any(abs.(coalesce.(diff_df[!, col], 0.0)) .> 1e-10)
                    has_diffs = true
                    break
                end
            end
            
            if has_diffs
                files_with_diffs += 1
            end
            
            results[filename] = diff_df
        end
    end
    
    println("    Completed: $files_with_diffs/$total_files files had differences")
    
    return results, files_with_diffs, total_files
end

# Merge all hourly differences into combined files
function merge_all_hour_differences(output_base_dir, total_hours)
    """Merge all hourly difference files into combined comparison files."""
    
    println("\n" * "="^80)
    println("MERGING ALL HOURLY DIFFERENCES")
    println("="^80)
    
    # Find all hour directories
    hour_dirs = filter(d -> occursin(r"^hour_\d+$", d) && isdir(joinpath(output_base_dir, d)), 
                      readdir(output_base_dir))
    
    if isempty(hour_dirs)
        @warn "No hour directories found in $output_base_dir"
        return
    end
    
    println("Found $(length(hour_dirs)) hour directories to merge")
    
    # Get list of difference files from first hour
    first_hour_dir = joinpath(output_base_dir, hour_dirs[1])
    diff_files = filter(f -> endswith(f, "_differences.csv"), readdir(first_hour_dir))
    
    println("Found $(length(diff_files)) difference file types to merge")
    
    # Merge each file type
    merged_dir = joinpath(output_base_dir, "merged_all_hours")
    if !isdir(merged_dir)
        mkpath(merged_dir)
    end
    
    for diff_file_pattern in diff_files
        # Extract base variable name (remove hour-specific suffix)
        base_name = replace(diff_file_pattern, r"_hour_\d+_differences\.csv$" => "_differences.csv")
        
        println("  Merging: $base_name")
        
        # Collect all hourly DataFrames for this variable
        all_dfs = []
        
        for hour_dir in sort(hour_dirs, by=d -> parse(Int, match(r"hour_(\d+)", d).captures[1]))
            hour = parse(Int, match(r"hour_(\d+)", hour_dir).captures[1])
            diff_file = joinpath(output_base_dir, hour_dir, replace(base_name, "_differences.csv" => "_hour_$(hour)_differences.csv"))
            
            if isfile(diff_file)
                df = CSV.read(diff_file, DataFrame)
                push!(all_dfs, df)
            end
        end
        
        if !isempty(all_dfs)
            # Combine all DataFrames
            merged_df = vcat(all_dfs..., cols=:union)
            
            # Sort by DateTime
            if "DateTime" in names(merged_df)
                sort!(merged_df, :DateTime)
            end
            
            # Save merged file
            merged_file = joinpath(merged_dir, base_name)
            CSV.write(merged_file, merged_df)
            println("    ✓ Saved merged file: $merged_file ($(nrow(merged_df)) rows)")
        end
    end
    
    println("  Merging complete! Files saved to: $merged_dir")
end

# Main comparison function
function run_all_hourly_comparisons()
    """Run comparisons for all hourly simulations."""
    
    println("="^80)
    println("BATCH COMPARISON: BASELINE HOURLY VS LOAD ADDITION HOURLY SIMULATIONS")
    println("="^80)
    println("Baseline hourly directory: $baseline_hourly_dir")
    println("Load addition hourly directory: $load_addition_hourly_dir")
    println()
    
    # Check if directories exist
    if !isdir(baseline_hourly_dir)
        error("Baseline hourly directory not found: $baseline_hourly_dir")
    end
    
    if !isdir(load_addition_hourly_dir)
        error("Load addition hourly directory not found: $load_addition_hourly_dir")
    end
    
    # Find all hourly simulation directories
    baseline_hour_infos = find_hourly_simulation_dirs(baseline_hourly_dir, "baseline")
    load_addition_hour_infos = find_hourly_simulation_dirs(load_addition_hourly_dir, "load addition")
    
    if isempty(baseline_hour_infos)
        error("No hourly simulation directories found in $baseline_hourly_dir")
    end
    
    if isempty(load_addition_hour_infos)
        error("No hourly simulation directories found in $load_addition_hourly_dir")
    end
    
    # Find common hours
    baseline_hours = Set(info.hour for info in baseline_hour_infos)
    load_addition_hours = Set(info.hour for info in load_addition_hour_infos)
    common_hours = intersect(baseline_hours, load_addition_hours)
    
    println("Found $(length(baseline_hour_infos)) baseline hourly directories")
    println("Found $(length(load_addition_hour_infos)) load addition hourly directories")
    println("Common hours: $(length(common_hours))")
    
    if length(common_hours) < length(baseline_hours)
        println("  Missing in load addition: $(setdiff(baseline_hours, load_addition_hours))")
    end
    if length(common_hours) < length(load_addition_hours)
        println("  Missing in baseline: $(setdiff(load_addition_hours, baseline_hours))")
    end
    println()
    
    # Create lookup dictionaries
    baseline_dict = Dict(info.hour => info for info in baseline_hour_infos)
    load_addition_dict = Dict(info.hour => info for info in load_addition_hour_infos)
    
    # Create main output directory
    if !isdir(output_base_dir)
        mkpath(output_base_dir)
    end
    
    # Run comparisons for common hours
    comparison_results = []
    common_hours_sorted = sort(collect(common_hours))
    total_dirs = length(common_hours_sorted)
    
    for (i, hour) in enumerate(common_hours_sorted)
        baseline_info = baseline_dict[hour]
        load_addition_info = load_addition_dict[hour]
        
        println("--- Processing hour $hour ($i of $total_dirs) ---")
        
        try
            # Create hour-specific output directory
            hour_output_dir = joinpath(output_base_dir, "hour_$(hour)")
            
            # Run comparison
            results, files_with_diffs, total_files = compare_hour_results(
                baseline_info.results_path, 
                load_addition_info.results_path, 
                hour, 
                hour_output_dir
            )
            
            println("  ✓ Comparison completed: $files_with_diffs/$total_files files had differences")
            
            push!(comparison_results, (
                hour = hour,
                status = "success",
                files_compared = total_files,
                files_with_diffs = files_with_diffs,
                output_dir = hour_output_dir
            ))
            
        catch e
            println("  ✗ Error comparing hour $hour:")
            println("    Error: $e")
            @warn "Comparison failed for hour $hour" exception=e
            
            push!(comparison_results, (
                hour = hour,
                status = "failed",
                error = string(e),
                files_compared = 0,
                files_with_diffs = 0,
                output_dir = ""
            ))
        end
        
        println()
    end
    
    # Merge all hourly differences
    merge_all_hour_differences(output_base_dir, total_dirs)
    
    # Generate summary
    println("="^80)
    println("COMPARISON SUMMARY")
    println("="^80)
    
    successful_comps = filter(r -> r.status == "success", comparison_results)
    failed_comps = filter(r -> r.status == "failed", comparison_results)
    
    println("Successfully compared: $(length(successful_comps))/$total_dirs hours")
    if !isempty(failed_comps)
        println("Failed comparisons:")
        for comp in failed_comps
            println("  Hour $(comp.hour): $(comp.error)")
        end
    end
    
    println("\nSuccessful comparisons:")
    println("Hour | Files Compared | Files with Diffs")
    println("-"^50)
    for comp in successful_comps[1:min(20, end)]  # Show first 20
        println("$(lpad(comp.hour, 4)) | $(lpad(comp.files_compared, 14)) | $(lpad(comp.files_with_diffs, 16))")
    end
    if length(successful_comps) > 20
        println("... ($(length(successful_comps) - 20) more hours)")
    end
    
    # Save summary to CSV
    summary_df = DataFrame([
        (hour = r.hour, status = r.status, files_compared = get(r, :files_compared, 0),
         files_with_diffs = get(r, :files_with_diffs, 0))
        for r in comparison_results
    ])
    
    summary_file = joinpath(output_base_dir, "comparison_summary.csv")
    CSV.write(summary_file, summary_df)
    println("\nSummary saved to: $summary_file")
    
    # Calculate overall statistics
    total_files_compared = sum(get(r, :files_compared, 0) for r in successful_comps; init=0)
    total_files_with_diffs = sum(get(r, :files_with_diffs, 0) for r in successful_comps; init=0)
    
    if length(successful_comps) == total_dirs
        println("\n🎉 All hourly comparisons completed successfully!")
        println("Overall: $total_files_with_diffs out of $total_files_compared files had differences")
    else
        println("\n⚠️  $(length(successful_comps)) out of $total_dirs comparisons completed successfully.")
        if length(successful_comps) > 0
            println("Successfully processed files: $total_files_with_diffs out of $total_files_compared had differences")
        end
    end
    
    println("="^80)
    
    return comparison_results
end

# Run comparisons if script is executed directly
comparison_results = run_all_hourly_comparisons()
