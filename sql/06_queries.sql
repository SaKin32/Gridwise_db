-- =====================================================================
--  File 6: Demo queries (JOIN, GROUP BY, HAVING, subquery, CTE, window function, EXPLAIN)
--  Run each query separately and inspect the result (in phpMyAdmin, select the query and press Go)
-- =====================================================================
SET NAMES utf8mb4;
USE gridwise_db;

-- Q01 | VIEW + ORDER BY | summary of all scenarios
SELECT scenario_id, label, source, notes_count, active_directives, plans_count, total_demand_kwh, peak_tariff
FROM v_scenario_overview
ORDER BY source, scenario_id
LIMIT 20;

-- Q02 | GROUP BY + aggregate | averages by source (sample/synthetic)
SELECT source, COUNT(*) AS scenarios, ROUND(AVG(total_demand_kwh),1) AS avg_demand_kwh,
       ROUND(AVG(total_solar_kwh),1) AS avg_solar_kwh, ROUND(AVG(notes_count),2) AS avg_notes,
       ROUND(AVG(active_directives),2) AS avg_active_directives
FROM v_scenario_overview
GROUP BY source;

-- Q03 | JOIN + conditional aggregation | reference vs baseline cost side by side (sample cases only)
SELECT s.scenario_id,
       MAX(CASE WHEN t.plan_name = 'reference_optimal'   THEN t.total_cost_bdt END) AS reference_cost,
       MAX(CASE WHEN t.plan_name = 'baseline_no_battery' THEN t.total_cost_bdt END) AS baseline_cost,
       ROUND(MAX(CASE WHEN t.plan_name = 'baseline_no_battery' THEN t.total_cost_bdt END)
           - MAX(CASE WHEN t.plan_name = 'reference_optimal'   THEN t.total_cost_bdt END), 2) AS saved_bdt
FROM scenario s
JOIN v_plan_totals t ON t.scenario_id = s.scenario_id
WHERE s.source = 'public_sample'
GROUP BY s.scenario_id
ORDER BY s.scenario_id;

-- Q04 | GROUP BY plan_name | average savings by plan type (compared with the no-battery cost)
--      (Caution: the plan types cover different scenario sets, so do not compare types directly; for same-scenario comparison see Q03/Q05)
SELECT plan_name, COUNT(*) AS plans, ROUND(AVG(savings_pct),2) AS avg_saving_pct,
       ROUND(MIN(savings_pct),2) AS min_pct, ROUND(MAX(savings_pct),2) AS max_pct
FROM v_plan_comparison
GROUP BY plan_name
ORDER BY avg_saving_pct DESC;

-- Q05 | window: RANK() OVER (PARTITION BY) | which plan is cheapest within each scenario
SELECT scenario_id, plan_name, total_cost_bdt,
       RANK() OVER (PARTITION BY scenario_id ORDER BY total_cost_bdt) AS cost_rank
FROM v_plan_totals
WHERE scenario_id IN ('SAMPLE-01','SAMPLE-02','SAMPLE-03','SYN-001','SYN-002')
ORDER BY scenario_id, cost_rank;

-- Q06 | window: ROW_NUMBER | the hour with the highest grid usage in each reference plan
SELECT scenario_id, plan_name, hour_no AS peak_hour, grid_kwh AS peak_grid_kwh, tariff_bdt_per_kwh
FROM (SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.plan_id ORDER BY r.grid_kwh DESC, r.hour_no) AS rn
        FROM v_plan_rows r WHERE r.plan_name = 'reference_optimal') x
WHERE rn = 1
ORDER BY scenario_id;

-- Q07 | ORDER BY + LIMIT | the 5 most expensive (scenario, hour) pairs
SELECT scenario_id, hour_no, tariff_bdt_per_kwh
FROM hourly_input
ORDER BY tariff_bdt_per_kwh DESC, scenario_id, hour_no
LIMIT 5;

-- Q08 | LEFT JOIN + GROUP BY | count per directive type (shows types with 0 uses too)
SELECT dt.type_code, COUNT(d.directive_id) AS used_times
FROM directive_type dt
LEFT JOIN directive d ON d.type_code = dt.type_code
GROUP BY dt.type_code
ORDER BY used_times DESC;

