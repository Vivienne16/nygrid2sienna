function find_strict_marginal_by_bus_branch(
    gen_df::DataFrame,
    lmp::DataFrame,
    gen_col_map::AbstractDict,
    gen_to_bus::AbstractDict,
    gen_cost::AbstractDict,
    pmin::Vector{Float64},
    pmax::Vector{Float64},
    branch_flow::DataFrame,          # columns: :BranchID, :Flow, :Limit
    PTDF::AbstractMatrix;            # rows=branches, cols=buses
    eps_price=0.1,
    flow_tol=1e-3
)
    @assert gen_df.DateTime == lmp.DateTime "Time stamps differ between gen and LMP data"

    # --- Generator limits dict ---
    gen_list = collect(keys(gen_to_bus))
    gen_limits = Dict(gen_list[i] => (pmin[i], pmax[i]) for i in 1:length(gen_list))

    # --- Bus → generators mapping ---
    bus_to_gens = Dict{String, Vector{Any}}()
    for (gen, bus) in gen_to_bus
        bus_to_gens[string(bus)] = get(bus_to_gens, string(bus), String[])
        push!(bus_to_gens[string(bus)], gen)
    end

    # --- Branch → index mapping for PTDF ---
    branch_list = branch_flow.BranchID
    branch_idx_map = Dict(branch_list[i] => i for i in 1:length(branch_list))

    # --- Prepare result dict ---
    marginals = Dict{DateTime, Dict{String, Vector{String}}}()

    # --- Loop over time ---
    for r in 1:nrow(gen_df)
        t = gen_df.DateTime[r]
        marginals[t] = Dict{String, Vector{String}}()

        # --- Identify congested branches at this time ---
        congested_branches = Dict{Int, Float64}()
        for (i, row) in enumerate(eachrow(branch_flow))
            flow_val = row.Flow[r]
            limit_val = row.Limit
            if abs(flow_val) >= limit_val - flow_tol
                congested_branches[i] = flow_val
            end
        end

        # --- Loop over buses ---
        for (bus_idx, bus) in enumerate(keys(bus_to_gens))
            lmp_col = find_lmp_col(lmp, bus)
            if lmp_col === nothing
                continue
            end
            lmp_val = lmp[r, lmp_col]
            if lmp_val === missing || (isa(lmp_val, Real) && isnan(lmp_val))
                continue
            end

            gens_at_bus = bus_to_gens[bus]
            marginal_candidates = String[]

            for gen in gens_at_bus
                col = get(gen_col_map, gen, nothing)
                if col === nothing
                    continue
                end
                pg = gen_df[r, col]
                if pg === missing || (isa(pg, Real) && isnan(pg))
                    continue
                end
                (pmin_g, pmax_g) = dict_lookup(gen_limits, gen)
                cost = dict_lookup(gen_cost, gen)
                mc = float(cost)

                # Generator must be inside limits and cost ≤ LMP
                if !(pg >= pmin_g && pg <= pmax_g  && mc <= lmp_val + eps_price)
                    continue
                end

                # Check if this generator can relieve any congested branch
                gen_idx = findfirst(x -> x == gen, gen_list)
                affects_congestion = false
                for (bidx, _) in congested_branches
                    sens = PTDF[bidx, bus_idx]   # bus injection → branch flow
                    if sens * (pmax_g - pg) > flow_tol || sens * (pg - pmin_g) > flow_tol
                        affects_congestion = true
                        break
                    end
                end

                if affects_congestion || isempty(congested_branches)
                    push!(marginal_candidates, gen)
                end
            end

            marginals[t][bus] = marginal_candidates
        end
    end

    return marginals
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

branch_order_ptdf = PTDF_matrix.axes[2]
branch_order_flow = branch_flow.BranchID


# Reorder branch_flow rows to match PTDF
branch_flow_aligned = branch_flow[[findfirst(==(b), branch_flow.BranchID) for b in branch_order_ptdf], :]

# Sanity check
all(branch_flow_aligned.BranchID .== branch_order_ptdf)  # should return true

lines = get_components(Line,sys)
txs = get_components(Transformer2W,sys)

strict_marginals = find_strict_marginal_by_bus_branch(
    gen_df,
    lmp,
    gen_col_map,
    gen_to_bus,
    gen_cost,
    pmin,
    pmax,
    branch_flow_aligned,
    PTDF_matrix;
    eps_price=0.1,
    flow_tol=1e-3
)