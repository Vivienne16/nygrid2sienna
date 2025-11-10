"""
Create 25 systems: 24 with MER load addition for specific hours + 1 baseline system.

This script generates 25 power system models:
- Systems 0-23: Add MER load for a specific hour (0-23) of every day in the year
  * System 0: Adds MER load at hour 0 of every day (midnight)
  * System 1: Adds MER load at hour 1 of every day
  * ...
  * System 23: Adds MER load at hour 23 of every day (11 PM)
- System 24: Baseline system with no MER modifications (reference case)

The MER load addition is applied only to buses in zone "C" (bus 65) and only for the 
specified hour of each day. Hour 24 represents the baseline case without any MER additions.
"""

using CSV
using DataFrames
using Dates
using TimeSeries
using InfrastructureSystems
using PowerSystems
const PSY = PowerSystems
const IS = InfrastructureSystems

include("parsing_utils.jl")

# Configuration parameters
base_power = 100
load_year = 2019
base_load_scale = 1.16  # 1.5% annual increase from 2020 load level to 2030
res_load_scale = 0.09   # 9% increase in residential load for 2030
com_load_scale = 0.02   # 2% increase in commercial load for 2030
ev_load_scale = 0.25    # 14% for 2030, which is about 1M
mer_load_magnitude = 1.0  # MER load magnitude per hour

function create_hourly_mer_load_profile(baseline_profile, target_hour, load_year)
    """
    Create a MER load profile that adds load only at the target hour of each day.
    
    Args:
        baseline_profile: DataFrame with baseline load profiles
        target_hour: Hour of day (0-23) to add MER load
        load_year: Year for the load profile
    
    Returns:
        Dictionary mapping bus IDs to modified load time series
    """
    
    # Get the total number of hours in the year
    start_date = DateTime(load_year, 1, 1)
    end_date = DateTime(load_year + 1, 1, 1) - Hour(1)
    total_hours = Int(Dates.value(end_date - start_date) / (1000 * 3600)) + 1
    
    println("Creating MER profile for hour $target_hour of each day")
    println("Total hours in year $load_year: $total_hours")
    
    # Verify baseline profile has correct number of rows
    if nrow(baseline_profile) != total_hours
        @warn "Baseline profile has $(nrow(baseline_profile)) rows, expected $total_hours"
    end
    
    # Create modified load profiles for each bus
    modified_profiles = Dict()
    
    for busid in names(baseline_profile)
        if busid == "1"  # Skip the first column if it's an index
            continue
        end
        
        # Get baseline load for this bus
        baseline_load = baseline_profile[!, busid] * base_load_scale
        
        # Create MER addition vector (zeros except for target hours)
        mer_addition = zeros(length(baseline_load))
        
        # Add MER load at target hour of each day
        current_date = start_date
        hour_index = 1
        
        while hour_index <= length(baseline_load) && current_date <= end_date
            current_hour = hour(current_date)
            
            # Add MER load if this is the target hour
            if current_hour == target_hour
                mer_addition[hour_index] = mer_load_magnitude
            end
            
            # Move to next hour
            current_date += Hour(1)
            hour_index += 1
        end
        
        # Combine baseline and MER load
        modified_profiles[busid] = baseline_load + mer_addition
    end
    
    return modified_profiles
end

