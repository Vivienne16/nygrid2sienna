#!/bin/bash

# Script to rerun missing hours from simulation results
# This script reads missing_hours.txt and submits jobs for those hours

# Usage: bash rerun_missing_hours.sh [results_directory]

# Set default results directory
RESULTS_DIR="${1:-BASEHourlySimulations_2005}"

echo "=========================================="
echo "RERUNNING MISSING HOURS"
echo "Results directory: $RESULTS_DIR"
echo "=========================================="

# Check if results directory exists
if [ ! -d "$RESULTS_DIR" ]; then
    echo "Error: Results directory not found: $RESULTS_DIR"
    exit 1
fi

# Check if missing_hours.txt exists
MISSING_HOURS_FILE="$RESULTS_DIR/missing_hours.txt"
if [ ! -f "$MISSING_HOURS_FILE" ]; then
    echo "Error: missing_hours.txt not found in $RESULTS_DIR"
    echo "Please run check_missing_hours.jl first to generate the list"
    exit 1
fi

# Count missing hours
NUM_MISSING=$(wc -l < "$MISSING_HOURS_FILE")
echo "Found $NUM_MISSING missing hours"

if [ $NUM_MISSING -eq 0 ]; then
    echo "No missing hours to rerun!"
    exit 0
fi

# Create logs directory if it doesn't exist
mkdir -p logs

# Read missing hours and submit individual jobs for each
JOB_COUNT=0
while IFS= read -r hour; do
    # Skip empty lines
    if [ -z "$hour" ]; then
        continue
    fi
    
    JOB_NAME="rerun_hour_${hour}"
    
    echo "Submitting job for hour $hour..."
    
    sbatch <<EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --output=logs/rerun_hour_${hour}_%j.out
#SBATCH --error=logs/rerun_hour_${hour}_%j.err
#SBATCH --time=24:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G

# Print job information
echo "=========================================="
echo "Job ID: \$SLURM_JOB_ID"
echo "Job Name: ${JOB_NAME}"
echo "Node: \$HOSTNAME"
echo "Rerunning hour: $hour"
echo "Started at: \$(date)"
echo "=========================================="

# Load required modules
module load gurobi
export PATH="/home/fs02/pmr82_0001/ml2589/julia-1.11.5/bin:\$PATH"

# Set Julia depot to avoid permission issues
export JULIA_DEPOT_PATH="\$HOME/.julia_local:\$HOME/.julia"

# Change to the project directory
cd /home/fs02/pmr82_0001/ml2589/nygrid2sienna

# Run the Julia script for this single hour
julia --project=. src/setup_hourly_simulation_load_addition.jl $hour $hour

# Print completion information
echo "=========================================="
echo "Completed at: \$(date)"
echo "Exit code: \$?"
echo "=========================================="
EOF

    JOB_COUNT=$((JOB_COUNT + 1))
    sleep 0.5  # Brief pause between submissions
    
done < "$MISSING_HOURS_FILE"

echo "=========================================="
echo "Submitted $JOB_COUNT jobs for missing hours"
echo "=========================================="
echo ""
echo "To check job status: squeue --me"
echo "To monitor progress: julia check_missing_hours.jl $RESULTS_DIR"