-- Q09 | HAVING | scenarios with 2 or more active directives
SELECT scenario_id, active_directives, notes_count
FROM v_scenario_overview
WHERE active_directives >= 2
ORDER BY active_directives DESC, scenario_id
LIMIT 15;

-- Q10 | CASE + aggregate | distractor (no_op) vs relevant notes, counted per directive type
SELECT d.type_code,
       CASE WHEN d.type_code = 'no_op' THEN 'distractor' ELSE 'relevant' END AS note_kind,
       COUNT(*) AS notes,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM operator_note n
JOIN directive d ON d.note_id = n.note_id
GROUP BY d.type_code, note_kind
ORDER BY notes DESC;

-- Q11 | JOIN 3 tables + GROUP_CONCAT | total hours blocked/changed per type
SELECT d.type_code, COUNT(DISTINCT d.directive_id) AS directives, COUNT(dh.hour_no) AS blocked_hours,
       ROUND(COUNT(dh.hour_no) / COUNT(DISTINCT d.directive_id), 2) AS avg_window_hours
FROM directive d
JOIN directive_hour dh ON dh.directive_id = d.directive_id
GROUP BY d.type_code
ORDER BY blocked_hours DESC;

-- Q12 | VIEW + HAVING | how many kWh of solar were lost to solar_reduction
SELECT scenario_id, ROUND(SUM(solar_kwh - effective_solar_kwh), 2) AS solar_lost_kwh
FROM v_hour_constraints
GROUP BY scenario_id
HAVING solar_lost_kwh > 0
ORDER BY solar_lost_kwh DESC
LIMIT 10;

-- Q13 | CASE + SUM | how much the battery charged/discharged per plan type
SELECT plan_name,
       ROUND(SUM(CASE WHEN battery_action = 'charge'    THEN battery_kwh ELSE 0 END), 1) AS total_charged_kwh,
       ROUND(SUM(CASE WHEN battery_action = 'discharge' THEN battery_kwh ELSE 0 END), 1) AS total_discharged_kwh,
       SUM(battery_action = 'idle') AS idle_hours
FROM v_plan_rows
GROUP BY plan_name;

-- Q14 | CTE + RANK | how much each plan discharged in the 3 most expensive hours (a smart plan discharges more)
WITH ranked_hours AS (
  SELECT scenario_id, hour_no,
         RANK() OVER (PARTITION BY scenario_id ORDER BY tariff_bdt_per_kwh DESC) AS tariff_rank
  FROM hourly_input
)
SELECT r.plan_name,
       ROUND(SUM(CASE WHEN r.battery_action = 'discharge' THEN r.battery_kwh ELSE 0 END), 1) AS discharged_in_top3_hours_kwh
FROM v_plan_rows r
JOIN ranked_hours h ON h.scenario_id = r.scenario_id AND h.hour_no = r.hour_no
WHERE h.tariff_rank <= 3
GROUP BY r.plan_name
ORDER BY discharged_in_top3_hours_kwh DESC;

-- Q15 | window: LAG | largest hour-to-hour jump in grid usage (SAMPLE-01 reference)
SELECT hour_no, grid_kwh, LAG(grid_kwh) OVER (ORDER BY hour_no) AS prev_grid_kwh,
       grid_kwh - LAG(grid_kwh) OVER (ORDER BY hour_no)         AS change_kwh
FROM v_plan_rows
WHERE scenario_id = 'SAMPLE-01' AND plan_name = 'reference_optimal'
ORDER BY ABS(grid_kwh - LAG(grid_kwh) OVER (ORDER BY hour_no)) DESC
LIMIT 5;

-- Q16 | window: running SUM | cumulative cost per hour for SAMPLE-01
SELECT hour_no, grid_kwh, tariff_bdt_per_kwh, hour_cost_bdt,
       SUM(hour_cost_bdt) OVER (ORDER BY hour_no) AS cumulative_cost_bdt
FROM v_plan_rows
WHERE scenario_id = 'SAMPLE-01' AND plan_name = 'reference_optimal'
ORDER BY hour_no;

-- Q17 | subquery | reference plans costing more than average
SELECT scenario_id, total_cost_bdt
FROM v_plan_totals
WHERE plan_name = 'reference_optimal'
  AND total_cost_bdt > (SELECT AVG(total_cost_bdt) FROM v_plan_totals WHERE plan_name = 'reference_optimal')
