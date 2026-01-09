using CSV
using DataFrames
using Statistics
using Glob

# Configuration
base_dir1 = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC/baseline_simulation/results"  # Base case
hourly_simulations_base = "MERHourlySimulations_fixstor"  # Base directory for hourly results
output_base_dir = "hourly_comparison_results_UC"

# Get all ActivePower*Variable files
function get_activepower_files(directory)
    files = readdir(directory)
    return filter(f -> startswith(f, "ActivePowerVariable__") || 
                      startswith(f, "ActivePowerInVariable__") || 
                      startswith(f, "ActivePowerOutVariable__"), files)
end

# Save difference CSV for a pair of files
function save_difference_csv(filename, df2, df1, diffs, common_cols, output_dir, hour)
    # Create output directory if it doesn't exist
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    # Create filename for diff CSV
    base_name = replace(filename, ".csv" => "")
    diff_filename = joinpath(output_dir, "$(base_name)_hour_$(hour)_differences.csv")
    
    # Build full diff DataFrame (keep all timestamps / rows)
    max_rows = max(nrow(df1), nrow(df2))

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
        if ts_col in names(df1) && nrow(df1) >= nrow(df2)
            diff_df[!, string(ts_col)] = vcat(df1[!, ts_col], fill(missing, max_rows - nrow(df1)))
        elseif ts_col in names(df2)
            diff_df[!, string(ts_col)] = vcat(df2[!, ts_col], fill(missing, max_rows - nrow(df2)))
        end
    else
        diff_df.row_index = 1:max_rows
    end

    # For each common column (except timestamp if used), add only diff columns
    for col in common_cols
        if !isnothing(ts_col) && col == ts_col
            continue
        end
        col1 = nrow(df1) >= max_rows ? df1[!, col] : vcat(df1[!, col], fill(missing, max_rows - nrow(df1)))
        col2 = nrow(df2) >= max_rows ? df2[!, col] : vcat(df2[!, col], fill(missing, max_rows - nrow(df2)))

        # Numeric: compute dir1 - dir2, keeping zeros and missings
        if eltype(col1) <: Number && eltype(col2) <: Number
            diff_col = Vector{Union{Float64, Missing}}(undef, max_rows)
            for i in 1:max_rows
                if i <= length(col1) && i <= length(col2)
                    if !(ismissing(col1[i]) || ismissing(col2[i]))
                        raw_diff = float(col1[i]) - float(col2[i])
                        # Set to 0 if absolute difference is less than 1e-4
                        diff_col[i] = abs(raw_diff) < 1e-4 ? 0.0 : raw_diff
                    else
                        diff_col[i] = missing
                    end
                elseif i <= length(col1)
                    # df2 is shorter -> treat missing
                    diff_col[i] = missing
                else
                    diff_col[i] = missing
                end
            end
            diff_df[!, "$(col)_diff"] = diff_col
        else
            # Non-numeric: boolean indicating match; treat missing appropriately
            match_col = Vector{Union{Bool, Missing}}(undef, max_rows)
            for i in 1:max_rows
                v1 = i <= length(col1) ? col1[i] : missing
                v2 = i <= length(col2) ? col2[i] : missing
                if ismissing(v1) || ismissing(v2)
                    match_col[i] = missing
                else
                    match_col[i] = v1 == v2
                end
            end
            diff_df[!, "$(col)_match"] = match_col
        end
    end

    # Always save full diff CSV (user requested keeping zeros and all timestamps)
    CSV.write(diff_filename, diff_df)
    println("  Saved differences to: $diff_filename")
end

