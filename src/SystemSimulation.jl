using Revise
using PowerSimulations
using Dates
using Logging
using PowerGraphics
using PowerSystems
# logger = configure_logging(console_level=Logging.Info)
const PSI = PowerSimulations
const PSY = PowerSystems
const PG = PowerGraphics
using TimeSeries
using JuMP
# using HiGHS
# using Xpress
using Gurobi
using StorageSystemsSimulations
using HydroPowerSimulations
using DataFrames
using CSV
const SSS = StorageSystemsSimulations
# Include the parsing utilities script
include("parsing_utils.jl")
include("post_process.jl")
# Simulation setup parameters
mer = false
load_year = 2019

if mer == false
    sys_name = "mer_nys2030_$load_year.json"
    sim_name = "mer_clcpa2030test"
else
    sys_name = "nys2030_$load_year.json"
    sim_name = "clcpa2030test"
end

output_dir = "HourlySimulation"
interval = 24
horizon = 48
steps = 364

# Check if the output directory exists, create if not
if !ispath(output_dir)
    mkpath(output_dir)
end

# Replace the HiGHS optimizer with Gurobi
solver = optimizer_with_attributes(
    () -> Gurobi.Optimizer(GRB_ENV),
    "TimeLimit" => 10000.0,     # Set the maximum solver time (in seconds)
    "OutputFlag" => 1,          # Enable logging to console
    "Threads" => 8,             # Set the number of solver threads to use
    "MIPGap" => 1e-3            # Set the relative MIP gap tolerance
)

# solver = optimizer_with_attributes(
#     Xpress.Optimizer,
#     "MIPRELSTOP" => 1e-3, # Set the relative mip gap tolerance
#     "OUTPUTLOG" => 1, # Enable logging
#     "MAXTIME" => 60, # Set the maximum solver time (in seconds)
#     "THREADS" => 8, # Set the number of solver threads to use
#     # "MAXMEMORYSOFT" => 30000, # Set the maximum amount of memory the solver can use (in MB)
# )

solver = optimizer_with_attributes(
    HiGHS.Optimizer,
    "time_limit" => 600.0,     # Set the maximum solver time (in seconds)
    # "threads" => 12,       
    "log_to_console" => true,  # Enable logging
    "mip_abs_gap" => 5e-3,      # Set the relative MIP gap tolerance
)
# Create a power system
sys = System(sys_name) 
add_reserves(sys; reg_reserve_frac=0.05, spinning_reserve_frac=0.1);
# Transform time series data for the specified horizon and interval
PSY.transform_single_time_series!(sys, Hour(horizon), Hour(interval))

# Create a unit commitment template using DC power flow model
# template_uc = PSI.template_unit_commitment(; network=NetworkModel(PSI.AreaBalancePowerModel, use_slacks=false, PTDF_matrix=PTDF(sys)))
template_uc = PSI.template_unit_commitment(; network=NetworkModel(PSI.DCPPowerModel,use_slacks=true, PTDF_matrix=PTDF(sys)))
# template_uc = PSI.template_unit_commitment(; network=NetworkModel(PSI.CopperPlatePowerModel, use_slacks=false, PTDF_matrix=PTDF(sys)))
# Set device models for different components
set_device_model!(template_uc, DeviceModel(ThermalStandard, ThermalDispatchNoMin))
# set_device_model!(template_uc, DeviceModel(ThermalStandard, ThermalBasicDispatch;duals=[PSI.ActivePowerVariableLimitsConstraint]))
set_device_model!(template_uc, StandardLoad, StaticPowerLoad)
set_device_model!(template_uc, DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves))
# set_device_model!(template_uc, DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves;duals=[SSS.StateofChargeLimitsConstraint,PSI.InputActivePowerVariableLimitsConstraint,PSI.OutputActivePowerVariableLimitsConstraint,EnergyBalanceConstraint]))
# set_device_model!(template_uc, DeviceModel(Transformer2W, StaticBranch;use_slacks=true,duals=[NetworkFlowConstraint]))
# set_device_model!(template_uc, DeviceModel(Line, StaticBranch;use_slacks=true,duals=[NetworkFlowConstraint]))
set_device_model!(template_uc, DeviceModel(Transformer2W, StaticBranch;use_slacks=true))
set_device_model!(template_uc, DeviceModel(Line, StaticBranch;use_slacks=true))
set_device_model!(template_uc, TwoTerminalHVDCLine, HVDCTwoTerminalLossless)
set_device_model!(template_uc, RenewableNonDispatch, FixedOutput)
set_device_model!(template_uc, RenewableDispatch, RenewableFullDispatch)
set_device_model!(template_uc, HydroDispatch, HydroDispatchRunOfRiver)
# set_service_model!(template_uc, ServiceModel(TransmissionInterface, ConstantMaxInterfaceFlow; duals=[PSI.InterfaceFlowLimit],use_slacks=true))
set_service_model!(template_uc, ServiceModel(TransmissionInterface, ConstantMaxInterfaceFlow))
# Create simulation models
models = SimulationModels(
    decision_models=[
        DecisionModel(
            template_uc,
            sys,
            name="UC",
            optimizer=solver,
            initialize_model=false,
            optimizer_solve_log_print=true,
            check_numerical_bounds=true,
            warm_start=true,
            store_variable_names=true,
        ),
    ],
)

