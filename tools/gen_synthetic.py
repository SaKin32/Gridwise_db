#!/usr/bin/env python3
"""
Synthetic case generator  ->  sql/05_seed_synthetic.sql

Usage:  python gen_synthetic.py <sample_json_path> <output_sql_path> [case_count=60]

* The demand/solar/tariff shape is taken from SAMPLE-01, then randomly scaled and noised.
* Notes (English only) are built from templates, so the "correct answer" of every directive is known.
* For every case a simple 'tariff_shift_heuristic' plan is built (charge in cheap hours, discharge in
  expensive hours). It is NOT an optimal solver; it only gives the database valid test data.
* The seed is fixed (random.Random(1000+i)), so the same data is produced on every run.
"""
import json
import math
import random
import sys

EPS = 0.01


def q(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


def r5(x):
    return int(round(x / 5.0)) * 5


def fmt(x):
    s = f"{x:.2f}".rstrip("0").rstrip(".")
    return s if s else "0"


def en_time(h):
    return f"{h % 12 or 12} {'AM' if h < 12 else 'PM'}"


EN_NOOP = [
    "The cafeteria menu changes tomorrow.",
    "A seminar room booking was moved to next week.",
    "The library is extending book-return hours next month.",
    "The sports office published the new tournament fixtures.",
    "Student affairs will hold a club fair on Friday.",
    "The IT office will update the Wi-Fi password policy next week.",
    "A parking sticker renewal notice was sent to all staff.",
    "The admission office extended the form submission deadline.",
]
REAL_TYPES = ["solar_reduction", "no_charge_window", "no_discharge_window",
              "minimum_battery_reserve", "max_grid_window"]


class Scn:
    pass


def make_scenario(i, base, dir_counter_start=None):
    rng = random.Random(1000 + i)
    s = Scn()
    s.id = f"SYN-{i:03d}"
    dscale = rng.uniform(0.7, 1.5)
    sscale = rng.choice([rng.uniform(0.3, 0.7), rng.uniform(0.8, 1.6), rng.uniform(0.8, 1.6)])
    tscale = rng.uniform(0.8, 1.35)
    s.demand = [max(20, r5(base["demand"][h] * dscale * (1 + rng.uniform(-0.06, 0.06)))) for h in range(24)]
    s.solar = [0 if base["solar"][h] == 0 else max(0, r5(base["solar"][h] * sscale * (1 + rng.uniform(-0.1, 0.1))))
               for h in range(24)]
    s.tariff = [max(3, int(round(base["tariff"][h] * tscale + rng.uniform(-1, 1)))) for h in range(24)]
    cap = rng.choice(range(180, 401, 10))
    init = r5(cap * rng.uniform(0.35, 0.65))
    mn = min(r5(cap * rng.uniform(0.12, 0.2)), init - 10)
    rate = max(30, r5(cap * rng.uniform(0.2, 0.3)))
    s.bat = dict(capacity=cap, initial=init, minimum=mn, max_charge=rate, max_discharge=rate)

    n_notes = rng.choice([1, 2, 2, 3])
    pool = REAL_TYPES + ["no_op"]
    types = rng.sample(pool, n_notes)
    # process solar_reduction first, because the grid cap value depends on effective solar
    types.sort(key=lambda t: (t != "solar_reduction", t == "no_op"))
    s.eff_solar = list(map(float, s.solar))
    notes = []
    for t in types:
        rng.random()  # keeps the random stream layout stable
        L = rng.randint(1, 4)
        st = rng.randint(0, 23 - L)
        hours = list(range(st, st + L))
        a, b = en_time(st), en_time(st + L)
        d = dict(type=t, hours=hours, factor=None, reserve=None, cap=None)
        if t == "solar_reduction":
            p = rng.choice([20, 25, 30, 40, 50, 60])
            d["factor"] = p / 100
            text = rng.choice([
                f"Rooftop solar will produce only about {p}% of forecast from {a} until {b} because of panel maintenance.",
                f"Cloud cover is expected between {a} and {b}; usable solar should be treated as roughly {p}% of normal.",
                f"Expect a {100 - p}% reduction in solar output from {a} to {b}.",
            ])
            d["explanation"] = f"Solar is reduced to {p}% of forecast in the stated window."
            for h in hours:
                s.eff_solar[h] = min(s.eff_solar[h], round(s.solar[h] * d["factor"], 2))
        elif t == "no_charge_window":
            text = (rng.choice([f"The battery charger is isolated for maintenance from {a} until {b}.",
                                f"Do not charge the battery between {a} and {b}."]))
            d["explanation"] = "Battery charging is unavailable in the stated window."
        elif t == "no_discharge_window":
            text = (rng.choice([f"For relay testing, the battery must not discharge from {a} until {b}.",
                                f"Battery discharge is disabled from {a} to {b} during protection tests."]))
            d["explanation"] = "Battery discharging is unavailable in the stated window."
        elif t == "minimum_battery_reserve":
            pct_ok = [p for p in (30, 40, 50, 60) if mn < cap * p / 100 <= init]
            if pct_ok and rng.random() < 0.5:
                p = rng.choice(pct_ok)
                d["reserve"] = cap * p / 100
                text = f"Keep at least {p}% of the battery capacity stored from {a} until {b} for emergency operations."
            else:
                x = r5(rng.uniform(mn + 10, init))
                x = max(min(x, init), mn + 5)
                d["reserve"] = x
                text = f"Keep at least {x} kWh in the battery from {a} until {b} for emergency services."
            d["explanation"] = f"Battery reserve of {fmt(d['reserve'])} kWh is required in the stated window."
        elif t == "max_grid_window":
            need = max(s.demand[h] - min(s.eff_solar[h], s.demand[h]) for h in hours)
            c = int(math.ceil((need + rng.uniform(0, 20)) / 5.0) * 5)
            d["cap"] = c
            text = (rng.choice([f"Grid import must not exceed {c} kWh in any hour from {a} until {b} (temporary feeder limit).",
                                f"The transformer limit is {c} kWh of grid import from {a} until {b}."]))
            d["explanation"] = f"Grid import is capped at {c} kWh per hour in the stated window."
        else:  # no_op
            d["hours"] = []
            text = rng.choice(EN_NOOP)
            d["explanation"] = "This note does not affect today's 24-hour energy schedule."
        d["text"] = text
        notes.append(d)
    rng.shuffle(notes)
    s.notes = notes
    real = [d["type"] for d in notes if d["type"] != "no_op"]
    s.label = f"Synthetic {i:03d}: " + (", ".join(real) if real else "distractor only")
    s.rng = rng
    return s


# ---------- plan evaluation and validation (a copy of the DB rules) ----------
def constraints(s):
    n = 24
    mn = [s.bat["minimum"]] * n
    nochg = [False] * n
    nodis = [False] * n
    cap = [None] * n
    for d in s.notes:
        for h in d["hours"]:
            if d["type"] == "minimum_battery_reserve":
                mn[h] = max(mn[h], d["reserve"])
            elif d["type"] == "no_charge_window":
                nochg[h] = True
            elif d["type"] == "no_discharge_window":
                nodis[h] = True
            elif d["type"] == "max_grid_window":
                cap[h] = d["cap"] if cap[h] is None else min(cap[h], d["cap"])
    return mn, nochg, nodis, cap


def evaluate(s, charge, discharge):
    mn, nochg, nodis, cap = constraints(s)
    b = s.bat
    e = b["initial"]
    rows, cost = [], 0.0
    for h in range(24):
        if (nochg[h] and charge[h] > EPS) or (nodis[h] and discharge[h] > EPS):
            return None
        if charge[h] > b["max_charge"] + EPS or discharge[h] > b["max_discharge"] + EPS:
            return None
        if charge[h] > 0 and discharge[h] > 0:
            return None
        net = s.demand[h] + charge[h] - discharge[h]
        if net < -EPS:
            return None
        su = min(s.eff_solar[h], net)
        grid = net - su
        if cap[h] is not None and grid > cap[h] + EPS:
            return None
        e = e + charge[h] - discharge[h]
        if e < mn[h] - EPS or e > b["capacity"] + EPS:
            return None
        action = "charge" if charge[h] > 0 else ("discharge" if discharge[h] > 0 else "idle")
        kwh = charge[h] if action == "charge" else (discharge[h] if action == "discharge" else 0)
        rows.append((h, round(grid, 2), round(su, 2), action, kwh, round(e, 2)))
        cost += grid * s.tariff[h]
    if abs(e - b["initial"]) > EPS:
        return None
    return rows, cost


def heuristic(s):
    charge, discharge = [0.0] * 24, [0.0] * 24
    base = evaluate(s, charge, discharge)
    best = base[1]
    moved = 0
    for _ in range(10):
        cands = sorted(((s.tariff[j] - s.tariff[i], i, j) for i in range(24) for j in range(24)
                        if i != j and s.tariff[j] - s.tariff[i] >= 3 and charge[j] == 0 and discharge[i] == 0),
                       reverse=True)[:60]
        improved = False
        for spread, i, j in cands:
            room = min(s.bat["max_charge"] - charge[i], s.bat["max_discharge"] - discharge[j])
            for frac in (1.0, 0.75, 0.5, 0.25):
                x = r5(room * frac)
                if x < 5:
                    continue
                charge[i] += x
                discharge[j] += x
                ev = evaluate(s, charge, discharge)
                if ev and ev[1] < best - 0.5:
                    best = ev[1]
                    moved += x
                    improved = True
                    break
                charge[i] -= x
                discharge[j] -= x
            if improved:
                break
        if not improved:
            break
    ev = evaluate(s, charge, discharge)
    return (ev[0], moved) if moved > 0 else (None, 0)


def main(json_path, out_path, count=60):
    d = json.load(open(json_path, encoding="utf-8"))
    c0 = d["cases"][0]["input"]["hours"]
    base = dict(demand=[h["demand_kwh"] for h in c0], solar=[h["solar_kwh"] for h in c0],
                tariff=[h["tariff_bdt_per_kwh"] for h in c0])

    scn, bat, hrs, notes, dirs, dhours, plans, hplans, baselines = [], [], [], [], [], [], [], [], []
    note_id = dir_id = plan_id = 100
    n_plans = 0
    for i in range(1, count + 1):
        s = make_scenario(i, base)
        # the simplest (idle) plan must be valid, otherwise the case is rejected (the generator checks this itself)
        assert evaluate(s, [0.0] * 24, [0.0] * 24), s.id
        scn.append(f"({q(s.id)}, {q(s.label)}, 'synthetic')")
        b = s.bat
        bat.append(f"({q(s.id)}, {b['capacity']}, {b['initial']}, {b['minimum']}, {b['max_charge']}, {b['max_discharge']})")
        for h in range(24):
            hrs.append(f"({q(s.id)}, {h}, {s.demand[h]}, {s.solar[h]}, {s.tariff[h]})")
        for idx, nt in enumerate(s.notes):
            note_id += 1
            dir_id += 1
            notes.append(f"({note_id}, {q(s.id)}, {idx}, {q(nt['text'])})")
            f = fmt(nt["factor"]) if nt["factor"] is not None else "NULL"
            r = fmt(nt["reserve"]) if nt["reserve"] is not None else "NULL"
            c = fmt(nt["cap"]) if nt["cap"] is not None else "NULL"
            dirs.append(f"({dir_id}, {note_id}, {q(nt['type'])}, {0 if nt['type'] == 'no_op' else 1}, {f}, {r}, {c}, {q(nt['explanation'])})")
            for h in nt["hours"]:
                dhours.append(f"({dir_id}, {h})")
        baselines.append(s.id)
        rows, moved = heuristic(s)
        if rows:
            plan_id += 1
            n_plans += 1
            plans.append(f"({plan_id}, {q(s.id)}, 'tariff_shift_heuristic', "
                         f"{q(f'Heuristic (not optimal): shifts about {fmt(moved)} kWh of battery energy from cheap to expensive tariff hours.')})")
            hplans.append([f"({plan_id}, {h}, {fmt(g)}, {fmt(su)}, {q(a)}, {fmt(k)}, {fmt(e)})" for h, g, su, a, k, e in rows])

    def block(table, cols, values):
        return f"INSERT INTO {table} ({cols}) VALUES\n  " + ",\n  ".join(values) + ";\n\n"

    parts = [
        "-- =====================================================================\n"
        "--  File 5: Synthetic data (auto-generated by tools/gen_synthetic.py)\n"
        f"--  {count} scenarios, English notes, a baseline plan and a heuristic plan for each\n"
        "-- =====================================================================\n"
        "SET NAMES utf8mb4;\nUSE gridwise_db;\nSTART TRANSACTION;\n\n",
        block("scenario", "scenario_id, label, source", scn),
        block("battery_config", "scenario_id, capacity_kwh, initial_energy_kwh, minimum_energy_kwh, max_charge_kwh_per_hour, max_discharge_kwh_per_hour", bat),
        block("hourly_input", "scenario_id, hour_no, demand_kwh, solar_kwh, tariff_bdt_per_kwh", hrs),
        block("operator_note", "note_id, scenario_id, note_index, note_text", notes),
        block("directive", "directive_id, note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh, explanation", dirs),
        block("directive_hour", "directive_id, hour_no", dhours),
        block("plan", "plan_id, scenario_id, plan_name, plan_summary", plans),
    ]
    for rows in hplans:
        parts.append(block("hourly_plan", "plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh", rows))
    parts.append("COMMIT;\n\n-- baseline plans (created through the stored procedure)\n")
    for sid in baselines:
        parts.append(f"CALL sp_create_baseline_plan({q(sid)}, 'baseline_no_battery', @ok, @msg);\n")
    open(out_path, "w", encoding="utf-8").write("".join(parts))
    print(f"wrote {out_path}: {count} scenarios, {len(notes)} notes, {len(dhours)} directive-hours, {n_plans} heuristic plans")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 60)
