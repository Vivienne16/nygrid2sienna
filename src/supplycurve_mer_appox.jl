using CSV
using DataFrames
using Dates
using TimeSeries
using PowerSimulations 
using StorageSystemsSimulations
using HydroPowerSimulations
const PSI = PowerSimulations


function find_gen_for_zone(thermal_config::DataFrame, bus_config::DataFrame, zone::String)
    # Find generators in thermal_config whose BusId is in bus_config for the given zone
    zone_bus_ids = bus_config[bus_config.zone .== zone, :busIdx]
    # Filter thermal_config for these BusIds
    gen_mask = in.(thermal_config.BusId, Ref(zone_bus_ids))
    return thermal_config[gen_mask, :]
end

results_dir = "/Users/vivienneliu/GitHub/nygrid2sienna/TestRun/clcpa2030test-5"
results = SimulationResults(results_dir);
results_uc = get_decision_problem_results(results, "UC");
variables = PSI.read_realized_variables(results_uc)
duals = PSI.read_realized_duals(results_uc)
expressions = PSI.read_realized_expressions(results_uc)
parameters = PSI.read_realized_parameters(results_uc)
sys = System("/Users/vivienneliu/GitHub/nygrid2sienna/TestRun/clcpa2030test-5/problems/UC/system-78486ea1-8459-437b-b7ff-4220c58d71a7.json")
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

tx_flow = variables["FlowActivePowerVariable__Transformer2W"]
line_flow = variables["FlowActivePowerVariable__Line"]

branch_flow = DataFrame(DateTime = line_flow.DateTime)

# Extract branch names from line and transformer flows
line_branches = names(line_flow, Not(:DateTime))
tx_branches   = names(tx_flow, Not(:DateTime))


# Append line flows
for b in line_branches
    branch_flow[!, b] = line_flow[!, b]
end

# Append transformer flows
for b in tx_branches
    branch_flow[!, b] = tx_flow[!, b]
end
line_limits = Dict()
for l in line_branches
    line = get_component(Line,sys,l)
    limit = get_rating(line) *100
    line_limits[l] = limit
end
tx_limits = Dict()
for t in tx_branches
    tx = get_component(Transformer2W,sys,t)
    limit = get_rating(tx) *100
    tx_limits[t] = limit
end
branch_limits = merge(line_limits,tx_limits)

all_flows = hcat(line_flow[:, Not(:DateTime)], tx_flow[:, Not(:DateTime)])
branch_ids = names(all_flows)

branch_flow = DataFrame(
    BranchID = String[], 
    Limit = Float64[], 
    Flow = Vector{Vector{Float64}}()
)


for b in branch_ids
    push!(branch_flow, (
        BranchID = String(b),
        Limit = branch_limits[String(b)],
        Flow = collect(all_flows[!, b])  # vector of flows over all times
    ))
end





price_ts = lmp
flow_ts = hcat(line_flow, tx_flow[:, Not(:DateTime)])
re_av_ts = parameters["ActivePowerTimeSeriesParameter__RenewableDispatch"]
hydro_av_ts = parameters["ActivePowerTimeSeriesParameter__HydroDispatch"]
thermal_ts = variables["ActivePowerVariable__ThermalStandard"]
hydro_gen_ts = variables["ActivePowerVariable__HydroDispatch"]
re_gen_ts = variables["ActivePowerVariable__RenewableDispatch"]
charge_ts = variables["ActivePowerInVariable__EnergyReservoirStorage"]
discharge_ts = variables["ActivePowerOutVariable__EnergyReservoirStorage"]
stor_energy_ts = variables["EnergyVariable__EnergyReservoirStorage"]


remain_re_ts = DataFrame(DateTime = re_av_ts[:, "DateTime"])
for col in names(re_av_ts)
    if col != "DateTime" && col in names(re_row)
        remain_re_ts[!, col] = re_av_ts[!, col] .- re_row[!, col]
    end
