using CSV
using DataFrames
using Dates
using TimeSeries

# configuration directory (relative to this script)
config_dir = normpath(joinpath(@__DIR__, "config"))

# Load configuration CSVs into DataFrames
wind_config = CSV.read(joinpath(config_dir, "wind_config.csv"), DataFrame)
upv_config = CSV.read(joinpath(config_dir, "upv_config.csv"), DataFrame)
dpv_config = CSV.read(joinpath(config_dir, "dpv_config.csv"), DataFrame)
storage_config = CSV.read(joinpath(config_dir, "storage_config.csv"), DataFrame)
bus_config = CSV.read(joinpath(config_dir, "bus_config.csv"), DataFrame)

# Quick info about loaded tables
@info "Loaded config files" wind_rows=size(wind_config, 1) upv_rows=size(upv_config, 1) dpv_rows=size(dpv_config, 1) storage_rows=size(storage_config, 1) bus_rows=size(bus_config, 1)

# Append zone information from `bus_config` (busIdx) to other configs (matching on `BusId`)
if !("zone" in names(bus_config))
    @error "bus_config does not contain a :zone column; cannot append zones to other configs"
else
    # prepare small lookup table with BusId -> zone
    bus_zone = select(bus_config, :busIdx, :zone)
    DataFrames.rename!(bus_zone, :busIdx => :BusId)

    # helper to join and report
    function append_zone!(df::DataFrame, df_name::AbstractString)
        if !("BusId" in names(df))
            @warn "$df_name missing :BusId column; skipping zone append"
            return
        end
        if "zone" in names(df)
            @info "$df_name already has :zone column; skipping"
            return
        end
        DataFrames.leftjoin!(df, bus_zone, on = :BusId)
        @info "Appended zone to $df_name" rows=size(df, 1)
    end

    append_zone!(wind_config, "wind_config")
    append_zone!(upv_config, "upv_config")
    append_zone!(dpv_config, "dpv_config")
    append_zone!(storage_config, "storage_config")
end

Re_cap = CSV.read("Data/AdAct_2030_ReCap.csv", DataFrame)

# Convert Re_cap to long form: Tech, zone, cap
cols = filter(n -> n != "Tech", names(Re_cap))
recap_long = DataFrames.stack(Re_cap, cols, variable_name = :zone, value_name = :cap)

# Ensure wind_config has zone and rating columns
if !("zone" in names(wind_config))
    @error "wind_config missing :zone column; run zone-append step first"
end
if !("rating" in names(wind_config))
    @error "wind_config missing :rating column; cannot distribute"
end

# Prepare allocated column
if !("allocated_cap" in names(wind_config))
    wind_config[!, :allocated_cap] = zeros(Float64, nrow(wind_config))
end

# Distribute for Wind_LBW and Wind_OSW
for tech in ("Wind_LBW", "Wind_OSW")
    prefix = tech == "Wind_LBW" ? "LBW_" : "OSW_"
    tech_rows = filter(r -> r.Tech == tech, recap_long)
    for r in eachrow(tech_rows)
        z = r.zone
        cap_zone = float(r.cap)
        # find matching wind_config rows by zone and name prefix
        mask = [ (wind_config.zone[i] == z) && startswith(String(wind_config.name[i]), prefix) for i in 1:nrow(wind_config) ]
        idxs = findall(mask)
        if isempty(idxs)
            @warn "No wind buses matching $prefix in zone $z for $tech; skipping"
            continue
        end
        ratings = Float64.(wind_config.rating[idxs])
        total_rating = sum(ratings)
        if total_rating == 0.0
            @warn "Total rating is zero for $tech in zone $z; skipping allocation"
            continue
        end
        frac = ratings ./ total_rating
        alloc = cap_zone .* frac
        wind_config.allocated_cap[idxs] .+= alloc
        @info "Distributed $(cap_zone) MW for $tech in zone $z to $(length(idxs)) buses"
    end
end

# Quick check: compare per-zone totals
zone_alloc = combine(groupby(wind_config, :zone), :allocated_cap => sum => :zone_alloc_sum)
@info "Wind allocation summary by zone" rows = nrow(zone_alloc)

# Allocate UPV capacity from Re_cap to upv_config (using Tech == "UPV")
if !("zone" in names(upv_config))
    @error "upv_config missing :zone column; run zone-append step first"
end
if !("rating" in names(upv_config))
    @error "upv_config missing :rating column; cannot distribute"
end
if !("allocated_cap" in names(upv_config))
    upv_config[!, :allocated_cap] = zeros(Float64, nrow(upv_config))
end

tech_rows = filter(r -> r.Tech == "UPV", recap_long)
for r in eachrow(tech_rows)
    z = r.zone
    cap_zone = float(r.cap)
    # find matching upv_config rows by zone and name prefix
    mask = [ (upv_config.zone[i] == z) && startswith(String(upv_config.name[i]), "UPV_") for i in 1:nrow(upv_config) ]
    idxs = findall(mask)
    if isempty(idxs)
        @warn "No UPV buses in zone $z for UPV; skipping"
        continue
    end
    ratings = Float64.(upv_config.rating[idxs])
    total_rating = sum(ratings)
    if total_rating == 0.0
        @warn "Total rating is zero for UPV in zone $z; skipping allocation"
        continue
    end
    frac = ratings ./ total_rating
    alloc = cap_zone .* frac
    upv_config.allocated_cap[idxs] .+= alloc
    @info "Distributed $(cap_zone) MW for UPV in zone $z to $(length(idxs)) buses"
