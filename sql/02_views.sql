-- =====================================================================
--  File 2: Views
--  Views keep "rule application + calculation" in one place so queries stay short
-- =====================================================================
SET NAMES utf8mb4;
USE gridwise_db;

-- 1. every active directive hour as its own row (directive + directive_hour + note)
CREATE OR REPLACE VIEW v_directive_hours AS
SELECT n.scenario_id, d.directive_id, d.type_code,
       d.factor, d.minimum_energy_kwh, d.max_grid_kwh, dh.hour_no
FROM directive d
JOIN operator_note  n  ON n.note_id = d.note_id
JOIN directive_hour dh ON dh.directive_id = d.directive_id
WHERE d.applies = 1;

-- 2. the "effective rules" of every (scenario, hour) after all directives are applied
--    solar_reduction -> effective_solar (several overlap: strictest factor = MIN)
--    reserve         -> max(base min, directive min)
--    grid cap        -> several overlap: MIN
CREATE OR REPLACE VIEW v_hour_constraints AS
SELECT h.scenario_id, h.hour_no, h.demand_kwh, h.solar_kwh, h.tariff_bdt_per_kwh,
       ROUND(h.solar_kwh * COALESCE(
         (SELECT MIN(x.factor) FROM v_directive_hours x
           WHERE x.scenario_id = h.scenario_id AND x.hour_no = h.hour_no
             AND x.type_code = 'solar_reduction'), 1), 2)                       AS effective_solar_kwh,
       GREATEST(b.minimum_energy_kwh, COALESCE(
         (SELECT MAX(x.minimum_energy_kwh) FROM v_directive_hours x
           WHERE x.scenario_id = h.scenario_id AND x.hour_no = h.hour_no
             AND x.type_code = 'minimum_battery_reserve'), 0))                  AS min_energy_kwh,
       EXISTS(SELECT 1 FROM v_directive_hours x
               WHERE x.scenario_id = h.scenario_id AND x.hour_no = h.hour_no
                 AND x.type_code = 'no_charge_window')                          AS no_charge,
       EXISTS(SELECT 1 FROM v_directive_hours x
               WHERE x.scenario_id = h.scenario_id AND x.hour_no = h.hour_no
                 AND x.type_code = 'no_discharge_window')                       AS no_discharge,
       (SELECT MIN(x.max_grid_kwh) FROM v_directive_hours x
         WHERE x.scenario_id = h.scenario_id AND x.hour_no = h.hour_no
           AND x.type_code = 'max_grid_window')                                 AS max_grid_kwh,
       b.capacity_kwh, b.initial_energy_kwh,
       b.max_charge_kwh_per_hour, b.max_discharge_kwh_per_hour
FROM hourly_input h
JOIN battery_config b ON b.scenario_id = h.scenario_id;

-- 3. every plan row + the effective rules of that hour + battery level of the previous hour
CREATE OR REPLACE VIEW v_plan_rows AS
SELECT p.plan_id, p.scenario_id, p.plan_name, hp.hour_no,
       hp.grid_kwh, hp.solar_used_kwh, hp.battery_action, hp.battery_kwh, hp.energy_after_kwh,
       CASE hp.battery_action WHEN 'charge'    THEN hp.battery_kwh ELSE 0 END AS charge_kwh,
       CASE hp.battery_action WHEN 'discharge' THEN hp.battery_kwh ELSE 0 END AS discharge_kwh,
       c.demand_kwh, c.solar_kwh, c.tariff_bdt_per_kwh, c.effective_solar_kwh,
       c.min_energy_kwh, c.no_charge, c.no_discharge, c.max_grid_kwh,
       c.capacity_kwh, c.initial_energy_kwh,
       c.max_charge_kwh_per_hour, c.max_discharge_kwh_per_hour,
       COALESCE(prev.energy_after_kwh, c.initial_energy_kwh) AS energy_before_kwh,
       hp.grid_kwh * c.tariff_bdt_per_kwh                    AS hour_cost_bdt
FROM hourly_plan hp
JOIN plan p                 ON p.plan_id = hp.plan_id
JOIN v_hour_constraints c   ON c.scenario_id = p.scenario_id AND c.hour_no = hp.hour_no
LEFT JOIN hourly_plan prev  ON prev.plan_id = hp.plan_id AND prev.hour_no + 1 = hp.hour_no;

-- 4. plan totals: total_grid, total_cost, peak (derived, so never stored)
CREATE OR REPLACE VIEW v_plan_totals AS
SELECT p.plan_id, p.scenario_id, p.plan_name,
       COUNT(*)                                            AS hours_count,
       ROUND(SUM(hp.grid_kwh), 2)                          AS total_grid_kwh,
       ROUND(SUM(hp.grid_kwh * hi.tariff_bdt_per_kwh), 2)  AS total_cost_bdt,
       MAX(hp.grid_kwh)                                    AS peak_grid_kwh
