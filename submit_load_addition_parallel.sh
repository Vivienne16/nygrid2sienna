#!/bin/bash
#SBATCH --job-name=load_add_hour_%a
#SBATCH --output=logs/load_addition_hour_%a_%j.out
#SBATCH --error=logs/load_addition_hour_%a_%j.err
#SBATCH --array=0-23
#SBATCH --time=48:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --exclusive

# Create logs directory if it doesn't exist
mkdir -p logs

# Get the hour from the array task ID
HOUR=$SLURM_ARRAY_TASK_ID

# Print job information
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Array Task ID: $SLURM_ARRAY_TASK_ID"
echo "Processing Hour: $HOUR"
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

# Run the Julia script with the hour as argument
julia --project=. src/setup_hourly_simulation_load_addition.jl $HOUR

# Print completion information
echo "=========================================="
echo "Completed at: $(date)"
echo "=========================================="
