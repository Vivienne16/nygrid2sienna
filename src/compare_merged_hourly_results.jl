using CSV
using DataFrames
using Statistics
using Glob
using Dates

# Configuration
baseline_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation/results"  # Base case
hourly_simulations_base = "MERHourlySimulations_fixstor"  # Base directory for hourly results
output_base_dir = "merged_hourly_comparison_results_fixstor"

!isdir(output_base_dir) && mkpath(output_base_dir)
# Get all ActivePower*Variable files
function get_activepower_files(directory)
    files = readdir(directory)
    return filter(f -> startswith(f, "ActivePowerVariable__") || 
                      startswith(f, "ActivePowerInVariable__") || 
                      startswith(f, "ActivePowerOutVariable__"), files)
end

# Find all daily simulation results for a given hour
function find_daily_simulation_dirs(hour_dir)
    """Find all day-specific simulation directories within an hour directory."""
    
    if !isdir(hour_dir)
        error("Hour directory not found: $hour_dir")
    end
    
    println("  Exploring hour directory: $hour_dir")
    
    # Look for hour_X_Y directories where Y is the day number
    dirs = readdir(hour_dir)
    day_dirs = filter(d -> occursin(r"hour_\d+_\d+", d) && isdir(joinpath(hour_dir, d)), dirs)
    
    println("  Found $(length(day_dirs)) daily directories: $day_dirs")
    
    # Extract day numbers and sort
    day_info = []
    for dir in day_dirs
        match_result = match(r"hour_(\d+)_(\d+)", dir)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            day = parse(Int, match_result.captures[2])
            full_path = joinpath(hour_dir, dir)
            
            println("    Checking daily directory: $full_path")
            println("      Contents: $(readdir(full_path))")
            
            # Look for simulation results directory - try multiple patterns
            results_dir = nothing
            
            # Pattern 1: Direct results directory
            if isdir(joinpath(full_path, "results"))
                results_dir = joinpath(full_path, "results")
                println("      Found results at: $results_dir")
            end
            
            # Pattern 2: Look for any subdirectory with "simulation" in name
            if results_dir === nothing
                subdirs = filter(d -> isdir(joinpath(full_path, d)), readdir(full_path))
                sim_dirs = filter(d -> occursin("simulation", d), subdirs)
                if !isempty(sim_dirs)
                    sim_dir = joinpath(full_path, sim_dirs[1])
                    if isdir(joinpath(sim_dir, "results"))
                        results_dir = joinpath(sim_dir, "results")
                        println("      Found results at: $results_dir")
                    end
                end
            end
            
            # Pattern 3: Recursively search for any "results" directory
            if results_dir === nothing
                for subdir in filter(d -> isdir(joinpath(full_path, d)), readdir(full_path))
                    subdir_path = joinpath(full_path, subdir)
                    if isdir(joinpath(subdir_path, "results"))
                        results_dir = joinpath(subdir_path, "results")
                        println("      Found results at: $results_dir")
                        break
                    end
                end
            end
            
            if results_dir !== nothing && isdir(results_dir)
                push!(day_info, (hour=hour, day=day, dir_name=dir, results_path=results_dir))
                println("      ✓ Added to day_info")
            else
                println("      ✗ No results directory found")
            end
        end
    end
    
    # Sort by day
    sort!(day_info, by=x -> x.day)
    
    println("  Final day_info: $(length(day_info)) entries")
    
    return day_info
end

# Merge daily simulation results into a single DataFrame
function merge_daily_results(hour, hour_dir, filename)
    """Merge all daily simulation results for a given hour and filename."""
    
    println("  Merging daily results for file: $filename")
    
    # Find all daily simulation directories
    day_dirs = find_daily_simulation_dirs(hour_dir)
    
    if isempty(day_dirs)
        @warn "No daily simulation directories found in $hour_dir"
        return nothing
    end
    
    println("    Found $(length(day_dirs)) daily simulation results")
    
    # Read and concatenate all daily results
    merged_df = DataFrame()
    
    for day_info in day_dirs
        file_path = joinpath(day_info.results_path, filename)
        
        if !isfile(file_path)
            @warn "File not found: $file_path"
            continue
        end
        
        df = CSV.read(file_path, DataFrame)
        
        # Append to merged DataFrame
        if isempty(merged_df)
            merged_df = df
        else
            append!(merged_df, df)
        end
    end
    
    if isempty(merged_df)
        @warn "No data merged for $filename"
        return nothing
    end
    
    # Sort by DateTime if present
    if "DateTime" in names(merged_df)
        sort!(merged_df, :DateTime)
    end
    
    println("    Merged $(nrow(merged_df)) total rows from $(length(day_dirs)) days")
    
    return merged_df
end

