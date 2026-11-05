-- =====================================================================
--  File 8: Transaction + Trigger + Audit demo (ends with ROLLBACK, so the real data stays intact)
--  Run it all at once in the mysql client; in phpMyAdmin it is better to run step by step
-- =====================================================================
SET NAMES utf8mb4;
USE gridwise_db;

-- Step 1: start the transaction
START TRANSACTION;

-- Step 2: hour 9 of the SAMPLE-01 baseline plan: solar 90 -> 80, grid 75 -> 85 (energy balance is preserved, so the trigger accepts it)
UPDATE hourly_plan hp JOIN plan p ON p.plan_id = hp.plan_id
   SET hp.solar_used_kwh = 80, hp.grid_kwh = 85
 WHERE p.scenario_id = 'SAMPLE-01' AND p.plan_name = 'baseline_no_battery' AND hp.hour_no = 9;

-- Step 3: the AFTER UPDATE trigger logged the change in plan_audit
SELECT audit_id, plan_id, hour_no, action_type, old_grid_kwh, new_grid_kwh FROM plan_audit;

-- Step 4: the cost changed (from the view)
SELECT plan_name, total_cost_bdt FROM v_plan_totals WHERE scenario_id = 'SAMPLE-01';

-- Step 5: set a SAVEPOINT, then try an invalid (rule-breaking) change
SAVEPOINT before_bad_edit;
--   Uncomment the lines below (remove --) and the trigger will raise an error: "RULE: energy balance broken ..."
-- UPDATE hourly_plan hp JOIN plan p ON p.plan_id = hp.plan_id
--    SET hp.grid_kwh = 500 WHERE p.scenario_id = 'SAMPLE-01' AND p.plan_name = 'baseline_no_battery' AND hp.hour_no = 9;
ROLLBACK TO SAVEPOINT before_bad_edit;

-- Step 6: cancel everything
ROLLBACK;

-- Step 7: verify: audit is empty, cost is as before
SELECT COUNT(*) AS audit_rows_after_rollback FROM plan_audit;
SELECT plan_name, total_cost_bdt FROM v_plan_totals WHERE scenario_id = 'SAMPLE-01';