function create_system_with_hourly_mer(target_hour, output_filename=nothing)
    """
    Create a power system with MER load added at specific hour of each day.
    
    Args:
        target_hour: Hour of day (0-23) to add MER load, or 24 for baseline (no MER)
        output_filename: Optional custom filename for output JSON
    """
    
    if target_hour == 24
        println("\n" * "="^60)
        println("CREATING BASELINE SYSTEM (NO MER MODIFICATIONS)")
        println("="^60)
    else
        println("\n" * "="^60)
        println("CREATING SYSTEM WITH MER LOAD AT HOUR $target_hour")
        println("="^60)
    end
    
    # Create new system
    sys = PSY.System(base_power)
    set_units_base_system!(sys, PSY.UnitSystem.NATURAL_UNITS)
    
    df_bus = CSV.read("config/bus_config.csv", DataFrame)
    
    ##########################
    ##### ADD LOAD ZONES #####
    ##########################
    zone_list = unique(df_bus[!, "zone"])
    for zone in zone_list
        z = PSY.Area(zone, 0.0, 0.0)
        PSY.add_component!(sys, z)
    end
    
    ##########################
    ##### ADD BUSES ##########
    ##########################
    for (bus_id, bus) in enumerate(eachrow(df_bus))
        number = bus.busIdx
        name = bus.name * "_" * string(bus.Vn)
        bustype = bus.busType
        angle = bus.a0
        magnitude = bus.v0
        voltage_limits = (min=bus.vmin, max=bus.vmax)
        base_voltage = bus.Vn
        area = get_component(PSY.Area, sys, bus.zone)
        _build_bus(sys, number, name, bustype, angle, magnitude, voltage_limits, base_voltage, area)
    end
    
    ##########################
    ##### ADD Transmission ###
    ##########################
    df_branch = CSV.read("config/branch_config_2040.csv", DataFrame)
    br_name_list = Set()
    for (br_id, br) in enumerate(eachrow(df_branch))
        from_id = br.from
        to_id = br.to
        from_bus = first(get_components(x -> PSY.get_number(x) == from_id, ACBus, sys))
        to_bus = first(get_components(x -> PSY.get_number(x) == to_id, ACBus, sys))
        v1 = PSY.get_base_voltage(from_bus)
        v2 = PSY.get_base_voltage(to_bus)
        name = string(from_id) * "-" * string(to_id)
        if name in br_name_list
            name = name * "~2"
        end
        push!(br_name_list, name)
        r = br.r
        x = br.x
        b = br.b
        if br.rating_A != 0.0
            rating = br.rating_A
        else
            rating = 99999.0
        end
        if v1 == v2
            _build_lines(sys; frombus=from_bus, tobus=to_bus, name=name, r=r, x=x, b=b, rating=rating)
        else
            _build_transformers(sys; frombus=from_bus, tobus=to_bus, name=name, r=r, x=x, b=b, rating=rating)
        end
    end
    
    ##########################
    ##### ADD DCline #########
    ##########################
    df_hvdc = CSV.read("config/hvdc_config.csv", DataFrame)
    for (hvdc_id, hvdc) in enumerate(eachrow(df_hvdc))
        name = hvdc.name
        from_id = hvdc.from_bus
        to_id = hvdc.to_bus
        from_bus = first(get_components(x -> PSY.get_number(x) == from_id, ACBus, sys))
        to_bus = first(get_components(x -> PSY.get_number(x) == to_id, ACBus, sys))
        rating = hvdc.Pmax
        _build_hvdc(sys; frombus=from_bus, tobus=to_bus, name=name, r=0.0, x=0.0, b=0.0, rating=rating)
    end
    
    ##########################
    ### ADD InterfaceLimits ##
    ##########################
    df_iflim = CSV.read("config/interfaceflow_limits_2030.csv", DataFrame)
    df_ifmap = CSV.read("config/interfaceflow_mapping_2030.csv", DataFrame)
    for idx = 1:nrow(df_iflim)
        name = "IF_" * string(idx)
        rating_lb = df_iflim[df_iflim.index.==Int(idx), :rating_lb][1]
        rating_ub = df_iflim[df_iflim.index.==Int(idx), :rating_ub][1]
        setoflines = df_ifmap[df_ifmap.index.==Int(idx), :mapping]
        signofline = float(df_ifmap[df_ifmap.index.==Int(idx), :sign])
        ifdict = Dict(zip(string.(setoflines), signofline))
        _build_interface_flow(sys; name, rating_lb, rating_ub, ifdict)
    end
    
    ##########################
    ### ADD Generators #######
    ##########################
    
    # Add all generators using the same logic as original SystemParsing.jl
    # (Copying the generator addition code from the original file)
    
    pm_mapping = Dict(
        "Combustion Turbine" => PrimeMovers.CT,
        "Combined Cycle" => PrimeMovers.CC,
        "Internal Combustion" => PrimeMovers.IC,
        "Steam Turbine" => PrimeMovers.ST,
        "Jet Engine" => PrimeMovers.GT,
    )
    
    fuel_mapping = Dict(
        "Kerosene" => ThermalFuels.DISTILLATE_FUEL_OIL,
        "Natural Gas" => ThermalFuels.NATURAL_GAS,
        "Fuel Oil 2" => ThermalFuels.DISTILLATE_FUEL_OIL,
        "Coal" => ThermalFuels.COAL,
        "Fuel Oil 6" => ThermalFuels.RESIDUAL_FUEL_OIL,
    )
    
    #### Add Thermal #########
    df_thermal = CSV.read("config/thermal_config.csv", DataFrame)
    retire_gen_id = CSV.read("config/retired_generators_2025.csv", DataFrame)[!,"PTID"]
    fuel_cost = CSV.read("Data/fuelPriceWeekly_2019.csv", DataFrame)
    for (th_id, th) in enumerate(eachrow(df_thermal))
        available = true
        if th.PTID in retire_gen_id
           available = false
        end
        name = th.Name
        bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
        fuel = fuel_mapping[th.FuelType]
        pmin = th.Pmin
        pmax = th.Pmax
        op_cost = _add_thermal_cost(th.HeatRateLM_1, th.HeatRateLM_0, th.Zone, th.FuelType, pmin, fuel_cost)
        ramp_rate = th.maxRamp10 / 10.0
        pm = pm_mapping[th.UnitType]
        generator = _add_thermal(sys, bus, name=name, available=available, fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
    end
    
    ##  Add Nuclear ##############
    df_nuclear = CSV.read("config/nuclear_config.csv", DataFrame)
    nuclear_cf = CSV.read("Data/nuclearGenDaily_2019.csv", DataFrame)
    for (th_id, th) in enumerate(eachrow(df_nuclear))
        name = th.Name
        bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
        fuel = ThermalFuels.NUCLEAR
        pmin = th.Pmin
        pmax = th.Pmax
        op_cost = ThermalGenerationCost(;
            variable=FuelCurve(; value_curve=LinearCurve(1.1), fuel_cost=1.0),
            fixed=0.0,
            start_up=0.0,
            shut_down=0.0,
        )
        ramp_rate = th.maxRamp10 / 10.0
        pm = PrimeMovers.ST
        generator = _add_nuclear(sys, bus, name=name, fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
    end
    
    ##  Add Hydro ##############
    df_hydro = CSV.read("config/hydro_config.csv", DataFrame)
    for (hy_id, hy) in enumerate(eachrow(df_hydro))
        name = hy.Name
        bus = first(get_components(x -> PSY.get_number(x) == hy.BusId, ACBus, sys))
        pmin = hy.Pmin
        pmax = hy.Pmax
        op_cost = HydroGenerationCost(;
            variable=FuelCurve(; value_curve=LinearCurve(0.0), fuel_cost=1.0),
            fixed=0.0,
        )
        ramp_rate = hy.maxRamp10 / 10.0
        pm = PrimeMovers.HY
        timest = get_timestamp(load_year)
        hy_ts = ones(size(timest)) * pmax
        generator = _add_hydro(sys, bus, name=name, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm, ts=hy_ts)
    end
    
    ##  Add AggGen ###########
    zonename_mapping = Dict(
        "NEISO" => "NPX",
        "PJM" => "PJM",
        "IESO" => "O H",
        "HQ" => "H Q",
    )
    average_price = Dict(
        "NEISO" => 28.44,
        "PJM" => 24.0,
        "IESO" => 17.9,
        "HQ" => 18.35,
        )
    df_agg = CSV.read("config/agggen_config.csv", DataFrame)
    df_hourlylmp = CSV.read("Data/priceHourly_2019.csv", DataFrame)
    for (th_id, th) in enumerate(eachrow(df_agg))
        name = th.Name
        bus = first(get_components(x -> PSY.get_number(x) == th.BusId, ACBus, sys))
        fuel = ThermalFuels.OTHER
        pmin = th.Pmin
        if name != "Hqimport"
            pmax = th.Pmax
        else
            pmax = th.Pmax
        end
        # filtered_df = filter(row -> row.ZoneName == zonename_mapping[th.Zone], df_hourlylmp)
        # zonal_price = filtered_df[1, "LBMP"]
        zonal_price = average_price[th.Zone]
        op_cost = ThermalGenerationCost(;
            variable=FuelCurve(; value_curve=LinearCurve(zonal_price), fuel_cost=1.0),
            fixed=0.0,
            start_up=0.0,
            shut_down=0.0,
        )
        ramp_rate = th.maxRampAgc
        pm = PrimeMovers.OT
        generator = _add_thermal(sys, bus, name=name, available = true,fuel=fuel, cost=op_cost, pmin=pmin, pmax=pmax, ramp_rate=ramp_rate, pm=pm)
    end
    
    ##########################
    ### ADD LOADS ############
    ##########################
    
    ###### Baseline Load with Hourly MER Addition ##########
    baseline_load_profile = CSV.read("load_profile/Baseload/Baseload_" * string(load_year) * ".csv", DataFrame)
    
    # Create modified load profiles with hourly MER addition (only if not baseline)
    if target_hour == 24
        # Hour 24 = baseline system with no MER modifications
        modified_load_profiles = nothing
        println("Creating baseline system - no MER load additions")
    else
        # Hours 0-23 = add MER load at specific hour
        modified_load_profiles = create_hourly_mer_load_profile(baseline_load_profile, target_hour, load_year)
    end
    
    for busid in names(baseline_load_profile)
        if busid == "1"  # Skip index column if present
            continue
        end
        
        bus = first(get_components(x -> PSY.get_number(x) == parse(Float64, busid), ACBus, sys))
        name = "Baseline_load_" * busid
        
        # Use modified load profile for zone C (bus 65), regular profile for others
        if busid == "65" && target_hour != 24
            # Add MER load for hours 0-23
            load_ts = modified_load_profiles[busid]
        else
            # Use baseline load for hour 24 or non-zone C buses
            load_ts = baseline_load_profile[!, busid] * base_load_scale
        end
        
        _build_load(sys, bus, name, load_ts, load_year)
    end
    
    ###### Comstock Load ##########
    comstock_load_profile = CSV.read("load_profile/Comload/Comload_" * string(load_year) * ".csv", DataFrame)
    for busid in names(comstock_load_profile)
        if busid == "1"
            continue
        end
        bus = first(get_components(x -> PSY.get_number(x) == parse(Float64, busid), ACBus, sys))
        name = "Comstock_load_" * busid
        load_ts = comstock_load_profile[!, busid]*com_load_scale
        _build_load(sys, bus, name, load_ts, load_year)
    end
    
    ###### Resstock Load ##########
    resstock_load_profile = CSV.read("load_profile/Resload/Resload_" * string(load_year) * ".csv", DataFrame)
    for busid in names(resstock_load_profile)
        if busid == "1"
            continue
        end
        bus = first(get_components(x -> PSY.get_number(x) == parse(Float64, busid), ACBus, sys))
        name = "Resstock_load_" * busid
        load_ts = resstock_load_profile[!, busid]*res_load_scale
        _build_load(sys, bus, name, load_ts, load_year)
    end
    
    ###### EV Load ##########
    ev_load_profile = CSV.read("load_profile/EVload/EVload.csv", DataFrame)
    for busid in names(ev_load_profile)
        if busid == "1"
            continue
        end
        bus = first(get_components(x -> PSY.get_number(x) == parse(Float64, busid), ACBus, sys))
        name = "EV_load_" * busid
        load_ts = ev_load_profile[!, busid]*ev_load_scale
        _build_load(sys, bus, name, load_ts, load_year)
    end
    
    ##########################
    ### ADD Wind ############
    ##########################
    df_wind = CSV.read("config/wind_config_2030.csv", DataFrame)
    wind_profile_raw = CSV.read("wind_profile/Wind" * string(load_year) * ".csv", DataFrame, header=false)
    new_header = wind_profile_raw.Column1
    transposed_data = permutedims(Matrix(select(wind_profile_raw, Not(:Column1))))
    wind_profile = DataFrame(transposed_data, Symbol.(string.(new_header)), makeunique=true)
    
    for (wind_id, wind) in enumerate(eachrow(df_wind))
        name = wind.name
        bus = first(get_components(x -> PSY.get_number(x) == wind.BusId, ACBus, sys))
        rating = wind.rating
        op_cost = RenewableGenerationCost(; variable=CostCurve(; value_curve=LinearCurve(1.0)))
        if wind.name[1:3] == "OSW" && wind.BusId in [79, 80]
            re_ts = wind_profile[!, string(wind.BusId)*"_1"]
        else
            re_ts = wind_profile[!, string(wind.BusId)]
        end
        generator = _add_wind(sys, bus, name, rating, op_cost, re_ts, load_year)
    end
    
    ##########################
    ### ADD UPV ############
    ##########################
    df_upv = CSV.read("config/upv_config_2030.csv", DataFrame)
    upv_profile_raw = CSV.read("upv_profile/solarUPV" * string(load_year) * ".csv", DataFrame, header=false)
    new_header = upv_profile_raw.Column1
    transposed_data = permutedims(Matrix(select(upv_profile_raw, Not(:Column1))))
    upv_profile = DataFrame(transposed_data, Symbol.(string.(new_header)), makeunique=true)
    
    for (upv_id, upv) in enumerate(eachrow(df_upv))
        name = upv.name
        bus = first(get_components(x -> PSY.get_number(x) == upv.BusId, ACBus, sys))
        rating = upv.rating
        op_cost = RenewableGenerationCost(; variable=CostCurve(; value_curve=LinearCurve(1.0)))
        re_ts = upv_profile[!, string(upv.BusId)]
        generator = _add_upv(sys, bus, name, rating, op_cost, re_ts, load_year)
    end
    
    ##########################
    ### ADD DPV ############
    ##########################
    df_dpv = CSV.read("config/dpv_config_2030.csv", DataFrame)
    dpv_profile_raw = CSV.read("dpv_profile/solarDPV" * string(load_year) * ".csv", DataFrame, header=false)
    new_header = dpv_profile_raw.Column1
    transposed_data = permutedims(Matrix(select(dpv_profile_raw, Not(:Column1))))
    dpv_profile = DataFrame(transposed_data, Symbol.(string.(new_header)), makeunique=true)
    
    for (dpv_id, dpv) in enumerate(eachrow(df_dpv))
        name = dpv.name
        bus = first(get_components(x -> PSY.get_number(x) == dpv.BusId, ACBus, sys))
        rating = dpv.rating
        op_cost = RenewableGenerationCost(; variable=CostCurve(; value_curve=LinearCurve(1.0)))
        re_ts = dpv_profile[!, string(dpv.BusId)]
        generator = _add_dpv(sys, bus, name, rating, op_cost, re_ts, load_year)
    end
    
    ##########################
    ### ADD Storage ##########
    ##########################
    df_storage = CSV.read("config/storage_config_2030.csv", DataFrame)
    
    for (sto_id, sto) in enumerate(eachrow(df_storage))
        name = sto.name
        bus = first(get_components(x -> PSY.get_number(x) == sto.BusId, ACBus, sys))
        power_capacity = sto.PowerCap
        energy_capacity = sto.EnergyCap
        efficiency = 0.95
        op_cost = StorageCost(charge_variable_cost=CostCurve(LinearCurve(1.0)))
        
        storage = _add_storage(sys, bus, name, power_capacity, energy_capacity, efficiency, op_cost)
    end
    
    # Save system to JSON file
    if output_filename === nothing
        if target_hour == 24
            output_filename = "baseline_nys2030_$(load_year).json"
        else
            output_filename = "mer_hourly_$(target_hour)_nys2030_$(load_year).json"
        end
    end

    PSY.to_json(sys, joinpath("MERsystems", output_filename), force=true)
    println("System saved to: $output_filename")
    
    return sys, output_filename
end

function create_all_hourly_mer_systems()
    """
    Create all 25 systems: 24 with MER load addition for each hour (0-23) plus baseline (24).
    """
    
    println("\n" * "="^80)
    println("CREATING 25 SYSTEMS: 24 HOURLY MER + 1 BASELINE")
    println("="^80)
    println("This will create 25 power system files:")
    println("- Hours 0-23: MER load added at specific hour of every day")
    println("- Hour 24: Baseline system with no MER modifications")
    println("="^80)
    
    created_systems = []
    
    for hour in 0:24  # Now includes hour 24 for baseline
        try
            if hour == 24
                println("\n--- Creating Baseline System (Hour 24) ---")
            else
                println("\n--- Creating MER system for hour $hour ---")
            end
            
            sys, filename = create_system_with_hourly_mer(hour)
            
            # Verify system was created successfully
            num_buses = length(get_components(Bus, sys))
            num_loads = length(get_components(StandardLoad, sys))
            num_generators = length(get_components(Generator, sys))
            
            if hour == 24
                println("✓ Baseline system created successfully:")
            else
                println("✓ MER system $hour created successfully:")
            end
            println("  - Buses: $num_buses")
            println("  - Loads: $num_loads") 
            println("  - Generators: $num_generators")
            println("  - File: $filename")
            
            push!(created_systems, (hour=hour, filename=filename, buses=num_buses, loads=num_loads, generators=num_generators))
            
        catch e
            if hour == 24
                println("✗ Error creating baseline system:")
            else
                println("✗ Error creating system for hour $hour:")
            end
            println("  Error: $e")
            @warn "Failed to create system for hour $hour" exception=e
        end
    end
    
    println("\n" * "="^80)
    println("SUMMARY OF CREATED SYSTEMS")
    println("="^80)
    println("Successfully created $(length(created_systems)) out of 25 systems:")
    println()
    println("Hour | Type      | Filename | Buses | Loads | Generators")
    println("-"^70)
    
    for sys_info in created_systems
        if sys_info.hour == 24
            sys_type = "Baseline"
        else
            sys_type = "MER"
        end
        println("$(lpad(sys_info.hour, 4)) | $(rpad(sys_type, 9)) | $(sys_info.filename) | $(lpad(sys_info.buses, 5)) | $(lpad(sys_info.loads, 5)) | $(lpad(sys_info.generators, 10))")
    end
    
    if length(created_systems) == 25
        println("\n🎉 All 25 systems created successfully!")
        println("   - 24 hourly MER systems (hours 0-23)")
        println("   - 1 baseline system (hour 24)")
    else
        println("\n⚠️  Only $(length(created_systems)) systems were created successfully.")
        failed_hours = setdiff(0:24, [s.hour for s in created_systems])
        println("Failed hours: $(join(failed_hours, ", "))")
    end
    
    println("="^80)
    
    return created_systems
end

# If run directly, create all systems
created_systems = create_all_hourly_mer_systems()
