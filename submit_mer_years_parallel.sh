#!/bin/bash
#SBATCH --job-name=mer_year_%a
#SBATCH --output=logs/mer_year_%a_%j.out
#SBATCH --error=logs/mer_year_%a_%j.err
#SBATCH --array=0-21
#SBATCH --time=48:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G


# Create logs directory if it doesn't exist
mkdir -p logs

# Map array index to year (0->1998, 1->1999, ..., 21->2019)
YEAR=$((1998 + SLURM_ARRAY_TASK_ID))

# Print job information
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Array Task ID: $SLURM_ARRAY_TASK_ID"
echo "Processing Year: $YEAR"
echo "Node: $HOSTNAME"
echo "Started at: $(date)"
echo "=========================================="

# Load required modules
module load gurobi
# module load julia/1.11.5
export PATH="/home/fs02/pmr82_0001/ml2589/julia-1.11.5/bin:$PATH"

# Set Julia depot to avoid permission issues
export JULIA_DEPOT_PATH="$HOME/.julia_local:$HOME/.julia"

# Change to the project directory
cd /home/fs02/pmr82_0001/ml2589/nygrid2sienna

# Run the Julia script with the year as argument
julia --project=. src/setup_mer_simulation_hourly.jl $YEAR

# Print completion information
echo "=========================================="
echo "Completed at: $(date)"
echo "=========================================="
