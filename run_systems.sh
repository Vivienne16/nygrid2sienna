#!/bin/bash
#SBATCH --job-name=nygrid_systems
#SBATCH --time=4:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --output=logs/system_%j.out
#SBATCH --error=logs/system_%j.err

# Adjust paths
JULIA_DIR="/home/fs02/pmr82_0001/ml2589/julia-1.11.5"
PROJECT_DIR="/home/fs02/pmr82_0001/ml2589/nygrid2sienna"
SYSTEM_SCRIPT="src/SystemParsing.jl"
SIM_SCRIPT="src/SystemSimulation.jl"

module load gurobi

export PATH="$JULIA_DIR/bin:$PATH"
cd "$PROJECT_DIR" || exit 1

# Expect LOAD_YEAR to be set by the submission command
if [ -n "$LOAD_YEAR" ]; then
  YEAR=$LOAD_YEAR
else
  echo "Environment variable LOAD_YEAR not set. Exiting." >&2
  exit 1
fi
export LOAD_YEAR=$YEAR

# Ensure logs directory exists
mkdir -p logs


# Run SystemParsing for this year
# srun $JULIA_DIR/bin/julia --project=. $SYSTEM_SCRIPT $YEAR


# Run system simulation (adjust args if needed)
srun --export=ALL $JULIA_DIR/bin/julia --project=. $SIM_SCRIPT $YEAR
