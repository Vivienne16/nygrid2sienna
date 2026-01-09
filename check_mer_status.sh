#!/bin/bash
# Script to check the status of MER parallel simulations

echo "=========================================="
echo "MER Hourly Simulation Status Check"
echo "=========================================="
echo ""

# Check if logs directory exists
if [ ! -d "logs" ]; then
    echo "No logs directory found. Jobs may not have been submitted yet."
    exit 0
fi

# Count log files
total_logs=$(ls logs/mer_hour_*.out 2>/dev/null | wc -l)
echo "Total job logs found: $total_logs"
echo ""

# Check for completed simulations
echo "Checking completion status for each hour:"
echo ""

for hour in {0..23}; do
    # Find the most recent log file for this hour
    latest_log=$(ls -t logs/mer_hour_${hour}_*.out 2>/dev/null | head -1)
    
    if [ -z "$latest_log" ]; then
        echo "Hour $hour: NOT STARTED"
    elif grep -q "HOUR $hour SIMULATION COMPLETE" "$latest_log" 2>/dev/null; then
        # Extract success/failure counts
        successful=$(grep "Successful:" "$latest_log" | tail -1 | awk '{print $2}')
        failed=$(grep "Failed:" "$latest_log" | tail -1 | awk '{print $2}')
        echo "Hour $hour: COMPLETE (Success: $successful, Failed: $failed)"
    elif grep -q "Error" "$latest_log" 2>/dev/null; then
        echo "Hour $hour: FAILED (see $latest_log)"
    else
        echo "Hour $hour: RUNNING"
    fi
done

echo ""
echo "=========================================="
echo "Slurm Queue Status:"
echo "=========================================="
squeue -u $USER --name=mer_hour_%a

echo ""
echo "=========================================="
echo "Output Directory Status:"
echo "=========================================="
if [ -d "MERHourlySimulations_test" ]; then
    echo "Hours with output directories:"
    for dir in MERHourlySimulations_test/hour_*/; do
        if [ -d "$dir" ]; then
            hour=$(basename "$dir" | sed 's/hour_//')
            num_results=$(find "$dir" -name "*.csv" 2>/dev/null | wc -l)
            echo "  Hour $hour: $num_results result files"
        fi
    done
else
    echo "No output directory found yet."
fi