ORDER BY total_cost_bdt DESC;

-- Q18 | NOT EXISTS | scenarios for which the "battery idle" baseline could not be built (because of directives)
SELECT s.scenario_id, s.label,
       (SELECT GROUP_CONCAT(d.type_code SEPARATOR ', ')
          FROM operator_note n JOIN directive d ON d.note_id = n.note_id
         WHERE n.scenario_id = s.scenario_id AND d.applies = 1) AS active_directive_types
FROM scenario s
WHERE NOT EXISTS (SELECT 1 FROM plan p WHERE p.scenario_id = s.scenario_id AND p.plan_name = 'baseline_no_battery');

-- Q19 | FULLTEXT search | find notes about "battery" and "maintenance"
SELECT scenario_id, note_index, note_text
FROM operator_note
WHERE MATCH(note_text) AGAINST('battery charger maintenance' IN NATURAL LANGUAGE MODE)
LIMIT 5;

-- Q20 | LIKE search + JOIN | notes mentioning 'solar' or 'maintenance' with their directive type
SELECT n.scenario_id, n.note_text, d.type_code, v.hours_list, v.parameter_value
FROM operator_note n
JOIN directive d          ON d.note_id = n.note_id
JOIN v_directive_summary v ON v.directive_id = d.directive_id
WHERE n.note_text LIKE '%solar%' OR n.note_text LIKE '%maintenance%'
ORDER BY n.scenario_id
LIMIT 8;

-- Q21 | CASE bucketing + window SUM | grid usage and cost share of the reference plan by tariff band (off-peak/shoulder/peak)
SELECT band, ROUND(SUM(grid_kwh),1) AS grid_kwh, ROUND(SUM(hour_cost_bdt),0) AS cost_bdt,
       ROUND(100 * SUM(hour_cost_bdt) / SUM(SUM(hour_cost_bdt)) OVER (), 1) AS cost_share_pct
FROM (SELECT grid_kwh, hour_cost_bdt,
             CASE WHEN tariff_bdt_per_kwh < 10 THEN '1-off-peak (<10)'
                  WHEN tariff_bdt_per_kwh < 20 THEN '2-shoulder (10-19)'
                  ELSE '3-peak (>=20)' END AS band
        FROM v_plan_rows WHERE plan_name = 'reference_optimal') x
GROUP BY band
ORDER BY band;

-- Q22 | Audit 1 | does any plan break the rules? (empty result = all fine)
SELECT * FROM v_plan_violations;

-- Q23 | Audit 2 | is the battery level at hour 23 equal to initial (manual check via JOIN; empty = fine)
SELECT p.plan_id, p.plan_name, hp.energy_after_kwh, b.initial_energy_kwh
FROM plan p
JOIN hourly_plan hp   ON hp.plan_id = p.plan_id AND hp.hour_no = 23
JOIN battery_config b ON b.scenario_id = p.scenario_id
WHERE ABS(hp.energy_after_kwh - b.initial_energy_kwh) > 0.01;

-- Q24 | Audit 3 | structural problems in directives (empty = fine)
SELECT * FROM v_directive_issues;

-- Q25 | stored function | cost computed directly with fn_plan_cost
SELECT plan_id, scenario_id, fn_plan_cost(plan_id) AS cost_by_function FROM plan WHERE plan_id IN (1, 2, 3);

-- Q26 | stored procedure | full plan validation and hourly report
CALL sp_validate_plan(5);
CALL sp_plan_report(5);

-- ---------------------------------------------------------------------
-- Index demo: EXPLAIN before and after (idx_input_tariff)
-- ---------------------------------------------------------------------
EXPLAIN SELECT scenario_id, hour_no FROM hourly_input WHERE tariff_bdt_per_kwh >= 30;   -- index present: type=range

ALTER TABLE hourly_input DROP INDEX idx_input_tariff;
EXPLAIN SELECT scenario_id, hour_no FROM hourly_input WHERE tariff_bdt_per_kwh >= 30;   -- index absent: type=ALL (full table scan)

CREATE INDEX idx_input_tariff ON hourly_input (tariff_bdt_per_kwh);                     -- recreate the index
