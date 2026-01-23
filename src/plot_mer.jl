using CSV
using DataFrames
using Plots
using StatsPlots
using Dates
using Statistics

# Load the combined MER results
println("Loading combined MER results...")
mer_file = "merged_hourly_mer_results/all_hours_mer_combined_by_timestep.csv"
df = CSV.read(mer_file, DataFrame)

println("Data loaded: $(nrow(df)) timesteps")
println("Date range: $(minimum(df.DateTime)) to $(maximum(df.DateTime))")

# Create the plot
println("Creating plot...")
p = plot(
    df.DateTime,
    df.mer_kg_co2_per_mwh,
    label="MER (kg CO₂/MWh)",
    xlabel="Time",
    ylabel="MER (kg CO₂/MWh)",
    title="Marginal Emission Rate - All Hours Combined",
    legend=:topright,
    linewidth=1.5,
    size=(1200, 600),
    dpi=300
)

# Add summary statistics as text
mean_mer = mean(filter(x -> abs(x) > 1e-6, df.mer_kg_co2_per_mwh))
median_mer = median(filter(x -> abs(x) > 1e-6, df.mer_kg_co2_per_mwh))
annotate!(
    minimum(df.DateTime) + (maximum(df.DateTime) - minimum(df.DateTime)) * 0.02,
    maximum(df.mer_kg_co2_per_mwh) * 0.95,
    text("Mean: $(round(mean_mer, digits=2)) kg CO₂/MWh\nMedian: $(round(median_mer, digits=2)) kg CO₂/MWh", 
         :left, 10, :black)
)

# Save the plot
output_file = "merged_hourly_mer_results/mer_combined_timeseries.png"
savefig(p, output_file)
println("Plot saved to: $output_file")

# Create a second plot showing hourly patterns
println("Creating hourly pattern plot...")
df.hour = Dates.hour.(df.DateTime)

# Calculate mean MER by hour
hourly_stats = combine(groupby(df, :hour)) do group
    non_zero = filter(x -> abs(x) > 1e-6, group.mer_kg_co2_per_mwh)
    DataFrame(
        mean_mer = isempty(non_zero) ? 0.0 : mean(non_zero),
        median_mer = isempty(non_zero) ? 0.0 : median(non_zero),
        std_mer = isempty(non_zero) ? 0.0 : std(non_zero),
        count = length(non_zero)
    )
end

sort!(hourly_stats, :hour)

p2 = plot(
    hourly_stats.hour,
    hourly_stats.median_mer,
    label="Median MER",
    xlabel="Hour of Day",
    ylabel="MER (kg CO₂/MWh)",
    title="Median Marginal Emission Rate by Hour of Day",
    legend=:topright,
    linewidth=2,
    marker=:circle,
    markersize=4,
    size=(1000, 600),
    dpi=300,
    xticks=0:23
)

# Add mean as comparison
plot!(
    hourly_stats.hour,
    hourly_stats.mean_mer,
    label="Mean MER",
    linewidth=2,
    marker=:square,
    markersize=4,
    linestyle=:dash
)

output_file2 = "merged_hourly_mer_results/mer_hourly_pattern.png"
savefig(p2, output_file2)
println("Hourly pattern plot saved to: $output_file2")

# Create a box plot by hour
println("Creating box plot by hour...")
p3 = boxplot(
    string.(df.hour),
    df.mer_kg_co2_per_mwh,
    xlabel="Hour of Day",
    ylabel="MER (kg CO₂/MWh)",
    title="MER Distribution by Hour of Day",
    legend=false,
    size=(1200, 600),
    dpi=300,
    xticks=(1:24, string.(0:23))
)

output_file3 = "merged_hourly_mer_results/mer_hourly_boxplot.png"
savefig(p3, output_file3)
println("Box plot saved to: $output_file3")

println("\nPlotting complete!")
println("Summary statistics:")
println("  Mean MER: $(round(mean_mer, digits=3)) kg CO₂/MWh")
println("  Median MER: $(round(median_mer, digits=3)) kg CO₂/MWh")
println("  Min MER: $(round(minimum(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")
println("  Max MER: $(round(maximum(df.mer_kg_co2_per_mwh), digits=3)) kg CO₂/MWh")