# Save difference CSV for a pair of files
function save_difference_csv(filename, df_baseline, df_hourly, diffs, common_cols, output_dir, hour)
    # Create output directory if it doesn't exist
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    # Create filename for diff CSV
    base_name = replace(filename, ".csv" => "")
    diff_filename = joinpath(output_dir, "$(base_name)_hour_$(hour)_differences.csv")
    
    # Build full diff DataFrame (keep all timestamps / rows)
    max_rows = max(nrow(df_baseline), nrow(df_hourly))

    # Detect a timestamp-like column among common_cols (case-insensitive)
    ts_candidates = [lowercase(string(c)) for c in common_cols]
    ts_names = ["timestamp", "time", "date", "datetime", "t"]
    ts_col = nothing
    for t in ts_names
        idx = findfirst(x -> x == t, ts_candidates)
        if !isnothing(idx)
            ts_col = common_cols[idx]
            break
        end
    end

    # Prepare diff_df and preserve timestamp column first if present
    diff_df = DataFrame()
    if !isnothing(ts_col)
        # take timestamp from the longer dataframe when available
        if ts_col in names(df_baseline) && nrow(df_baseline) >= nrow(df_hourly)
            diff_df[!, string(ts_col)] = vcat(df_baseline[!, ts_col], fill(missing, max_rows - nrow(df_baseline)))
        elseif ts_col in names(df_hourly)
            diff_df[!, string(ts_col)] = vcat(df_hourly[!, ts_col], fill(missing, max_rows - nrow(df_hourly)))
        end
    else
        diff_df.row_index = 1:max_rows
    end

    # For each common column (except timestamp if used), add diff columns
    for col in common_cols
        if !isnothing(ts_col) && col == ts_col
            continue
        end
        col_baseline = nrow(df_baseline) >= max_rows ? df_baseline[!, col] : vcat(df_baseline[!, col], fill(missing, max_rows - nrow(df_baseline)))
        col_hourly = nrow(df_hourly) >= max_rows ? df_hourly[!, col] : vcat(df_hourly[!, col], fill(missing, max_rows - nrow(df_hourly)))

        # Numeric: compute baseline - hourly, keeping zeros and missings
        if eltype(col_baseline) <: Number && eltype(col_hourly) <: Number
            diff_col = Vector{Union{Float64, Missing}}(undef, max_rows)
            for i in 1:max_rows
                if i <= length(col_baseline) && i <= length(col_hourly)
                    if !(ismissing(col_baseline[i]) || ismissing(col_hourly[i]))
                        raw_diff = -float(col_baseline[i]) + float(col_hourly[i])
                        # Set to 0 if absolute difference is less than 1e-4
                        diff_col[i] = abs(raw_diff) < 1e-4 ? 0.0 : raw_diff
                    else
                        diff_col[i] = missing
                    end
                elseif i <= length(col_baseline)
                    # df_hourly is shorter -> treat missing
                    diff_col[i] = missing
                else
                    diff_col[i] = missing
                end
            end
            diff_df[!, "$(col)_diff"] = diff_col
        else
            # Non-numeric: boolean indicating match
            match_col = Vector{Union{Bool, Missing}}(undef, max_rows)
            for i in 1:max_rows
                v1 = i <= length(col_baseline) ? col_baseline[i] : missing
                v2 = i <= length(col_hourly) ? col_hourly[i] : missing
                if ismissing(v1) || ismissing(v2)
                    match_col[i] = missing
                else
                    match_col[i] = v1 == v2
                end
            end
            diff_df[!, "$(col)_match"] = match_col
        end
    end

    # Save full diff CSV
    CSV.write(diff_filename, diff_df)
    println("    Saved differences to: $diff_filename")
end