# Load and compare ActivePower*Variable files
function compare_activepowervariable_files(dir1, dir2, hour, output_dir)
    files1 = get_activepower_files(dir1)
    files2 = get_activepower_files(dir2)
    
    println("  ActivePower*Variable files found:")
    println("    Base case: ", length(files1), " files")
    println("    Hour $hour case: ", length(files2), " files")
    
    # Check if same files exist in both directories
    common_files = intersect(files1, files2)
    
    if length(common_files) != length(files1) || length(common_files) != length(files2)
        println("  Warning: Different files in the two directories!")
        println("    Files only in base: ", setdiff(files1, files2))
        println("    Files only in hour $hour: ", setdiff(files2, files1))
    end
    
    # Load and compare each common file
    results = Dict()
    files_with_diffs = 0
    
    for file in common_files
        # Load data from both directories
        df1 = CSV.read(joinpath(dir1, file), DataFrame)
        df2 = CSV.read(joinpath(dir2, file), DataFrame)

        diffs = Dict{String, Any}()

        # Check dimensions
        dim1 = size(df1)
        dim2 = size(df2)
        if dim1 != dim2
            diffs["dimensions"] = (dim1, dim2)
        end

        # Check columns
        cols1 = names(df1)
        cols2 = names(df2)
        if cols1 != cols2
            diffs["columns_only_in_dir1"] = setdiff(cols1, cols2)
            diffs["columns_only_in_dir2"] = setdiff(cols2, cols1)
        end

        # Compare values for common columns and collect only differences
        common_cols = intersect(cols1, cols2)
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
        if nrow(df1) != nrow(df2) && !isnothing(timestamp_col)
            println("    Warning: Different data sizes ($(nrow(df1)) vs $(nrow(df2)) rows). Aligning by $timestamp_col...")
            # Find overlapping timestamps
            ts1 = df1[!, timestamp_col]
            ts2 = df2[!, timestamp_col]
            common_timestamps = intersect(ts1, ts2)
            
            if !isempty(common_timestamps)
                # Filter both dataframes to common timestamps
                df1_filtered = filter(row -> row[timestamp_col] in common_timestamps, df1)
                df2_filtered = filter(row -> row[timestamp_col] in common_timestamps, df2)
                
                # Sort by timestamp to ensure proper alignment
                sort!(df1_filtered, timestamp_col)
                sort!(df2_filtered, timestamp_col)
                
                println("    Comparing $(length(common_timestamps)) overlapping timestamps")
                df1 = df1_filtered
                df2 = df2_filtered
            else
                println("    Warning: No overlapping timestamps found!")
            end
        end

        for col in common_cols
            # Defensive column extraction
            col1 = df1[!, col]
            col2 = df2[!, col]

            # Skip comparison if arrays have different sizes and we couldn't align them
            if length(col1) != length(col2)
                println("    Skipping column $col due to size mismatch ($(length(col1)) vs $(length(col2)))")
                continue
            end

            # Numerical comparison (handle missings)
            is_num = eltype(col1) <: Number && eltype(col2) <: Number
            if is_num
                # compute diffs skipping pairs where either is missing
                diffs_list = Float64[]
                missing_pattern_differs = false
                
                for (i, (x, y)) in enumerate(zip(col1, col2))
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
                    # if all entries missing on at least one side, treat as difference only if patterns differ
                    max_abs_diff = 0.0
                    mean_abs_diff = 0.0
                end

                if max_abs_diff > tol || missing_pattern_differs
                    col_diffs[string(col)] = Dict(
                        "type" => "numeric",
                        "max_abs_diff" => max_abs_diff,
                        "mean_abs_diff" => mean_abs_diff,
                        "stats_dir1" => (minimum(skipmissing(col1)), maximum(skipmissing(col1)), mean(skipmissing(col1))) |> x -> x,
                        "stats_dir2" => (minimum(skipmissing(col2)), maximum(skipmissing(col2)), mean(skipmissing(col2))) |> x -> x,
                    )
                end
            else
                # Non-numeric: check element-wise equality while handling missing
                eqcount = 0
                for (x, y) in zip(col1, col2)
                    if x == y  # This handles missing == missing as true
                        eqcount += 1
                    end
                end
                nrows = length(col1)
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
            save_difference_csv(file, df1, df2, diffs, common_cols, output_dir, hour)
            files_with_diffs += 1
        end

        # Store results including differences
        results[file] = Dict(
            "df1" => df1,
            "df2" => df2,
            "dimensions1" => dim1,
            "dimensions2" => dim2,
            "common_cols" => common_cols,
            "differences" => diffs,
        )
    end
    
    return results, files_with_diffs, length(common_files)
end

