#!/bin/bash
# Submit individual SLURM jobs for years 1998-2019 using run_systems.sh
PROJECT_DIR="/home/fs02/pmr82_0001/ml2589/nygrid2sienna"
SCRIPT="run_systems.sh"

cd "$PROJECT_DIR" || exit 1
module load gurobi
for year in 2003 2015; do
  echo "Submitting job for year $year"
  sbatch --export=LOAD_YEAR=$year $SCRIPT
  sleep 0.1
done