FROM plan p
JOIN hourly_plan hp ON hp.plan_id = p.plan_id
JOIN hourly_input hi ON hi.scenario_id = p.scenario_id AND hi.hour_no = hp.hour_no
GROUP BY p.plan_id, p.scenario_id, p.plan_name;

-- 5. violation audit: any row returned is a problem; an empty result means the plan is valid (tolerance 0.01)
CREATE OR REPLACE VIEW v_plan_violations AS
SELECT plan_id, scenario_id, hour_no, 'SOLAR_EXCEEDS_AVAILABLE' AS rule_code,
       CONCAT('solar_used=', solar_used_kwh, ' > effective_solar=', effective_solar_kwh) AS detail
FROM v_plan_rows WHERE solar_used_kwh > effective_solar_kwh + 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'ENERGY_BALANCE',
       CONCAT('grid+solar+discharge=', grid_kwh + solar_used_kwh + discharge_kwh,
              ' but demand+charge=', demand_kwh + charge_kwh)
FROM v_plan_rows
WHERE ABS((grid_kwh + solar_used_kwh + discharge_kwh) - (demand_kwh + charge_kwh)) > 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'CHARGE_RATE_EXCEEDED',
       CONCAT('charge=', battery_kwh, ' > max=', max_charge_kwh_per_hour)
FROM v_plan_rows WHERE battery_action = 'charge' AND battery_kwh > max_charge_kwh_per_hour + 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'DISCHARGE_RATE_EXCEEDED',
       CONCAT('discharge=', battery_kwh, ' > max=', max_discharge_kwh_per_hour)
FROM v_plan_rows WHERE battery_action = 'discharge' AND battery_kwh > max_discharge_kwh_per_hour + 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'NO_CHARGE_WINDOW_BROKEN',
       CONCAT('charging ', battery_kwh, ' kWh in a no-charge hour')
FROM v_plan_rows WHERE no_charge = 1 AND battery_action = 'charge' AND battery_kwh > 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'NO_DISCHARGE_WINDOW_BROKEN',
       CONCAT('discharging ', battery_kwh, ' kWh in a no-discharge hour')
FROM v_plan_rows WHERE no_discharge = 1 AND battery_action = 'discharge' AND battery_kwh > 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'GRID_CAP_EXCEEDED',
       CONCAT('grid=', grid_kwh, ' > cap=', max_grid_kwh)
FROM v_plan_rows WHERE max_grid_kwh IS NOT NULL AND grid_kwh > max_grid_kwh + 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'ENERGY_BELOW_MINIMUM',
       CONCAT('energy_after=', energy_after_kwh, ' < min=', min_energy_kwh)
FROM v_plan_rows WHERE energy_after_kwh < min_energy_kwh - 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'ENERGY_ABOVE_CAPACITY',
       CONCAT('energy_after=', energy_after_kwh, ' > capacity=', capacity_kwh)
FROM v_plan_rows WHERE energy_after_kwh > capacity_kwh + 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'BATTERY_TRANSITION_WRONG',
       CONCAT('before=', energy_before_kwh, ' ', battery_action, ' ', battery_kwh, ' but after=', energy_after_kwh)
FROM v_plan_rows
WHERE ABS(energy_after_kwh - (energy_before_kwh + charge_kwh - discharge_kwh)) > 0.01
UNION ALL
SELECT plan_id, scenario_id, hour_no, 'END_OF_DAY_NEUTRALITY',
       CONCAT('final=', energy_after_kwh, ' but initial=', initial_energy_kwh)
FROM v_plan_rows WHERE hour_no = 23 AND ABS(energy_after_kwh - initial_energy_kwh) > 0.01
UNION ALL
SELECT p.plan_id, p.scenario_id, NULL, 'INCOMPLETE_PLAN',
       CONCAT('plan has ', (SELECT COUNT(*) FROM hourly_plan x WHERE x.plan_id = p.plan_id), ' hours, expected 24')
FROM plan p
WHERE (SELECT COUNT(*) FROM hourly_plan x WHERE x.plan_id = p.plan_id) <> 24;

-- 6. validity summary of every plan
-- starts from table plan + LEFT JOIN, so a plan with 0 hourly rows is still listed (as INVALID)
CREATE OR REPLACE VIEW v_plan_status AS
SELECT p.plan_id, p.scenario_id, p.plan_name, t.total_cost_bdt,
       (SELECT COUNT(*) FROM v_plan_violations v WHERE v.plan_id = p.plan_id) AS violation_count,
       CASE WHEN (SELECT COUNT(*) FROM v_plan_violations v WHERE v.plan_id = p.plan_id) = 0
            THEN 'VALID' ELSE 'INVALID' END AS status