# Compare baseline with merged hourly results
function compare_merged_results(baseline_dir, hour_dir, hour, output_dir)
    """Compare baseline results with merged daily results for a specific hour."""
    
    println("  Comparing merged results for hour $hour")
    
    # Get list of ActivePower files from baseline
    baseline_files = get_activepower_files(baseline_dir)
    
    if isempty(baseline_files)
        @warn "No ActivePower files found in baseline directory"
        return Dict(), 0, 0
    end
    
    println("    Found $(length(baseline_files)) ActivePower files in baseline")
    
    # Compare each file
    results = Dict()
    files_with_diffs = 0
    total_files = 0
    
    for filename in baseline_files
        println("    Processing: $filename")
        
        # Load baseline data
        baseline_file_path = joinpath(baseline_dir, filename)
        df_baseline = CSV.read(baseline_file_path, DataFrame)
        
        # Merge daily results for this hour
        df_hourly = merge_daily_results(hour, hour_dir, filename)
        
        if df_hourly === nothing
            @warn "Could not merge daily results for $filename in hour $hour"
            continue
        end
        
        total_files += 1
        
        # Compare dimensions
        diffs = Dict{String, Any}()
        dim_baseline = size(df_baseline)
        dim_hourly = size(df_hourly)
        
        if dim_baseline != dim_hourly
            diffs["dimensions"] = (baseline=dim_baseline, hourly=dim_hourly)
        end
        
        # Check columns
        cols_baseline = names(df_baseline)
        cols_hourly = names(df_hourly)
        
        if cols_baseline != cols_hourly
            diffs["columns_only_in_baseline"] = setdiff(cols_baseline, cols_hourly)
            diffs["columns_only_in_hourly"] = setdiff(cols_hourly, cols_baseline)
        end
        
        # Compare values for common columns
        common_cols = intersect(cols_baseline, cols_hourly)
        tol = 1e-12
        col_diffs = Dict{String, Any}()
        
        # Check if we have a DateTime/timestamp column to align data
        timestamp_col = nothing
        for col in common_cols
            if lowercase(string(col)) in ["datetime", "timestamp", "time", "date"]
                timestamp_col = col
                break
            end
        end

        # If DataFrames have different sizes, align them by timestamp if possible
        if nrow(df_baseline) != nrow(df_hourly) && !isnothing(timestamp_col)
            println("    Warning: Different data sizes ($(nrow(df_baseline)) vs $(nrow(df_hourly)) rows). Aligning by $timestamp_col...")
            # Find overlapping timestamps
            ts_baseline = df_baseline[!, timestamp_col]
            ts_hourly = df_hourly[!, timestamp_col]
            common_timestamps = intersect(ts_baseline, ts_hourly)
            
            if !isempty(common_timestamps)
                # Filter both dataframes to common timestamps
                df_baseline_filtered = filter(row -> row[timestamp_col] in common_timestamps, df_baseline)
                df_hourly_filtered = filter(row -> row[timestamp_col] in common_timestamps, df_hourly)
                
                # Sort by timestamp to ensure proper alignment
                sort!(df_baseline_filtered, timestamp_col)
                sort!(df_hourly_filtered, timestamp_col)
                
                println("    Comparing $(length(common_timestamps)) overlapping timestamps")
                df_baseline = df_baseline_filtered
                df_hourly = df_hourly_filtered
            else
                println("    Warning: No overlapping timestamps found!")
            end
        end
        
        for col in common_cols
            col_baseline = df_baseline[!, col]
            col_hourly = df_hourly[!, col]
            
            # Skip comparison if arrays have different sizes and we couldn't align them
            if length(col_baseline) != length(col_hourly)
                println("    Skipping column $col due to size mismatch ($(length(col_baseline)) vs $(length(col_hourly)))")
                continue
            end
            
            # Numerical comparison
            is_num = eltype(col_baseline) <: Number && eltype(col_hourly) <: Number
            if is_num
                diffs_list = Float64[]
                missing_pattern_differs = false
                
                for (i, (x, y)) in enumerate(zip(col_baseline, col_hourly))
                    if ismissing(x) != ismissing(y)
                        missing_pattern_differs = true
                    elseif !(ismissing(x) || ismissing(y))
                        push!(diffs_list, abs(float(x) - float(y)))
                    end
                end
                
                if !isempty(diffs_list)
                    max_abs_diff = maximum(diffs_list)
                    mean_abs_diff = mean(diffs_list)
                else
                    max_abs_diff = 0.0
                    mean_abs_diff = 0.0
                end
                
                if max_abs_diff > tol || missing_pattern_differs
                    col_diffs[string(col)] = Dict(
                        "type" => "numeric",
                        "max_abs_diff" => max_abs_diff,
                        "mean_abs_diff" => mean_abs_diff,
                        "stats_baseline" => (minimum(skipmissing(col_baseline)), maximum(skipmissing(col_baseline)), mean(skipmissing(col_baseline))),
                        "stats_hourly" => (minimum(skipmissing(col_hourly)), maximum(skipmissing(col_hourly)), mean(skipmissing(col_hourly))),
                    )
                end
            else
                # Non-numeric comparison
                eqcount = 0
                for (x, y) in zip(col_baseline, col_hourly)
                    if x == y  # This handles missing == missing as true
                        eqcount += 1
                    end
                end
                nrows = length(col_baseline)
                ndiff = nrows - eqcount
                if ndiff > 0
                    col_diffs[string(col)] = Dict(
                        "type" => "non-numeric",
                        "rows_differ" => ndiff,
                    )
                end
            end
        end
        
        if !isempty(col_diffs)
            diffs["column_differences"] = col_diffs
        end
        
        # Save difference CSV if there are differences
        if !isempty(diffs)
            save_difference_csv(filename, df_baseline, df_hourly, diffs, common_cols, output_dir, hour)
            files_with_diffs += 1
        end
        
        # Store results
        results[filename] = Dict(
            "df_baseline" => df_baseline,
            "df_hourly" => df_hourly,
            "dimensions_baseline" => dim_baseline,
            "dimensions_hourly" => dim_hourly,
            "common_cols" => common_cols,
            "differences" => diffs,
        )
    end
    
    return results, files_with_diffs, total_files
