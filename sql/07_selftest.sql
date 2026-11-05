-- =====================================================================
--  File 7: Self-test (verify that triggers and constraints really work)
--  Usage:  CALL sp_selftest();   (all tests should PASS; ends with ROLLBACK, so data is unchanged)
-- =====================================================================
SET NAMES utf8mb4;
USE gridwise_db;
DROP PROCEDURE IF EXISTS sp_selftest;
DELIMITER $$
CREATE PROCEDURE sp_selftest()
BEGIN
  DECLARE v_err VARCHAR(255);
  DECLARE p1, p2, p3, p4, p5 INT UNSIGNED;

  DROP TEMPORARY TABLE IF EXISTS selftest_results;
  CREATE TEMPORARY TABLE selftest_results (
    test_no INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(120), expected VARCHAR(80), actual VARCHAR(255), verdict VARCHAR(4));

  START TRANSACTION;
  INSERT INTO plan (scenario_id, plan_name) VALUES ('SAMPLE-01', '__selftest__'); SET p1 = LAST_INSERT_ID();
  INSERT INTO plan (scenario_id, plan_name) VALUES ('SAMPLE-02', '__selftest__'); SET p2 = LAST_INSERT_ID();
  INSERT INTO plan (scenario_id, plan_name) VALUES ('SAMPLE-03', '__selftest__'); SET p3 = LAST_INSERT_ID();
  INSERT INTO plan (scenario_id, plan_name) VALUES ('SAMPLE-04', '__selftest__'); SET p4 = LAST_INSERT_ID();
  INSERT INTO plan (scenario_id, plan_name) VALUES ('SAMPLE-05', '__selftest__'); SET p5 = LAST_INSERT_ID();

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 0, 90, 0, 'idle', 0, 110);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('valid row is accepted (SAMPLE-01, hour 0, idle)', 'no error (accepted)', IFNULL(v_err, '(no error)'), IF(v_err IS NULL, 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 1, 85, 0, 'idle', 0, 100);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('continuity: rejected if it does not match the previous hour', 'error: transition wrong', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%transition wrong%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 12, 5, 180, 'idle', 0, 110);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('solar_reduction: using more than the reduced solar is rejected', 'error: solar_used exceeds', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%solar_used exceeds%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 0, 80, 0, 'idle', 0, 110);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when energy balance is broken', 'error: energy balance', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%energy balance%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 0, 150, 0, 'charge', 60, 170);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when charge rate limit is exceeded', 'error: charge exceeds', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%charge exceeds%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 0, 30, 0, 'discharge', 60, 50);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when discharge rate limit is exceeded', 'error: discharge exceeds', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%discharge exceeds%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 3, 130, 0, 'charge', 50, 230);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when battery goes above capacity', 'error: above capacity', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%above capacity%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 3, 40, 0, 'discharge', 40, 30);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when battery goes below the minimum', 'error: below active minimum', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%below active minimum%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 23, 105, 0, 'idle', 0, 100);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('rejected when battery does not return to initial in the last hour', 'error: end-of-day', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%end-of-day%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p2, 2, 145, 0, 'charge', 55, 125);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('no_charge_window: charging in a forbidden hour is rejected', 'error: no_charge_window', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%no_charge_window%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p4, 18, 165, 0, 'discharge', 50, 100);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('no_discharge_window: discharging in a forbidden hour is rejected', 'error: no_discharge_window', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%no_discharge_window%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p5, 18, 205, 0, 'idle', 0, 120);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('max_grid_window: rejected when the grid cap is exceeded', 'error: max_grid_window', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%max_grid_window%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p3, 18, 155, 0, 'discharge', 50, 70);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('minimum_battery_reserve: rejected when going below the reserve', 'error: below active minimum', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%below active minimum%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    VALUES (p1, 0, 90, 0, 'idle', 10, 110);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('CHECK: battery_kwh > 0 while idle is rejected', 'error: ck_hplan_idle', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%ck_hplan_idle%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO operator_note (scenario_id, note_index, note_text) VALUES ('SAMPLE-01', 2, 'selftest note');
    INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh)
    VALUES (LAST_INSERT_ID(), 'minimum_battery_reserve', 1, NULL, 999, NULL);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('guardrail: rejected when reserve exceeds capacity', 'error: reserve exceeds', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%reserve exceeds%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO operator_note (scenario_id, note_index, note_text) VALUES ('SAMPLE-02', 1, 'selftest note');
    INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh)
    VALUES (LAST_INSERT_ID(), 'solar_reduction', 1, 1.5, NULL, NULL);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('CHECK: solar factor above 1 is rejected', 'error: ck_directive_factor', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%ck_directive_factor%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO operator_note (scenario_id, note_index, note_text) VALUES ('SAMPLE-02', 2, 'selftest note');
    INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh)
    VALUES (LAST_INSERT_ID(), 'no_op', 1, NULL, NULL, NULL);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('CHECK: applies=1 on no_op is rejected', 'error: ck_directive_applies', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%ck_directive_applies%', 'PASS', 'FAIL'));

  SET v_err = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    INSERT INTO operator_note (scenario_id, note_index, note_text) VALUES ('SAMPLE-03', 1, 'selftest note');
    INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh)
    VALUES (LAST_INSERT_ID(), 'no_charge_window', 1, 0.5, NULL, NULL);
  END;
  INSERT INTO selftest_results (test_name, expected, actual, verdict)
  VALUES ('CHECK: giving a factor to no_charge_window is rejected', 'error: ck_directive_factor', IFNULL(v_err, '(no error)'), IF(v_err LIKE '%ck_directive_factor%', 'PASS', 'FAIL'));

  -- show results first, then ROLLBACK (if the temp table is InnoDB, ROLLBACK also removes its rows)
  SELECT test_no, test_name, verdict, expected, actual FROM selftest_results ORDER BY test_no;
  SELECT SUM(verdict = 'PASS') AS passed, SUM(verdict = 'FAIL') AS failed, COUNT(*) AS total FROM selftest_results;
  ROLLBACK;
END$$
DELIMITER ;

CALL sp_selftest();