end

remain_hydro_ts = DataFrame(DateTime = hydro_av_ts[:, "DateTime"])
for col in names(hydro_av_ts)
    if col != "DateTime" && col in names(hydro_row)
        remain_hydro_ts[!, col] = hydro_av_ts[!, col] .- hydro_row[!, col]
    end
end
    
line_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/branch_config_2040.csv", DataFrame)
bus_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/bus_config.csv", DataFrame)
thermal_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/thermal_config.csv", DataFrame)
hydro_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/hydro_config.csv", DataFrame)
nuclear_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/nuclear_config.csv", DataFrame)
storage_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/storage_config_2030.csv", DataFrame)
upv_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/upv_config_2030.csv", DataFrame)
dpv_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/dpv_config_2030.csv", DataFrame)
wind_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/wind_config_2030.csv", DataFrame)

# Vertically concatenate upv_config, dpv_config, and wind_config
re_config = vcat(upv_config, dpv_config, wind_config)

zone_list = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K"]
t_range = thermal_ts[:, "DateTime"]

# Initialize the output table once: zones as columns, timestamps as rows
best_gen_hr_df = DataFrame(DateTime = t_range)
for z in zone_list
    best_gen_hr_df[!, z] = Vector{Union{Missing, Float64}}(missing, length(t_range))
end

# Initialize a table to store storage availability flags per zone/time
storage_avail_df = DataFrame(DateTime = t_range)
for z in zone_list
    storage_avail_df[!, z] = Vector{Union{Missing, Bool}}(missing, length(t_range))
end

# Initialize a table to store available hydro + renewable per zone/time
avail_re_hydro_df = DataFrame(DateTime = t_range)
for z in zone_list
    avail_re_hydro_df[!, z] = Vector{Union{Missing, Float64}}(missing, length(t_range))
end

