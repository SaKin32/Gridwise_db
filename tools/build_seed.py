#!/usr/bin/env python3
"""
JSON (BUP_CSE_FEST_2026_Preli_Public_Sample_Cases.json) -> sql/04_seed_samples.sql

Usage:  python build_seed.py  <json_path>  <output_sql_path>
This script only generates SQL INSERT statements. Python is not needed when running on XAMPP,
because the generated 04_seed_samples.sql file is already provided.
"""
import json
import sys
from decimal import Decimal


def q(s):
    """SQL string literal"""
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


def num(x):
    return format(Decimal(str(x)).normalize(), "f")


def main(json_path, out_path):
    data = json.load(open(json_path, encoding="utf-8"))
    cases = data["cases"]

    scn, bat, hrs, notes, dirs, dhours, plans, hplans = [], [], [], [], [], [], [], []
    note_id = dir_id = plan_id = 0

    for case in cases:
        inp, out = case["input"], case["expected_output"]
        sid = inp["scenario_id"]
        scn.append(f"({q(sid)}, {q(case['label'])}, 'public_sample')")
        b = inp["battery"]
        bat.append(
            f"({q(sid)}, {num(b['capacity_kwh'])}, {num(b['initial_energy_kwh'])}, {num(b['minimum_energy_kwh'])}, "
            f"{num(b['max_charge_kwh_per_hour'])}, {num(b['max_discharge_kwh_per_hour'])})"
        )
        assert [h["hour"] for h in inp["hours"]] == list(range(24)), sid
        for h in inp["hours"]:
            hrs.append(f"({q(sid)}, {h['hour']}, {num(h['demand_kwh'])}, {num(h['solar_kwh'])}, {num(h['tariff_bdt_per_kwh'])})")

        assert len(inp["operator_notes"]) == len(out["directive_interpretation"]), sid
        for idx, (text, di) in enumerate(zip(inp["operator_notes"], out["directive_interpretation"])):
            assert di["note_index"] == idx
            note_id += 1
            dir_id += 1
            notes.append(f"({note_id}, {q(sid)}, {idx}, {q(text)})")
            adj = di["structured_adjustment"] or {}
            factor = num(adj["factor"]) if "factor" in adj else "NULL"
            reserve = num(adj["minimum_energy_kwh"]) if "minimum_energy_kwh" in adj else "NULL"
            cap = num(adj["max_grid_kwh"]) if "max_grid_kwh" in adj else "NULL"
            dirs.append(
                f"({dir_id}, {note_id}, {q(di['directive_type'])}, {1 if di['applies'] else 0}, "
                f"{factor}, {reserve}, {cap}, {q(di['explanation'])})"
            )
            for hr in adj.get("hours", []):
                dhours.append(f"({dir_id}, {hr})")

        # reference plan + totals cross-check (check that our totals match the totals given in the JSON)
        plan_id += 1
        plans.append(f"({plan_id}, {q(sid)}, 'reference_optimal', {q(out['plan_summary'])})")
        total_grid = total_cost = Decimal(0)
        peak = Decimal(0)
        rows = []
        for hp, hin in zip(out["hourly_plan"], inp["hours"]):
            assert hp["hour"] == hin["hour"]
            g = Decimal(str(hp["grid_kwh"]))
            total_grid += g
            total_cost += g * Decimal(str(hin["tariff_bdt_per_kwh"]))
            peak = max(peak, g)
            rows.append(
                f"({plan_id}, {hp['hour']}, {num(hp['grid_kwh'])}, {num(hp['solar_used_kwh'])}, "
                f"{q(hp['battery_action'])}, {num(hp['battery_kwh'])}, {num(hp['battery_energy_after_kwh'])})"
            )
        assert abs(total_grid - Decimal(str(out["total_grid_kwh"]))) < Decimal("0.01"), (sid, "grid")
        assert abs(total_cost - Decimal(str(out["total_cost_bdt"]))) < Decimal("0.01"), (sid, "cost")
        assert abs(peak - Decimal(str(out["peak_grid_kwh"]))) < Decimal("0.01"), (sid, "peak")
        hplans.append(rows)

    def block(table, cols, values):
        return f"INSERT INTO {table} ({cols}) VALUES\n  " + ",\n  ".join(values) + ";\n\n"

    parts = [
        "-- =====================================================================\n"
        "--  File 4: 10 public sample cases (generated automatically from the JSON)\n"
        "--  Source: BUP CSE Fest 2026 Preliminary - GridWise Public Sample Case Pack\n"
        "--  (every reference plan is validated by the triggers while it is inserted)\n"
        "-- =====================================================================\n"
        "SET NAMES utf8mb4;\nUSE gridwise_db;\nSTART TRANSACTION;\n\n",
        block("scenario", "scenario_id, label, source", scn),
        block("battery_config", "scenario_id, capacity_kwh, initial_energy_kwh, minimum_energy_kwh, "
              "max_charge_kwh_per_hour, max_discharge_kwh_per_hour", bat),
        block("hourly_input", "scenario_id, hour_no, demand_kwh, solar_kwh, tariff_bdt_per_kwh", hrs),
        block("operator_note", "note_id, scenario_id, note_index, note_text", notes),
        block("directive", "directive_id, note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh, explanation", dirs),
        block("directive_hour", "directive_id, hour_no", dhours),
        block("plan", "plan_id, scenario_id, plan_name, plan_summary", plans),
    ]
    for rows in hplans:
        parts.append(block("hourly_plan", "plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh", rows))
    parts.append("COMMIT;\n\n")

    parts.append(
        "-- Try to build a 'battery idle' baseline plan for each sample (stored procedure + transaction).\n"
        "-- In cases where the baseline is invalid because of a directive (for example a grid cap), the procedure rolls back by itself\n"
        "-- and stores the reason in @msg. This is proof that the triggers work.\n"
    )
    for case in cases:
        sid = case["input"]["scenario_id"]
        parts.append(f"CALL sp_create_baseline_plan({q(sid)}, 'baseline_no_battery', @ok, @msg);\n")
    parts.append("\n")
    open(out_path, "w", encoding="utf-8").write("".join(parts))
    print(f"wrote {out_path}: {len(cases)} scenarios, {note_id} notes, {len(dhours)} directive-hours, {plan_id} reference plans")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