# Create a simulation sequence
sequence = SimulationSequence(models=models, ini_cond_chronology=InterProblemChronology())

# Create a simulation object
sim = Simulation(
    name="$(sim_name)",
    steps=steps,
    models=models,
    sequence=sequence,
    simulation_folder=output_dir,
    # initial_time=DateTime("2019-07-18T14:00:00")
)

# Build and execute the simulation
build!(sim, serialize=true)
execute!(sim, enable_progress_bar=true)

model = get_simulation_model(sim, :UC)
# JuMP.write_to_file(model.internal.container.JuMPmodel, "model.lp")
results = SimulationResults(sim; ignore_status=true);
results_uc = get_decision_problem_results(results, "UC");
set_system!(results_uc, sys);
variables = PSI.read_realized_variables(results_uc)
duals = PSI.read_realized_duals(results_uc)
export_results_csv(results_uc, variables, "ED", joinpath(results.path, "results"))
# PSI.compute_conflict!(model.internal.container)
# plotlyjs()
# p = PG.plot_fuel(
#     results_uc;
#     curtailment=true,
#     display=false,
#     title="all_plants_case_dispatch", # saved plot will saved with the title as its name
#     slacks=true,
#     generator_mapping_file="src/generator_mapping.yaml",
#     palette=PG.load_palette("src/color.yaml"),
#     save=".",
#     format="html"
# );

PTDF_matrix = PTDF(sys)
base_power = get_base_power(sys)
λ = PSI.read_realized_dual(results_uc, "CopperPlateBalanceConstraint__System")[:, 2]
duals_line = PSI.read_realized_dual(results_uc, "NetworkFlowConstraint__Line")
duals_transformer = PSI.read_realized_dual(results_uc, "NetworkFlowConstraint__Transformer2W")
lmp = duals_line[:, [:DateTime]]
for bus in get_components(ACBus, sys)
    if in(get_number(bus),PTDF_matrix.axes[1])
        lmp[:, get_name(bus)] = (λ .+ sum(duals_line[:,l]*PTDF_matrix[l,get_number(bus)] for l in names(duals_line)[2:end])) ./base_power
    end
end
lmp = lmp/-100.0
CSV.write("lmp_DC.csv", lmp)

pg = variables["ActivePowerVariable__ThermalStandard"]
lims = get_active_power_limits.(get_components(ThermalStandard, sys))
# extract min and max into plain Float64 vectors
pmin = [l.min for l in lims]*100
pmax = [l.max for l in lims]*100
bus_id = get_name.(get_bus.(get_components(ThermalStandard, sys)))
gen_to_bus = Dict()
gen_cost = Dict()
for gen in get_components(ThermalStandard, sys)
    gen_name = get_name(gen)
    bus_name = get_name(get_bus(gen))
    op_cost = get_operation_cost(gen)
    variable_cost = op_cost.variable
    fuel_cost = variable_cost.fuel_cost
    heat_rate = variable_cost.value_curve.function_data.proportional_term
    cost_a = fuel_cost .* heat_rate
    gen_to_bus[gen_name] = bus_name
    gen_cost[gen_name] = cost_a
end

# Build gen dispatch DataFrame from realized variables for ThermalStandard
# `pg` is the realized ActivePowerVariable__ThermalStandard (TimeArray/DataFrame-like)
gen_df = DataFrame(pg)


# normalize column names to Strings for consistent lookup
orig_names = names(gen_df)
for n in orig_names
    if n !== "DateTime"
        newn = String(n)
        if newn != String(n)
            DataFrames.rename!(gen_df, n => newn)
        else
            # ensure it's a String column name
            DataFrames.rename!(gen_df, n => newn)
        end
    end
end