results = []
for t in t_range
    price_row = price_ts[price_ts[:, "DateTime"] .== t, :]
    thermal_row = thermal_ts[thermal_ts[:, "DateTime"] .== t, :]
    hydro_row = hydro_gen_ts[hydro_gen_ts[:, "DateTime"] .== t, :]
    hydro_avail_row = hydro_av_ts[hydro_av_ts[:, "DateTime"] .== t, :]
    re_row = re_gen_ts[re_gen_ts[:, "DateTime"] .== t, :]
    re_avail_row = re_av_ts[re_av_ts[:, "DateTime"] .== t, :]
    charge_row = charge_ts[charge_ts[:, "DateTime"] .== t, :]
    discharge_row = discharge_ts[discharge_ts[:, "DateTime"] .== t, :]
    net_discharge_row = discharge_row .- charge_row

    for zone in zone_list
        zone_buses = bus_config[bus_config.zone .== zone, :]
        # price_zone = mean([price_row[1, String(bus.name)] for bus in eachrow(zone_buses) if String(bus.Name) in names(price_row)])
        
    # Add logic to process or store these rows as needed
    # Check the column names in re_avail_row against re_config to get BusId and determine if it is in the zone
        zone_re_remain = []
        for col in names(re_avail_row)
            if col != "DateTime" && col in re_config.name
                bus_id = re_config[re_config.name .== col, :BusId][1]
                bus_zone = bus_config[bus_config.busIdx .== bus_id, :zone][1]
                if bus_zone == zone
                    push!(zone_re_remain, col)
                end
            end
        end
        if isempty(zone_re_remain)
            remain_re_zone = 0.0
        else
            vals = [remain_re_ts[1, col] for col in zone_re_remain]
            remain_re_zone = sum(x -> x === missing ? 0.0 : Float64(x), vals)
        end
        
        
        # Check the column names in hydro_row against hydro_config to get BusId and determine if it is in the zone
        zone_hydro_remain = []
        for col in names(hydro_avail_row)
            if col != "DateTime" && col in hydro_config.Name
                bus_id = hydro_config[hydro_config.Name .== col, :BusId][1]
                bus_zone = bus_config[bus_config.busIdx .== bus_id, :zone][1]
                if bus_zone == zone
                    push!(zone_hydro_remain, col)
                end
            end
        end
        if isempty(zone_hydro_remain)
            remain_hydro_zone = 0.0
        else
            vals = [remain_hydro_ts[1, col] for col in zone_hydro_remain]
            remain_hydro_zone = sum(x -> x === missing ? 0.0 : Float64(x), vals)
        end





        # Get thermal generators for this zone
        thermal_zone = find_gen_for_zone(thermal_config, bus_config, zone)
        # nuclear_zone = find_gen_for_zone(nuclear_config, bus_config, zone)
        # all_zone_gens = vcat(thermal_zone, nuclear_zone)
        # Get generation, Pmin, and Pmax for each generator in the zone
        thermal_gen_zone = []
        pmin_zone = []
        pmax_zone = []
        heat_rate = []
        for gen in eachrow(thermal_zone)
            gen_name = String(gen.Name)
            if gen_name in names(thermal_row)
                push!(thermal_gen_zone, thermal_row[1, gen_name])
                push!(pmin_zone, gen.Pmin)
                push!(pmax_zone, gen.Pmax)
                push!(heat_rate, gen.HeatRateLM_1)
            end
        end

        # Find generator with output > 0 and remaining capacity, with smallest heatrate
        gen_candidates = [(i, thermal_gen_zone[i], pmax_zone[i], heat_rate[i]) for i in 1:length(thermal_gen_zone) if thermal_gen_zone[i] > 0 && pmax_zone[i] - thermal_gen_zone[i] > 0]
        if !isempty(gen_candidates)
            # Get index of generator with smallest heatrate
            min_idx = argmin([c[4] for c in gen_candidates])
            best_gen_idx = gen_candidates[min_idx][1]
        else
            # If none, get generator with 0 output and smallest heatrate
            zero_candidates = [(i, heat_rate[i]) for i in 1:length(thermal_gen_zone) if thermal_gen_zone[i] == 0]
            if !isempty(zero_candidates)
                min_idx = argmin([c[2] for c in zero_candidates])
                best_gen_idx = zero_candidates[min_idx][1]
            else
                best_gen_idx = nothing
            end
        end
        # If found, get generator info
        if best_gen_idx !== nothing
            best_gen_output = thermal_gen_zone[best_gen_idx]
            best_gen_pmax = pmax_zone[best_gen_idx]
            best_gen_heatrate = heat_rate[best_gen_idx]
            best_gen_name = String(thermal_zone[best_gen_idx, :Name])
        end

        # Record best heat rate for this zone and timestamp
        zone_sym = Symbol(zone)
        row_idx = findfirst(==(t), best_gen_hr_df.DateTime)
        if row_idx !== nothing
            if best_gen_idx !== nothing
                best_gen_hr_df[row_idx, zone_sym] = best_gen_heatrate
            else
                best_gen_hr_df[row_idx, zone_sym] = missing
            end
        end
        
        # Storage availability: find storage at buses in this zone and check net discharge
        zone_storage = storage_config[in.(storage_config.BusId, Ref(zone_buses.busIdx)), :]
        # net_discharge_row is discharge_row - charge_row, both DataFrames aligned on DateTime
        # For each storage unit in the zone, check if net discharge < power rating and stored energy > 1
        flag_available = false
        for s in eachrow(zone_storage)
            col_name = String(s.name)
            power_rating = s.PowerCap  # assuming column is `rating` for kW/MW
            energy_col = Symbol(col_name)  # EnergyVariable__EnergyReservoirStorage column uses the same name
            # Safeguard: ensure columns exist
            has_power = col_name in names(net_discharge_row)
            has_energy = col_name in names(stor_energy_ts)
            if has_power && has_energy
                net_p = net_discharge_row[1, col_name]
                stored_e = stor_energy_ts[stor_energy_ts[:, "DateTime"] .== t, energy_col][1]
                if net_p < power_rating && stored_e > 1
                    flag_available = true
                    break
                end
            end
        end
        # Record flag
        row_idx = findfirst(==(t), storage_avail_df.DateTime)
        if row_idx !== nothing
            storage_avail_df[row_idx, Symbol(zone)] = flag_available
        end
        
        # Record available hydro + renewable for this zone and timestamp
        row_idx = findfirst(==(t), avail_re_hydro_df.DateTime)
        if row_idx !== nothing
            avail_re_hydro_df[row_idx, Symbol(zone)] = (remain_re_zone + remain_hydro_zone)
        end
    end
