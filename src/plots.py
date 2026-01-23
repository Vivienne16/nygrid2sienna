import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import yaml
import shutil
import datetime as dt
from plotly.subplots import make_subplots
import plotly.graph_objects as go
import plotly.express as px
import re
import os
import json

def load_color(file: str) -> dict:
    with open(file, 'r') as f:
        color_dict = yaml.safe_load(f)
    return pd.DataFrame.from_dict(color_dict).T.sort_values(by='order')["RGB"].to_dict()

def load_gen_mapping(file: str) -> dict:
    with open(file, 'r') as f:
        gen_mapping = yaml.safe_load(f)
    list_of_dicts = []
    for key, value in gen_mapping.items():
        for v in value:
            v["group"] = key
        list_of_dicts.append(value)
    return pd.DataFrame.from_dict(list_of_dicts)

def get_gen_mix(df,gen_mapping,fuel_mapper):
    keys = list(gen_mapping["mapper"].keys()) + gen_mapping["vars"]
    df = df.query("metric.isin(@keys)").copy()
    
    fuel_map = {}
    for k,v in fuel_mapper.items():
        fuel_map.update({var[1]:k for var in v})
    df["type"] = df["variable"].map(fuel_map)
    df.loc[df["metric"].isin(gen_mapping["mapper"].keys()),"type"] = df["metric"].map(gen_mapping["mapper"])
    
    return df.pivot_table(index="DateTime",columns="type",values="value",aggfunc="sum").rename_axis("variable",axis=1)

def renewable_percentage(df_gen_mix, df_load_mix):
    total_gen = df_gen_mix.sum(axis=1)
    renewable_gen = df_gen_mix[[col for col in df_gen_mix.columns if col in ["PV","Wind","Hydropower"]]].sum(axis=1)
    total_load = df_load_mix.sum(axis=1)
    renewable_pct = (renewable_gen / total_load) * 100
    return renewable_pct

def total_renewable_percentage(df_gen_mix, df_load_mix):
    """Calculate total renewable percentage for the full horizon"""
    renewable_cols = [col for col in df_gen_mix.columns if col in ["PV","Wind","Hydropower"]]
    total_renewable_gen = df_gen_mix[renewable_cols].sum().sum()
    total_load = df_load_mix.sum().sum()
    total_renewable_pct = (total_renewable_gen / total_load) * 100
    return total_renewable_pct

def total_fc_percentage(df_gen_mix, df_load_mix):
    """Calculate total renewable percentage for the full horizon"""
    renewable_cols = [col for col in df_gen_mix.columns if col in ["PV","Wind","Hydropower","Nuclear"]]
    total_renewable_gen = df_gen_mix[renewable_cols].sum().sum()
    total_load = df_load_mix.sum().sum()
    total_renewable_pct = (total_renewable_gen / total_load) * 100
    return total_renewable_pct

def dispatch_plot(df, gen_mapping, color_mapping, load_mapper,fuel_mapper, folder, output_dir):
    rows = 2
    subplot_titles = ["Generation Mix","Storage SOC"]
    fig = make_subplots(rows=rows, cols=1, shared_xaxes=True, vertical_spacing=0.1,
                            subplot_titles=subplot_titles)

    df_batt_soc = df.query("metric == 'EnergyVariable__EnergyReservoirStorage'").pivot(index="DateTime",columns="variable",values="value")
    bess_sum = df_batt_soc.sum(axis=1)
    fig.add_trace(go.Scatter(x=bess_sum.index, y=bess_sum.values, name="Total BESS SOC",
                            fill="tonexty",stackgroup="BESS"), row=2, col=1)
    fig.update_yaxes(title_text="MWh", row=2, col=1)

        
    df_gen_mix = get_gen_mix(df,gen_mapping,fuel_mapper)
    gen_cols_known = {k:v for k,v in color_mapping.items() if k in df_gen_mix.columns}
    gen_cols_unknown = [col for col in df_gen_mix.columns if col not in color_mapping.keys()]
    for col, color in gen_cols_known.items():
        fig.add_trace(go.Scatter(x=df_gen_mix.index, y=df_gen_mix[col], name=col,
                                fill="tonexty", stackgroup="Generation", line=dict(color=color)), row=1, col=1)
        
        for col in gen_cols_unknown:
            fig.add_trace(go.Scatter(x=df_gen_mix.index, y=df_gen_mix[col], name=col,
                                    fill="tonexty", stackgroup="Generation"), row=1, col=1)
            
    df_load_mix = df.query("metric == 'Load'").pivot(index="DateTime",columns="variable",values="value")
    for col in df_load_mix.columns:
        fig.add_trace(go.Scatter(x=df_load_mix.index, y=df_load_mix[col], name=f"Load {col}",
                                    line=dict(dash="dash")), row=1, col=1)
    fig.update_yaxes(title_text="MW", row=1, col=1)
    fig.update_layout(height=800, width=1000, title_text=f"Generation Mix and BESS SOC - {folder}")
    fig.write_html(os.path.join(output_dir,f"{folder}_gen_mix_bess_soc.html"))
    plt.close()
    print(f"Saved plot for {folder}")

results_dir = "MERHourlySimulations_UC_noreserve_newre"
folders = [f for f in os.listdir(results_dir) if os.path.isdir(os.path.join(results_dir, f))]

load_mapper = json.load(open("src/load.json","r"))
gen_mapping = json.load(open("src/gen.json","r"))
color_mapping = load_color("src/color.yaml")
with open("src/aggregation.json","r") as f:
        fuel_mapper = json.load(f)
results_list = []
for folder in folders:
    output_dir = os.path.join(results_dir, folder, "results")
    input_dir = os.path.join(output_dir,f"{folder}.feather")
    df = pd.read_feather(input_dir)
    dispatch_plot(df, gen_mapping, color_mapping, load_mapper, fuel_mapper, folder, output_dir)
    df_gen_mix = get_gen_mix(df,gen_mapping,fuel_mapper)
    df_load_mix = df.query("metric == 'Load'").pivot(index="DateTime",columns="variable",values="value")
    renewable_pct = total_renewable_percentage(df_gen_mix, df_load_mix)
    fc_pct = total_fc_percentage(df_gen_mix, df_load_mix)
    
    # Extract number between underscores from folder name
    match = re.search(r'_(\d+)_', folder)
    folder_num = int(match.group(1)) if match else None
    
    results_list.append({"folder_number": folder_num, "folder": folder, "renewable_percentage": renewable_pct, "fc_percentage": fc_pct})
    print(folder, folder_num, renewable_pct, fc_pct)

results_df = pd.DataFrame(results_list)

# Sort by folder_number
results_df = results_df.sort_values(by='folder_number').reset_index(drop=True)

print("\nSummary of Renewable Percentages:")
print(results_df)

# Save to CSV
results_df.to_csv(os.path.join(results_dir, "renewable_percentages.csv"), index=False)
print(f"\nResults saved to {os.path.join(results_dir, 'renewable_percentages.csv')}")