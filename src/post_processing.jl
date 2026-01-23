using PowerAnalytics
const PA = PowerAnalytics
using Feather
using JSON
using DataFrames
using PowerSimulations
using StorageSystemsSimulations
using HydroPowerSimulations
using InfrastructureSystems
using TimeSeries
using CSV
using DataFrames
using Plots
using Statistics
using PowerSystems
using ArgParse
const PSY = PowerSystems
const PSI = PowerSimulations


function nondtcols(df::DataFrame)
    return names(df)[.!([el <: DateTime || el <: Date || el <: Time for el in eltype.(eachcol(df))])]
end

function nondtvals(df::DataFrame)
    return df[!, nondtcols(df)]
end

# results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/2030_MER_Test_PTDF"
results_dir = "/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERHourlySimulations_UC_noreserve_newre"
results_folders = readdir(results_dir)
filter!(x-> isdir(joinpath(results_dir, x)), results_folders)
# system = System("/home/fs02/pmr82_0001/ml2589/nygrid2sienna/MERsystems/baseline_nys2030_2019.json")
# aggregation = PA.make_fuel_dictionary(system,PA.get_generator_mapping("src/generator_mapping.yaml"))
# JSON.write("src/aggregation.json", JSON.json(aggregation,4))
for folder in results_folders
    status_file = joinpath(results_dir, folder, "results", "status.json")
    if isfile(status_file)
        status_data = JSON.parsefile(status_file)
        if get(status_data, "run_status", "") != "SUCCESSFULLY_FINALIZED"
            error("Simulation in folder $folder did not complete successfully.")
        end
    end
    result_dir = joinpath(results_dir, folder)
    results = SimulationResults(result_dir)
    results_us = get_decision_problem_results(results, "UC")
    variables = PSI.read_realized_variables(results_us)
    parameters = PSI.read_realized_parameters(results_us)
    timestamps = copy(PSI.get_realized_timestamps(results_us))
    df = DataFrame()
    for (name, _df) in merge(variables, parameters)
        temp_df = stack(_df)
        temp_df[:, :"metric"] .= name
        append!(df, temp_df)
    end
    
    # Filter out variables that contain "AggGen" in their names
    df = filter(row -> !occursin("AggGen", row.variable), df)
    println("Filtered out AggGen variables. Remaining rows: $(nrow(df))")
    
    load = PA.get_load_data(results_us)
    # Get the raw load DataFrame without combining categories to preserve individual bus data
    _df = load.data[:Load]  # Access the Load DataFrame directly
    
    # Filter load columns to only keep buses 37-82
    load_cols = names(_df)  # Get column names from the DataFrame
    filtered_load_cols = ["DateTime"]  # Always keep DateTime column
    
    for col in load_cols
        if col != "DateTime"
            # Extract bus number from column name (format: *_load_XX or similar)
            bus_match = match(r"_(\d+)$", string(col))
            if bus_match !== nothing
                bus_num = parse(Int, bus_match.captures[1])
                if 37 <= bus_num <= 82
                    push!(filtered_load_cols, col)
                end
            end
        end
    end
    
    # Keep only the filtered columns
    _df = _df[!, filtered_load_cols]
    println("Filtered load data to buses 37-82. Columns kept: $(length(filtered_load_cols)-1)")
    
    # Now combine the filtered categories
    _df_combined = DataFrame(DateTime = _df.DateTime, Load = sum(eachcol(_df[!, Not(:DateTime)])))
    _df = _df_combined
    
    df_load = copy(_df)
    _df = stack(_df)
    _df[:, :"metric"] .= "Load"
    
    # Append the stacked load data to main dataframe
    append!(df, _df)
    output_dir = joinpath(results_dir, folder,"results")
    mkpath(output_dir)
    feather_file = joinpath(output_dir, "$folder.feather")
    Feather.write(feather_file, df)

    
end