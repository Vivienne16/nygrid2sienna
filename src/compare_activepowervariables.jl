using CSV
using DataFrames
using Statistics

# Paths to the result directories
dir2 = "/Users/vivienneliu/GitHub/nygrid2sienna/TestRun/clcpa2030test-3/results"
dir1 = "/Users/vivienneliu/GitHub/nygrid2sienna/TestRun/mer_clcpa2030test-3/results"

# Get all ActivePower*Variable files
function get_activepower_files(directory)
    files = readdir(directory)
    return filter(f -> startswith(f, "ActivePowerVariable__") || 
                      startswith(f, "ActivePowerInVariable__") || 
                      startswith(f, "ActivePowerOutVariable__"), files)
end

# Save difference CSV for a pair of files
function save_difference_csv(filename, df1, df2, diffs, common_cols)
    # Create output directory if it doesn't exist
    output_dir = "comparison_results"
    if !isdir(output_dir)
        mkdir(output_dir)
    end
    
    # Create filename for diff CSV
    base_name = replace(filename, ".csv" => "")
    diff_filename = joinpath(output_dir, "$(base_name)_differences.csv")
    
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
function compare_activepowervariable_files(dir1, dir2)
    files1 = get_activepower_files(dir1)
    files2 = get_activepower_files(dir2)
    
    println("ActivePower*Variable files found:")
    println("Directory 1 (clcpa2030test): ", files1)
    println("Directory 2 (mer_clcpa2030test): ", files2)
    println()
    
    # Check if same files exist in both directories
    common_files = intersect(files1, files2)
    
    if length(common_files) != length(files1) || length(common_files) != length(files2)
        println("Warning: Different files in the two directories!")
        println("Files only in dir1: ", setdiff(files1, files2))
        println("Files only in dir2: ", setdiff(files2, files1))
        println()
    end
    
    # Load and compare each common file
    results = Dict()
    
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

        for col in common_cols
            # Defensive column extraction
            col1 = df1[!, col]
            col2 = df2[!, col]

            # Numerical comparison (handle missings)
            is_num = eltype(col1) <: Number && eltype(col2) <: Number
            if is_num
                # compute diffs skipping pairs where either is missing
                diffs_list = Float64[]
                for (x, y) in zip(col1, col2)
                    if !(ismissing(x) || ismissing(y))
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

                if max_abs_diff > tol || any(ismissing.(col1) .!= ismissing.(col2))
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
                eqcount = count(x -> x === true, (col1 .== col2))
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

        # Only print summary if there are differences
        if !isempty(diffs)
            println("Differences in file: $file")
            println("="^60)
            if haskey(diffs, "dimensions")
                println("  Different dimensions:")
                println("    dir1: $(diffs["dimensions"][1])")
                println("    dir2: $(diffs["dimensions"][2])")
            end
            if haskey(diffs, "columns_only_in_dir1") || haskey(diffs, "columns_only_in_dir2")
                println("  Column list differences:")
                println("    only in dir1: ", get(diffs, "columns_only_in_dir1", String[]))
                println("    only in dir2: ", get(diffs, "columns_only_in_dir2", String[]))
            end
            if haskey(diffs, "column_differences")
                println("  Column value differences:")
                for (c, info) in diffs["column_differences"]
                    if info["type"] == "numeric"
                        println("    $c : numeric — max_abs_diff=$(info["max_abs_diff"]), mean_abs_diff=$(info["mean_abs_diff"])")
                    else
                        println("    $c : non-numeric — rows differing=$(info["rows_differ"])")
                    end
                end
            end
            println()
        end

        # Save difference CSV if there are differences
        if !isempty(diffs)
            save_difference_csv(file, df1, df2, diffs, common_cols)
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
    
    return results
end

# Run the comparison
println("Comparing ActivePower*Variable files between directories...")
println("Directory 1: $dir1")
println("Directory 2: $dir2")
println()

results = compare_activepowervariable_files(dir1, dir2)

println("Comparison complete!")
println("Results stored in 'results' dictionary with the following keys:")
for key in keys(results)
    println("  - $key")
end