end


iflow_ts = expressions["InterfaceTotalFlow__TransmissionInterface"]
if_config = CSV.read("/Users/vivienneliu/GitHub/nygrid2sienna/config/interfaceflow_limits_2030.csv", DataFrame)

# Remove rows where both interface1 and interface2 are missing
keep_mask = .!(ismissing.(if_config.interface1) .& ismissing.(if_config.interface2))
if_config = if_config[keep_mask, :][1:11, :]

# Helper to split zone pair like "A-B" into (from, to)
split_zone_pair(s) = ismissing(s) ? (missing, missing) : begin
    parts = split(String(s), "-")
    if length(parts) == 2
        (strip(parts[1]), strip(parts[2]))
    else
        (missing, missing)
    end
end

# Parse interface1 into from1/to1, interface2 into from2/to2
n = nrow(if_config)
from1_col = Vector{Union{Missing,String}}(undef, n)
to1_col   = Vector{Union{Missing,String}}(undef, n)
from2_col = Vector{Union{Missing,String}}(undef, n)
to2_col   = Vector{Union{Missing,String}}(undef, n)
for i in 1:n
    f1, t1 = split_zone_pair(if_config[i, :interface1])
    from1_col[i] = f1; to1_col[i] = t1
    f2, t2 = split_zone_pair(if_config[i, :interface2])
    from2_col[i] = f2; to2_col[i] = t2
end
if_config[!, :from1] = from1_col
if_config[!, :to1]   = to1_col
if_config[!, :from2] = from2_col
if_config[!, :to2]   = to2_col

function get_connected_zones(if_config::DataFrame, zone::AbstractString)
    # Return unique list of zones connected to `zone` using from1/to1 and from2/to2
    required_cols = ["from1", "to1", "from2", "to2"]
    connected = Set{String}()
    for i in 1:nrow(if_config)
        f1 = if_config[i, :from1]; t1 = if_config[i, :to1]
        f2 = if_config[i, :from2]; t2 = if_config[i, :to2]
        if !ismissing(f1) && !ismissing(t1)
            if String(f1) == zone
                push!(connected, String(t1))
            elseif String(t1) == zone
                push!(connected, String(f1))
            end
        end
        if !ismissing(f2) && !ismissing(t2)
            if String(f2) == zone
                push!(connected, String(t2))
            elseif String(t2) == zone
                push!(connected, String(f2))
            end
        end
    end
    return sort!(collect(connected))
end

# Helper to robustly find the interface flow column in iflow_ts given an interface name
canon_name(x) = lowercase(replace(string(x), r"[^A-Za-z0-9]+" => ""))
function lookup_iflow_col(iflow_ts::DataFrame, int_name::AbstractString)
    target = canon_name(int_name)
    # 1) exact match by Symbol
    sym = Symbol(int_name)
    if sym in names(iflow_ts)
        return sym
    end
    # 2) exact match by String
    if int_name in names(iflow_ts)
        return int_name
    end
    # 3) canonical string match (ignoring non-alphanumerics and case)
    for n in names(iflow_ts)
        if canon_name(n) == target || occursin(target, canon_name(n)) || occursin(canon_name(n), target)
            return n
        end
    end
    return nothing
