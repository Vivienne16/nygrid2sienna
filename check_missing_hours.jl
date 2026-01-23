"""
Check which hours are missing from the simulation results.

This script checks if all 8760 hours have been successfully simulated
and reports any missing hours.

Usage:
    julia check_missing_hours.jl [results_directory]

Arguments:
    results_directory: Optional. Directory containing hourly simulation results.
                      Defaults to "MERHourlySimulations_UC_noreserve_pmin_fixed_new"
"""

using Glob

function check_missing_hours(results_dir::String)
    println("="^80)
    println("CHECKING SIMULATION COMPLETION")
    println("Results directory: $results_dir")
    println("="^80)
    
    # Check if results directory exists
    if !isdir(results_dir)
        error("Results directory not found: $results_dir")
    end
    
    # Find all hour directories
    hour_dirs = glob("hour_*", results_dir)
    
    # Extract hour numbers from directory names
    completed_hours = Set{Int}()
    for dir in hour_dirs
        # Extract hour number from path like "MERHourlySimulations_UC_noreserve/hour_1234"
        dir_name = basename(dir)
        hour_match = match(r"hour_(\d+)", dir_name)
        if hour_match !== nothing
            hour_num = parse(Int, hour_match.captures[1])
            if hour_num >= 1 && hour_num <= 8760
                push!(completed_hours, hour_num)
            end
        end
    end
    
    # Find missing hours
    all_hours = Set(1:8760)
    missing_hours = sort(collect(setdiff(all_hours, completed_hours)))
    
    # Report results
    println("\nTotal hours expected: 8760")
    println("Total hours completed: $(length(completed_hours))")
    println("Total hours missing: $(length(missing_hours))")
    
    if isempty(missing_hours)
        println("\n✓ All hours completed successfully!")
    else
        println("\n✗ Missing hours:")
        
        # Group consecutive missing hours for easier reading
        if !isempty(missing_hours)
            ranges = []
            start_hour = missing_hours[1]
            end_hour = missing_hours[1]
            
            for i in 2:length(missing_hours)
                if missing_hours[i] == end_hour + 1
                    end_hour = missing_hours[i]
                else
                    if start_hour == end_hour
                        push!(ranges, "$start_hour")
                    else
                        push!(ranges, "$start_hour-$end_hour")
                    end
                    start_hour = missing_hours[i]
                    end_hour = missing_hours[i]
                end
            end
            
            # Add the last range
            if start_hour == end_hour
                push!(ranges, "$start_hour")
            else
                push!(ranges, "$start_hour-$end_hour")
            end
            
            println("  Hour ranges: $(join(ranges, ", "))")
        end
        
        # Save missing hours to file
        output_file = joinpath(results_dir, "missing_hours.txt")
        open(output_file, "w") do f
            for hour in missing_hours
                println(f, hour)
            end
        end
        println("\nMissing hours saved to: $output_file")
    end
    
    println("\n" * "="^80)
    
    return missing_hours
end

# Main execution
if length(ARGS) >= 1
    results_dir = ARGS[1]
else
    results_dir = "BASEHourlySimulations_2005"
end

missing_hours = check_missing_hours(results_dir)

# Exit with appropriate code
if isempty(missing_hours)
    exit(0)
else
    exit(1)
end