# Build a mapping from generator name -> column in gen_df (keep original key types)
gen_col_map = Dict{Any, Symbol}()
cols = names(gen_df)
for g in keys(gen_to_bus)
    gstr = String(g)
    # try exact match on String form
    match = findfirst(c -> String(c) == gstr, cols)
    if match === nothing
        # try contains or startswith
        match = findfirst(c -> occursin(gstr, String(c)) || startswith(String(c), gstr), cols)
    end
    if match === nothing
        @warn "No column found in gen_df matching generator name" gen=String(g)
    else
        col = cols[match]
        # normalize column identifier to Symbol for consistent indexing
        col_sym = try
            convert(Symbol, col)
        catch
            Symbol(string(col))
        end
        gen_col_map[g] = col_sym
    end
end
@info "Generator to column matches" matched = length(gen_col_map) total_gens = length(keys(gen_to_bus))

# Helpers for robust dict and column lookups
function dict_lookup(d::AbstractDict, key)
    if haskey(d, key)
        return d[key]
    end
    ks = string(key)
    if haskey(d, ks)
        return d[ks]
    end
    ks_sym = Symbol(ks)
    if haskey(d, ks_sym)
        return d[ks_sym]
    end
    return nothing
end

function find_lmp_col(lmp::DataFrame, busname::AbstractString)
    cols = names(lmp)
    # try exact symbol and string matches
    sym = Symbol(busname)
    if sym in cols
        return sym
    end
    if busname in cols
        return busname
    end
    # fuzzy match
    for c in cols
        cn = String(c)
        if occursin(busname, cn) || occursin(cn, busname) || startswith(cn, busname) || startswith(busname, cn)
            return c
        end
    end
    return nothing
end

# Updated function uses gen_col_map to read dispatch values and flexible lookups
function find_hourly_marginal_gens(
    gen_df::DataFrame,
    lmp::DataFrame,
    gen_col_map::AbstractDict,
    gen_to_bus::AbstractDict,
    gen_cost::AbstractDict,
    pmin::Vector{Float64},
    pmax::Vector{Float64};
    eps_price=0.1
)
    @assert gen_df.DateTime == lmp.DateTime "Time stamps differ between gen and LMP data"

    # --- Build generator limit dictionary (consistent with gen_to_bus order) ---
    gen_list = collect(keys(gen_to_bus))
    gen_limits = Dict(gen_list[i] => (pmin[i], pmax[i]) for i in 1:length(gen_list))

    marginals = Dict{DateTime, Vector{String}}()

    # --- Optional scaling check between gen_cost and LMPs ---
    mean_cost = mean(abs.(collect(values(gen_cost))))
    mean_lmp = mean(skipmissing(vcat(eachcol(lmp[:, Not(:DateTime)])...)))
    if mean_cost < 0.01 * mean_lmp
        @warn "Detected scale mismatch between gen_cost and LMP (multiplying gen_cost by 1000)"
        gen_cost = Dict(k => v * 1000 for (k, v) in gen_cost)
    end

    # --- Loop over time steps ---
    for r in 1:nrow(gen_df)
        t = gen_df.DateTime[r]
        mg = String[]

        for (gen_key, col) in gen_col_map
            val = gen_df[r, col]
            if val === missing || (isa(val, Real) && isnan(val))
                continue
            end

            bus = dict_lookup(gen_to_bus, gen_key)
            if bus === nothing
                continue
            end

            lmp_col = find_lmp_col(lmp, string(bus))
            if lmp_col === nothing
                continue
            end

            lmp_val = lmp[r, lmp_col]
            if lmp_val === missing || (isa(lmp_val, Real) && isnan(lmp_val))
                continue
            end

            cost = dict_lookup(gen_cost, gen_key)
            if cost === nothing
                continue
            end
            mc = float(cost)

            lims = dict_lookup(gen_limits, gen_key)
            if lims === nothing
                continue
            end
            (pmin_g, pmax_g) = lims

            # --- Core marginality condition ---
            # 1. Generator output is inside its feasible range (not at limits)
            # 2. LMP is close to or above its marginal cost (within tolerance)
            if val > pmin_g + 1e-3 && val < pmax_g - 1e-3 && float(lmp_val) >= mc - eps_price
                push!(mg, string(gen_key))
            end
        end

        marginals[t] = mg
    end

    return marginals
end
# Call the updated function
marginal_gens = find_hourly_marginal_gens(gen_df, lmp, gen_col_map, gen_to_bus, gen_cost,pmin,pmax, eps_price=0.1)
@info "Computed hourly marginal generators" hours=length(keys(marginal_gens)) matched_gens=length(gen_col_map)

# Write marginals to CSV: DateTime, Marginals (semicolon-separated)
out = DataFrame(DateTime = collect(keys(marginal_gens)), Marginals = [join(marginal_gens[t], ";") for t in collect(keys(marginal_gens))])
CSV.write(joinpath(results.path, "hourly_marginal_gens.csv"), out)
@info "Wrote hourly_marginal_gens.csv" rows=nrow(out)