end

function find_flows_for_zone(if_config::DataFrame, iflow_ts::DataFrame, zone::AbstractString, t)
    # Return a DataFrame with one row per connected region at time t.
    # Orientation is the interface raw direction: from1 -> to1
    # Columns: Neighbor, MaxCap, MinCap, Flow, TxAvail, Direction
    row_idx = findfirst(==(t), iflow_ts[:, :DateTime])
    if row_idx === nothing
        return DataFrame(Neighbor=String[], MaxCap=Float64[], MinCap=Float64[], Flow=Float64[], TxAvail=Float64[], Direction=Int[])
    end

    max_cap = Dict{String,Float64}()
    min_cap = Dict{String,Float64}()
    flows_raw = Dict{String,Float64}()   # raw from iflow_ts (from1->to1 positive)

    for i in 1:nrow(if_config)
        int_name = String(if_config[i, :name])
        # rating_lb is to->from capacity, rating_ub is from->to capacity
        rating_lb = Float64(if_config[i, :rating_lb])
        rating_ub = Float64(if_config[i, :rating_ub])
        f1 = if_config[i, :from1]; t1 = if_config[i, :to1]

        # Ignore second pair entirely and skip if not touching zone
        if ismissing(f1) || ismissing(t1)
            continue
        end
        if !(String(f1) == zone || String(t1) == zone)
            continue
        end

        # Neighbor zone label for this row
        neighbor = String(t1) == zone ? String(f1) : String(t1)

        # Raw flow value for this interface at time t (from1->to1 positive in iflow_ts)
        col = lookup_iflow_col(iflow_ts, int_name)
        col === nothing && continue
        raw_val = iflow_ts[row_idx, col]
        raw_flow = raw_val === missing ? 0.0 : Float64(raw_val)

        # Accumulate per neighbor in raw orientation
        flows_raw[neighbor] = get(flows_raw, neighbor, 0.0) + raw_flow
        max_cap[neighbor] = get(max_cap, neighbor, 0.0) + rating_ub   # from->to
        min_cap[neighbor] = get(min_cap, neighbor, 0.0) - rating_lb   # to->from (negative bound)
    end

    # Build result table
    neighbors = sort!(collect(union(keys(max_cap), union(keys(min_cap), keys(flows_raw)))))
    df = DataFrame(Neighbor=String[], MaxCap=Float64[], MinCap=Float64[], Flow=Float64[], TxAvail=Float64[], Direction=Int[])
    for nb in neighbors
        f = get(flows_raw, nb, 0.0)
        maxc = get(max_cap, nb, 0.0)
        minc = get(min_cap, nb, 0.0)
        if f >= 0
            dir = 1  # along from1->to1
            tx_av = maxc - f
        else
            dir = -1 # opposite to from1->to1
            tx_av = -(minc - f)
        end
        push!(df, (Neighbor=nb, MaxCap=maxc, MinCap=minc, Flow=f, TxAvail=tx_av, Direction=dir))
    end
    return df
end

# Adjust flow direction so positive means import into `region`
function fix_direction(row::DataFrameRow, region::AbstractString, flow_col::Union{Symbol,String})
    col = Symbol(flow_col)
    from_n = haskey(row, :from_node) ? row[:from_node] : missing
    to_n   = haskey(row, :to_node)   ? row[:to_node]   : missing
    v = row[col]
    flow_val = v === missing ? missing : Float64(v)
    if !ismissing(from_n) && from_n == region
        return flow_val === missing ? missing : -flow_val
    elseif !ismissing(to_n) && to_n == region
        return flow_val
    else
        return missing
    end
end

function fix_direction(from_node::AbstractString, to_node::AbstractString, region::AbstractString, flow::Real)
    if from_node == region
        return -Float64(flow)
    elseif to_node == region
        return Float64(flow)
    else
        return missing
    end
end

find_flows_for_zone(if_config, iflow_ts, "E", t)