end

# Find all hourly simulation directories
function find_hourly_simulation_dirs()
    if !isdir(hourly_simulations_base)
        error("Hourly simulations base directory not found: $hourly_simulations_base")
    end
    
    # Look for hour_XX directories
    dirs = readdir(hourly_simulations_base)
    hour_dirs = filter(d -> startswith(d, "hour_") && isdir(joinpath(hourly_simulations_base, d)), dirs)
   
    # Extract hour numbers and sort
    hour_info = []
    for dir_name in hour_dirs
        match_result = match(r"hour_(\d+)$", dir_name)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            full_path = joinpath(hourly_simulations_base, dir_name)
            push!(hour_info, (hour=hour, dir_name=dir_name, dir_path=full_path))
        end
    end
    
    # Sort by hour
    sort!(hour_info, by=x -> x.hour)
    
    return hour_info
end

function run_all_merged_hourly_comparisons()
    """Run comparisons for all merged hourly simulation results against baseline."""
    
    println("="^80)
    println("BATCH COMPARISON: MERGED HOURLY SIMULATIONS VS BASELINE")
    println("="^80)
    println("Baseline directory: $baseline_dir")
    println("Hourly simulations base: $hourly_simulations_base")
    println()
    
    # Check if baseline directory exists
    if !isdir(baseline_dir)
        error("Baseline directory not found: $baseline_dir")
    end
    
    # Find all hourly simulation directories
    hour_dirs = find_hourly_simulation_dirs()
    
    if isempty(hour_dirs)
        error("No hourly simulation directories found in $hourly_simulations_base")
    end
    
    println("Found $(length(hour_dirs)) hourly simulation directories:")
    for hour_info in hour_dirs
        println("  Hour $(hour_info.hour): $(hour_info.dir_path)")
    end
    println()
    
    # Create main output directory
    if !isdir(output_base_dir)
        mkpath(output_base_dir)
    end
    
    # Run comparisons
    comparison_results = []
    total_dirs = length(hour_dirs)
    
    for (i, hour_info) in enumerate(hour_dirs)
        hour = hour_info.hour
        hour_dir = hour_info.dir_path
        
        println("--- Processing hour $hour ($i of $total_dirs) ---")
        println("Comparing:")
        println("  Baseline:  $baseline_dir")
        println("  Hour $hour:    $hour_dir (merged from daily results)")
        
        try
            # Create hour-specific output directory
            hour_output_dir = joinpath(output_base_dir, "hour_$(lpad(hour, 2, '0'))")
            
            # Run comparison with merged results
            results, files_with_diffs, total_files = compare_merged_results(baseline_dir, hour_dir, hour, hour_output_dir)
            
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
    
    println("\\nSuccessful comparisons:")
    println("Hour | Files Compared | Files with Diffs | Output Directory")
    println("-"^70)
    for comp in successful_comps
        println("$(lpad(comp.hour, 4)) | $(lpad(comp.files_compared, 14)) | $(lpad(comp.files_with_diffs, 16)) | $(comp.output_dir)")
    end
    
    # Save summary to CSV
    summary_df = DataFrame([
        (hour = r.hour, status = r.status, files_compared = get(r, :files_compared, 0),
         files_with_diffs = get(r, :files_with_diffs, 0), output_dir = get(r, :output_dir, ""))
        for r in comparison_results
    ])
    
    summary_file = joinpath(output_base_dir, "merged_comparison_summary.csv")
    CSV.write(summary_file, summary_df)
    println("\\nSummary saved to: $summary_file")
    
    # Calculate overall statistics
    total_files_compared = sum(get(r, :files_compared, 0) for r in successful_comps; init=0)
    total_files_with_diffs = sum(get(r, :files_with_diffs, 0) for r in successful_comps; init=0)
    
    if length(successful_comps) == total_dirs
        println("\\n🎉 All merged hourly comparisons completed successfully!")
        println("Overall: $total_files_with_diffs out of $total_files_compared files had differences")
    else
        println("\\n⚠️  $(length(successful_comps)) out of $total_dirs comparisons completed successfully.")
        if length(successful_comps) > 0
            println("Successfully processed files: $total_files_with_diffs out of $total_files_compared had differences")
        end
    end
    
    println("="^80)
    
    return comparison_results
end

# Run comparisons if script is executed directly
comparison_results = run_all_merged_hourly_comparisons()
