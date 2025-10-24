using CSV
using DataFrames
using Logging



# set config dir
config_dir = normpath(joinpath(@__DIR__, "..", "config"))

# Compare thermal_config PTIDs with 2025 existing generator PTIDs
existing_path = normpath("/Users/vivienneliu/GitHub/nygrid2sienna/Data/2025NYCA_existinggen.csv")
existing_df = CSV.read(existing_path, DataFrame; normalizenames=true)
exclude_type = ["LBW","OSW","SUN","WAT","UR"]

# Filter out rows in exclude_type for existing_df
vals = uppercase.(string.(existing_df[!, "FuelType"]))
keep_mask = [ !(v in exclude_type) for v in vals ]
existing_df = existing_df[keep_mask, :]


thermal_path = joinpath(config_dir, "thermal_config.csv")
thermal_df = CSV.read(thermal_path, DataFrame; normalizenames=true)

existing_ptid = existing_df[!, "PTID"]
thermal_ptid = thermal_df[!, "PTID"]
# Compute PTIDs present in thermal_config but missing in existing 2025 list
missing_ptids = setdiff(thermal_ptids, existing_ptids)

# Ensure both thermal_ptid and missing_ptids are of the same type for comparison
thermal_ptid = string.(thermal_ptid)
missing_ptids = string.(missing_ptids)

# Create a retire_mask to indicate which PTIDs are in missing_ptids and also in thermal_ptid
retire_mask = [(ptid in missing_ptids) for ptid in thermal_ptid]

# Add a new column to thermal_df to indicate if the PTID is in missing_ptids

missing_rows = thermal_df[retire_mask, :]

# Save the missing rows to a CSV file
CSV.write(joinpath(config_dir, "missing_thermal_rows.csv"), missing_rows)
@info "Wrote missing_thermal_rows.csv" rows=nrow(missing_rows)

# Save the rows not in missing_ptids to another CSV file
remaining_rows = thermal_df[.!retire_mask, :]
CSV.write(joinpath(config_dir, "remaining_thermal_rows.csv"), remaining_rows)
@info "Wrote remaining_thermal_rows.csv" rows=nrow(remaining_rows)



