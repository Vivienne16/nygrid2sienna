"""
Test script to diagnose CSV write performance on the cluster.
Tests writing large CSV files to check if disk I/O is slow.
"""

using CSV
using DataFrames
using Dates

function test_csv_write()
    println("="^60)
    println("TESTING CSV WRITE PERFORMANCE")
    println("="^60)
    
    # Create test DataFrame with realistic size (8760 hours × many columns)
    n_rows = 8760
    n_cols = 50
    
    println("\nCreating test DataFrame:")
    println("  - Rows: $n_rows")
    println("  - Columns: $n_cols")
    
    create_start = time()
    
    # Create DataFrame with timestamps and random data
    df = DataFrame(DateTime = collect(DateTime(2019, 1, 1):Hour(1):DateTime(2019, 12, 31, 23)))
    for i in 1:n_cols
        df[!, "Column_$i"] = rand(n_rows) .* 1000
    end
    
    create_time = time() - create_start
    println("✓ DataFrame created in $(round(create_time, digits=2)) seconds")
    
    # Test 1: Write to current directory
    println("\n--- Test 1: Writing to current directory ---")
    output_file1 = "test_csv_output_1.csv"
    println("Output file: $output_file1")
    println("Starting write at: $(Dates.now())")
    
    write_start = time()
    CSV.write(output_file1, df)
    write_time = time() - write_start
    
    println("✓ CSV written in $(round(write_time, digits=2)) seconds")
    file_size = filesize(output_file1) / (1024 * 1024)
    println("  File size: $(round(file_size, digits=2)) MB")
    println("  Write speed: $(round(file_size / write_time, digits=2)) MB/s")
    
    # Test 2: Write to temp directory
    println("\n--- Test 2: Writing to temp directory ---")
    temp_dir = "test_temp_dir"
    if !isdir(temp_dir)
        mkpath(temp_dir)
    end
    
    output_file2 = joinpath(temp_dir, "test_csv_output_2.csv")
    println("Output file: $output_file2")
    println("Starting write at: $(Dates.now())")
    
    write_start = time()
    CSV.write(output_file2, df)
    write_time = time() - write_start
    
    println("✓ CSV written in $(round(write_time, digits=2)) seconds")
    file_size = filesize(output_file2) / (1024 * 1024)
    println("  File size: $(round(file_size, digits=2)) MB")
    println("  Write speed: $(round(file_size / write_time, digits=2)) MB/s")
    
    # Test 3: Multiple small writes
    println("\n--- Test 3: Multiple small writes (10 files) ---")
    multi_write_start = time()
    
    for i in 1:10
        small_df = df[1:876, :]  # 10% of data
        output_file = joinpath(temp_dir, "test_small_$i.csv")
        CSV.write(output_file, small_df)
    end
    
    multi_write_time = time() - multi_write_start
    println("✓ 10 files written in $(round(multi_write_time, digits=2)) seconds")
    println("  Average per file: $(round(multi_write_time / 10, digits=2)) seconds")
    
    # Cleanup
    println("\n--- Cleanup ---")
    rm(output_file1)
    rm(temp_dir, recursive=true)
    println("✓ Test files cleaned up")
    
    println("\n✓ All tests completed successfully!")
end

# Run the test
test_csv_write()