# Find all hourly simulation directories and merge their daily results
function find_and_merge_hourly_simulation_dirs()
    if !isdir(hourly_simulations_base)
        error("Hourly simulations base directory not found: $hourly_simulations_base")
    end
    
    # Look for hour_XX directories
    dirs = readdir(hourly_simulations_base)
    hour_dirs = filter(d -> startswith(d, "hour_") && isdir(joinpath(hourly_simulations_base, d)), dirs)
    
    # Extract hour numbers and merge daily results for each hour
    merged_hour_data = []
    for dir in hour_dirs
        match_result = match(r"hour_(\d+)", dir)
        if match_result !== nothing
            hour = parse(Int, match_result.captures[1])
            full_path = joinpath(hourly_simulations_base, dir)
            day_dirs = readdir(full_path)
            
            println("Processing hour $hour with $(length(day_dirs)) daily simulations...")
            
            # Merge all daily results for this hour
            merged_results_dir = joinpath(hourly_simulations_base, "merged_hour_$hour")
            if !isdir(merged_results_dir)
                mkpath(merged_results_dir)
            end
            
            # Get list of files to merge from first daily simulation
            first_day_dir = joinpath(full_path, day_dirs[1], "results")
            if !isdir(first_day_dir)
                println("  Warning: No results directory found in first daily simulation")
                continue
            end
            
            files_to_merge = get_activepower_files(first_day_dir)
            
            # Merge each file type across all daily simulations
            for filename in files_to_merge
                println("  Merging file: $filename")
                merged_df = DataFrame()
                
                for day_dir in day_dirs
                    results_dir = joinpath(full_path, day_dir, "results")
                    file_path = joinpath(results_dir, filename)
                    
                    if isfile(file_path)
                        df = CSV.read(file_path, DataFrame)
                        if isempty(merged_df)
                            merged_df = df
                        else
                            append!(merged_df, df)
                        end
                    end
                end
                
                # Sort by DateTime if present
                if "DateTime" in names(merged_df)
                    sort!(merged_df, :DateTime)
                end
                
                # Save merged file
                merged_file_path = joinpath(merged_results_dir, filename)
                CSV.write(merged_file_path, merged_df)
                println("    Merged $(nrow(merged_df)) rows from $(length(day_dirs)) daily simulations")
            end
            
            push!(merged_hour_data, (hour=hour, results_path=merged_results_dir))
        end
    end
    
    # Sort by hour
    sort!(merged_hour_data, by=x -> x.hour)
    
    return merged_hour_data
end

function run_all_hourly_comparisons()
    """Run comparisons for all hourly simulation results against base case."""
    
    println("="^80)
    println("BATCH COMPARISON: HOURLY SIMULATIONS VS BASE CASE")
    println("="^80)
    println("Base case directory: $base_dir1")
    println("Hourly simulations base: $hourly_simulations_base")
    println()
    
    # Check if base case directory exists
    if !isdir(base_dir1)
        error("Base case directory not found: $base_dir1")
    end
    
    # Find and merge all hourly simulation directories
    hour_dirs = find_and_merge_hourly_simulation_dirs()
    
    if isempty(hour_dirs)
        error("No hourly simulation directories found in $hourly_simulations_base")
    end
    
    println("Found and merged $(length(hour_dirs)) hourly simulation directories:")
    for hour_info in hour_dirs
        println("  Hour $(hour_info.hour): $(hour_info.results_path)")
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
        merged_results_dir = hour_info.results_path
        
        println("--- Processing hour $hour ($i of $total_dirs) ---")
        println("Comparing:")
        println("  Base case: $base_dir1")
        println("  Hour $hour (merged):   $merged_results_dir")
        
        try
            # Create hour-specific output directory
            hour_output_dir = joinpath(output_base_dir, "hour_$(hour)")
            
            # Run comparison using merged results
            results, files_with_diffs, total_files = compare_activepowervariable_files(base_dir1, merged_results_dir, hour, hour_output_dir)
            
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
    
    summary_file = joinpath(output_base_dir, "comparison_summary.csv")
    CSV.write(summary_file, summary_df)
    println("\\nSummary saved to: $summary_file")
    
    # Calculate overall statistics
    total_files_compared = sum(get(r, :files_compared, 0) for r in successful_comps)
    total_files_with_diffs = sum(get(r, :files_with_diffs, 0) for r in successful_comps)
    
    if length(successful_comps) == total_dirs
        println("\\n🎉 All hourly comparisons completed successfully!")
        println("Overall: $total_files_with_diffs out of $total_files_compared files had differences")
    else
        println("\\n⚠️  $(length(successful_comps)) out of $total_dirs comparisons completed successfully.")
    end
    
    println("="^80)
    
    return comparison_results
end

# Run comparisons if script is executed directly

comparison_results = run_all_hourly_comparisons()
