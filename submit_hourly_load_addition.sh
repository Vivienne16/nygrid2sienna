#!/bin/bash

# Submit 10 separate jobs to partition 8760 hours into 10 chunks
# Each job processes 876 hours (876 * 10 = 8760)

# Create logs directory if it doesn't exist
mkdir -p logs

# Define hours per job
HOURS_PER_JOB=876
TOTAL_HOURS=8760

# Loop through and submit 10 jobs
for i in {1..10}; do
    START_HOUR=$(( (i-1) * HOURS_PER_JOB + 1 ))
    END_HOUR=$(( i * HOURS_PER_JOB ))
    
    # Adjust last job to include any remaining hours
    if [ $i -eq 10 ]; then
        END_HOUR=$TOTAL_HOURS
    fi
    
    JOB_NAME="mer_${START_HOUR}-${END_HOUR}"
    
    echo "Submitting job $i: Hours $START_HOUR to $END_HOUR"
    
    sbatch <<EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --output=logs/hourly_load_addition_${START_HOUR}-${END_HOUR}_%j.out
#SBATCH --error=logs/hourly_load_addition_${START_HOUR}-${END_HOUR}_%j.err
#SBATCH --time=168:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G

# Print job information
echo "=========================================="
echo "Job ID: \$SLURM_JOB_ID"
echo "Job Name: ${JOB_NAME}"
echo "Node: \$HOSTNAME"
echo "Hour Range: $START_HOUR to $END_HOUR"
echo "Started at: \$(date)"
echo "=========================================="

# Load required modules
module load gurobi
export PATH="/home/fs02/pmr82_0001/ml2589/julia-1.11.5/bin:\$PATH"

# Set Julia depot to avoid permission issues
export JULIA_DEPOT_PATH="\$HOME/.julia_local:\$HOME/.julia"

# Change to the project directory
cd /home/fs02/pmr82_0001/ml2589/nygrid2sienna

# Run the Julia script with hour range
julia --project=. src/setup_hourly_simulation_load_addition.jl $START_HOUR $END_HOUR

# Print completion information
echo "=========================================="
echo "Completed at: \$(date)"
echo "Exit code: \$?"
echo "=========================================="
EOF

    sleep 1  # Brief pause between submissions
done

echo "All 10 jobs submitted successfully!"