end

# Optional summary for UPV
upv_zone_alloc = combine(groupby(upv_config, :zone), :allocated_cap => sum => :zone_alloc_sum)
@info "UPV allocation summary by zone" rows = nrow(upv_zone_alloc)

# Allocate DPV capacity from Re_cap to dpv_config (using Tech == "DPV")
if !("zone" in names(dpv_config))
    @error "dpv_config missing :zone column; run zone-append step first"
end
if !("rating" in names(dpv_config))
    @error "dpv_config missing :rating column; cannot distribute"
end
if !("allocated_cap" in names(dpv_config))
    dpv_config[!, :allocated_cap] = zeros(Float64, nrow(dpv_config))
end

tech_rows = filter(r -> r.Tech == "DPV", recap_long)
for r in eachrow(tech_rows)
    z = r.zone
    cap_zone = float(r.cap)
    # find matching dpv_config rows by zone and name prefix
    mask = [ (dpv_config.zone[i] == z) && startswith(String(dpv_config.name[i]), "DPV_") for i in 1:nrow(dpv_config) ]
    idxs = findall(mask)
    if isempty(idxs)
        @warn "No DPV buses in zone $z for DPV; skipping"
        continue
    end
    ratings = Float64.(dpv_config.rating[idxs])
    total_rating = sum(ratings)
    if total_rating == 0.0
        @warn "Total rating is zero for DPV in zone $z; skipping allocation"
        continue
    end
    frac = ratings ./ total_rating
    alloc = cap_zone .* frac
    dpv_config.allocated_cap[idxs] .+= alloc
    @info "Distributed $(cap_zone) MW for DPV in zone $z to $(length(idxs)) buses"
end

# Optional summary for DPV
dpv_zone_alloc = combine(groupby(dpv_config, :zone), :allocated_cap => sum => :zone_alloc_sum)
@info "DPV allocation summary by zone" rows = nrow(dpv_zone_alloc)

# Allocate Storage capacity from Re_cap to storage_config (using Tech == "Storage")
if !("zone" in names(storage_config))
    @error "storage_config missing :zone column; run zone-append step first"
end
# Determine weight column: prefer :rating, fall back to :PowerCap
weight_col = if "rating" in names(storage_config)
    :rating
elseif "PowerCap" in names(storage_config)
    :PowerCap
else
    nothing
end
if weight_col === nothing
    @error "storage_config lacks both :rating and :PowerCap; cannot determine distribution weights"
end

if !("allocated_cap" in names(storage_config))
    storage_config[!, :allocated_cap] = zeros(Float64, nrow(storage_config))
end

tech_rows = filter(r -> r.Tech == "Storage", recap_long)
for r in eachrow(tech_rows)
    z = r.zone
    cap_zone = float(r.cap)
    # find matching storage_config rows by zone and name prefix
    mask = [ (storage_config.zone[i] == z) && startswith(String(storage_config.name[i]), "Storage_") for i in 1:nrow(storage_config) ]
    idxs = findall(mask)
    if isempty(idxs)
        @warn "No Storage buses in zone $z for Storage; skipping"
        continue
    end
    weights = Float64.(storage_config[!, weight_col][idxs])
    total_weights = sum(weights)
    if total_weights == 0.0
        @warn "Total weights are zero for Storage in zone $z; skipping allocation"
        continue
    end
    frac = weights ./ total_weights
    alloc = cap_zone .* frac
    storage_config.allocated_cap[idxs] .+= alloc
    @info "Distributed $(cap_zone) MW for Storage in zone $z to $(length(idxs)) buses using weight $(String(weight_col))"
end

# Optional summary for Storage
storage_zone_alloc = combine(groupby(storage_config, :zone), :allocated_cap => sum => :zone_alloc_sum)
@info "Storage allocation summary by zone" rows = nrow(storage_zone_alloc)

# Replace original rating columns with the computed allocations
for (df, df_name) in ((wind_config, "wind_config"), (upv_config, "upv_config"), (dpv_config, "dpv_config"), (storage_config, "storage_config"))
    if "allocated_cap" in names(df)
        if "rating" in names(df)
            # remove the original rating column
            select!(df, Not(:rating))
        end
        # rename allocated_cap -> rating
        DataFrames.rename!(df, :allocated_cap => :rating)
        @info "Replaced rating with allocated values for $df_name"
    else
        @warn "$df_name missing :allocated_cap; leaving rating unchanged"
    end
end

# Save updated config files for 2030
try
    CSV.write(joinpath(config_dir, "wind_config_2030.csv"), wind_config)
    @info "Wrote wind_config_2030.csv"
    CSV.write(joinpath(config_dir, "upv_config_2030.csv"), upv_config)
    @info "Wrote upv_config_2030.csv"
    CSV.write(joinpath(config_dir, "dpv_config_2030.csv"), dpv_config)
    @info "Wrote dpv_config_2030.csv"
    CSV.write(joinpath(config_dir, "storage_config_2030.csv"), storage_config)
    @info "Wrote storage_config_2030.csv"
catch e
    @error "Failed to write 2030 config CSVs" exception = e
end