FROM plan p
LEFT JOIN v_plan_totals t ON t.plan_id = p.plan_id;

-- 7. compact directive view (note + type + parameter + list of hours)
CREATE OR REPLACE VIEW v_directive_summary AS
SELECT n.scenario_id, n.note_index, n.note_text, d.directive_id, d.type_code, d.applies,
       COALESCE(CAST(d.factor AS CHAR), CAST(d.minimum_energy_kwh AS CHAR),
                CAST(d.max_grid_kwh AS CHAR))                          AS parameter_value,
       (SELECT GROUP_CONCAT(dh.hour_no ORDER BY dh.hour_no SEPARATOR ',')
          FROM directive_hour dh WHERE dh.directive_id = d.directive_id) AS hours_list,
       d.explanation
FROM operator_note n
LEFT JOIN directive d ON d.note_id = n.note_id;

-- 8. structural directive problems (rules CHECK cannot catch because they span several tables)
CREATE OR REPLACE VIEW v_directive_issues AS
SELECT s.scenario_id, s.directive_id, 'ACTIVE_DIRECTIVE_WITHOUT_HOURS' AS issue
FROM v_directive_summary s
WHERE s.applies = 1 AND s.hours_list IS NULL
UNION ALL
SELECT s.scenario_id, s.directive_id, 'NO_OP_HAS_HOURS'
FROM v_directive_summary s
WHERE s.type_code = 'no_op' AND s.hours_list IS NOT NULL
UNION ALL
SELECT s.scenario_id, s.directive_id, 'NOTE_WITHOUT_DIRECTIVE'
FROM v_directive_summary s
WHERE s.directive_id IS NULL
UNION ALL
SELECT n.scenario_id, d.directive_id, 'RESERVE_ABOVE_CAPACITY'
FROM directive d
JOIN operator_note n  ON n.note_id = d.note_id
JOIN battery_config b ON b.scenario_id = n.scenario_id
WHERE d.minimum_energy_kwh > b.capacity_kwh;

-- 9. scenario overview
CREATE OR REPLACE VIEW v_scenario_overview AS
SELECT s.scenario_id, s.label, s.source,
       (SELECT COUNT(*) FROM hourly_input h WHERE h.scenario_id = s.scenario_id)        AS hours_count,
       (SELECT ROUND(SUM(h.demand_kwh),2) FROM hourly_input h WHERE h.scenario_id = s.scenario_id) AS total_demand_kwh,
       (SELECT ROUND(SUM(h.solar_kwh),2)  FROM hourly_input h WHERE h.scenario_id = s.scenario_id) AS total_solar_kwh,
       (SELECT MAX(h.tariff_bdt_per_kwh)  FROM hourly_input h WHERE h.scenario_id = s.scenario_id) AS peak_tariff,
       (SELECT COUNT(*) FROM operator_note n WHERE n.scenario_id = s.scenario_id)       AS notes_count,
       (SELECT COUNT(*) FROM operator_note n JOIN directive d ON d.note_id = n.note_id
         WHERE n.scenario_id = s.scenario_id AND d.applies = 1)                         AS active_directives,
       (SELECT COUNT(*) FROM plan p WHERE p.scenario_id = s.scenario_id)                AS plans_count
FROM scenario s;

-- 10. hypothetical "no battery" cost (comparison baseline): grid = demand - used solar
CREATE OR REPLACE VIEW v_no_battery_cost AS
SELECT c.scenario_id,
       ROUND(SUM((c.demand_kwh - LEAST(c.effective_solar_kwh, c.demand_kwh)) * c.tariff_bdt_per_kwh), 2) AS no_battery_cost_bdt
FROM v_hour_constraints c
GROUP BY c.scenario_id;

-- 11. plan cost versus the "no battery" cost: how much money is saved
CREATE OR REPLACE VIEW v_plan_comparison AS
SELECT t.plan_id, t.scenario_id, t.plan_name, t.total_grid_kwh, t.total_cost_bdt, t.peak_grid_kwh,
       nb.no_battery_cost_bdt,
       ROUND(nb.no_battery_cost_bdt - t.total_cost_bdt, 2)                              AS savings_bdt,
       ROUND(100 * (nb.no_battery_cost_bdt - t.total_cost_bdt) / nb.no_battery_cost_bdt, 2) AS savings_pct
FROM v_plan_totals t
JOIN v_no_battery_cost nb ON nb.scenario_id = t.scenario_id;