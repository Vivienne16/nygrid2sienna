using CSV
using DataFrames

# Load the combined MER results
println("Loading combined MER results...")
mer_file = "merged_hourly_mer_results/all_hours_mer_combined_by_timestep.csv"
df = CSV.read(mer_file, DataFrame)

println("Total timesteps: $(nrow(df))")

# Count values with absolute value > 1
count_above_1 = sum(abs.(df.mer_kg_co2_per_mwh) .> 1.0)
count_below_or_equal_1 = sum(abs.(df.mer_kg_co2_per_mwh) .<= 1.0)

println("\nMER Analysis:")
println("  |MER| > 1 kg CO₂/MWh: $count_above_1 ($(round(100*count_above_1/nrow(df), digits=2))%)")
println("  |MER| ≤ 1 kg CO₂/MWh: $count_below_or_equal_1 ($(round(100*count_below_or_equal_1/nrow(df), digits=2))%)")

# Additional statistics
println("\nAdditional Statistics:")
println("  Min MER: $(round(minimum(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")
println("  Max MER: $(round(maximum(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")
println("  Mean MER: $(round(mean(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")
println("  Median MER: $(round(median(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")

# Count zero or near-zero values
count_near_zero = sum(abs.(df.mer_kg_co2_per_mwh) .< 1e-6)
println("  Near-zero (|MER| < 1e-6): $count_near_zero ($(round(100*count_near_zero/nrow(df), digits=2))%)")
