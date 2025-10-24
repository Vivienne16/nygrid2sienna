using CSV
using DataFrames
using Dates
using TimeSeries

results = SimulationResults(sim; ignore_status=true);
results_uc = get_decision_problem_results(results, "UC");
variables = get_variable_timeseries(results_uc)
duals = read_realized
price_ts = lmp
line_config = branch_flow[!,"Flow"]


