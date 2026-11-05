-- =====================================================================
--  File 3: Stored procedures, functions and triggers
--  (run via phpMyAdmin Import, or  mysql -u root < 03_routines_triggers.sql)
-- =====================================================================
SET NAMES utf8mb4;
USE gridwise_db;

DROP TRIGGER   IF EXISTS trg_hplan_bi;
DROP TRIGGER   IF EXISTS trg_hplan_bu;
DROP TRIGGER   IF EXISTS trg_hplan_au;
DROP TRIGGER   IF EXISTS trg_hplan_ad;
DROP TRIGGER   IF EXISTS trg_directive_bi;
DROP TRIGGER   IF EXISTS trg_directive_bu;
DROP PROCEDURE IF EXISTS sp_check_plan_row;
DROP PROCEDURE IF EXISTS sp_check_directive;
DROP PROCEDURE IF EXISTS sp_validate_plan;
DROP PROCEDURE IF EXISTS sp_plan_report;
DROP PROCEDURE IF EXISTS sp_create_baseline_plan;
DROP PROCEDURE IF EXISTS sp_add_directive;
DROP FUNCTION  IF EXISTS fn_plan_cost;

DELIMITER $$

-- ---------------------------------------------------------------------
-- fn_plan_cost : total grid cost (BDT) of one plan
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_plan_cost(p_plan_id INT UNSIGNED)
RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
  DECLARE v_cost DECIMAL(14,2);
  SELECT total_cost_bdt INTO v_cost FROM v_plan_totals WHERE plan_id = p_plan_id;
  RETURN v_cost;
END$$

-- ---------------------------------------------------------------------
-- sp_check_plan_row : checks every rule of one row; on a violation SIGNAL blocks the INSERT/UPDATE.
--   Both triggers (BEFORE INSERT / BEFORE UPDATE) call it, so the logic lives in one place.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_plan_row(
  IN p_plan_id INT UNSIGNED, IN p_hour TINYINT UNSIGNED,
  IN p_grid DECIMAL(10,2),   IN p_solar DECIMAL(10,2),
  IN p_action VARCHAR(10),   IN p_kwh DECIMAL(10,2), IN p_after DECIMAL(10,2))
BEGIN
  DECLARE v_scn      VARCHAR(30);
  DECLARE v_demand, v_eff_solar, v_min_e, v_cap, v_init   DECIMAL(10,2);
  DECLARE v_max_ch, v_max_dis, v_max_grid                  DECIMAL(10,2);
  DECLARE v_no_ch, v_no_dis                                TINYINT;
  DECLARE v_charge, v_discharge, v_before                  DECIMAL(10,2);
  DECLARE v_n_after, v_n_kwh                               DECIMAL(10,2);
  DECLARE v_n_action                                       VARCHAR(10);

  SET v_demand = NULL;
  SELECT scenario_id INTO v_scn FROM plan WHERE plan_id = p_plan_id;

  SELECT c.demand_kwh, c.effective_solar_kwh, c.min_energy_kwh, c.capacity_kwh, c.initial_energy_kwh,
         c.max_charge_kwh_per_hour, c.max_discharge_kwh_per_hour, c.max_grid_kwh, c.no_charge, c.no_discharge
    INTO v_demand, v_eff_solar, v_min_e, v_cap, v_init,
         v_max_ch, v_max_dis, v_max_grid, v_no_ch, v_no_dis
    FROM v_hour_constraints c
   WHERE c.scenario_id = v_scn AND c.hour_no = p_hour;

  IF v_demand IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'hourly_input row not found for this scenario/hour';
  END IF;

  SET v_charge    = IF(p_action = 'charge',    p_kwh, 0);
  SET v_discharge = IF(p_action = 'discharge', p_kwh, 0);

  -- (1) solar: may not use more than the effective solar
  IF p_solar > v_eff_solar + 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: solar_used exceeds effective solar for this hour';
  END IF;

  -- (2) energy balance: grid + solar + discharge = demand + charge
  IF ABS((p_grid + p_solar + v_discharge) - (v_demand + v_charge)) > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: energy balance broken (grid+solar+discharge <> demand+charge)';
  END IF;

  -- (3) hourly rate limits
  IF p_action = 'charge' AND p_kwh > v_max_ch + 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: charge exceeds max_charge_kwh_per_hour';
  END IF;
  IF p_action = 'discharge' AND p_kwh > v_max_dis + 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: discharge exceeds max_discharge_kwh_per_hour';
  END IF;

  -- (4) directives: no_charge / no_discharge / grid cap
  IF v_no_ch = 1 AND v_charge > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'DIRECTIVE: no_charge_window is active in this hour';
  END IF;
  IF v_no_dis = 1 AND v_discharge > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'DIRECTIVE: no_discharge_window is active in this hour';
  END IF;
  IF v_max_grid IS NOT NULL AND p_grid > v_max_grid + 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'DIRECTIVE: max_grid_window cap exceeded in this hour';
  END IF;

  -- (5) battery bounds (including any active reserve) and capacity
  IF p_after < v_min_e - 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: battery energy below active minimum/reserve';
  END IF;
  IF p_after > v_cap + 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: battery energy above capacity';
  END IF;

  -- (6) continuity: this level must follow from the previous hour's final level (initial level for hour 0)
  SET v_before = NULL;
  IF p_hour = 0 THEN
    SET v_before = v_init;
  ELSE
    SELECT energy_after_kwh INTO v_before FROM hourly_plan
     WHERE plan_id = p_plan_id AND hour_no = p_hour - 1;
  END IF;
  IF v_before IS NOT NULL AND ABS(p_after - (v_before + v_charge - v_discharge)) > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: battery transition wrong (energy_after <> before +/- battery_kwh)';
  END IF;

  -- if the next hour's row already exists (UPDATE case) its continuity must still hold
  IF p_hour < 23 THEN
    SET v_n_after = NULL;
    SELECT energy_after_kwh, battery_kwh, battery_action INTO v_n_after, v_n_kwh, v_n_action
      FROM hourly_plan WHERE plan_id = p_plan_id AND hour_no = p_hour + 1;
    IF v_n_after IS NOT NULL AND
       ABS(v_n_after - (p_after + IF(v_n_action = 'charge', v_n_kwh, 0)
                                - IF(v_n_action = 'discharge', v_n_kwh, 0))) > 0.01 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: change breaks the next hour''s battery transition';
    END IF;
  END IF;

  -- (7) end of day: the battery must return to its initial level
  IF p_hour = 23 AND ABS(p_after - v_init) > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'RULE: end-of-day battery energy must equal initial energy';
  END IF;
END$$

-- ---------------------------------------------------------------------
-- hourly_plan triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_hplan_bi BEFORE INSERT ON hourly_plan FOR EACH ROW
BEGIN
  CALL sp_check_plan_row(NEW.plan_id, NEW.hour_no, NEW.grid_kwh, NEW.solar_used_kwh,
                         NEW.battery_action, NEW.battery_kwh, NEW.energy_after_kwh);
END$$

CREATE TRIGGER trg_hplan_bu BEFORE UPDATE ON hourly_plan FOR EACH ROW
BEGIN
  CALL sp_check_plan_row(NEW.plan_id, NEW.hour_no, NEW.grid_kwh, NEW.solar_used_kwh,
                         NEW.battery_action, NEW.battery_kwh, NEW.energy_after_kwh);
END$$

CREATE TRIGGER trg_hplan_au AFTER UPDATE ON hourly_plan FOR EACH ROW
BEGIN
  INSERT INTO plan_audit (plan_id, hour_no, action_type, old_grid_kwh, new_grid_kwh, old_action, new_action)
  VALUES (OLD.plan_id, OLD.hour_no, 'UPDATE', OLD.grid_kwh, NEW.grid_kwh, OLD.battery_action, NEW.battery_action);
END$$

CREATE TRIGGER trg_hplan_ad AFTER DELETE ON hourly_plan FOR EACH ROW
BEGIN
  INSERT INTO plan_audit (plan_id, hour_no, action_type, old_grid_kwh, new_grid_kwh, old_action, new_action)
  VALUES (OLD.plan_id, OLD.hour_no, 'DELETE', OLD.grid_kwh, NULL, OLD.battery_action, NULL);
END$$

-- ---------------------------------------------------------------------
-- directive trigger: a reserve may not exceed battery capacity
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_directive(IN p_note_id INT UNSIGNED, IN p_reserve DECIMAL(10,2))
BEGIN
  DECLARE v_cap DECIMAL(10,2);
  IF p_reserve IS NOT NULL THEN
    SET v_cap = NULL;
    SELECT b.capacity_kwh INTO v_cap
      FROM operator_note n JOIN battery_config b ON b.scenario_id = n.scenario_id
     WHERE n.note_id = p_note_id;
    IF v_cap IS NOT NULL AND p_reserve > v_cap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'GUARDRAIL: reserve exceeds battery capacity';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_directive_bi BEFORE INSERT ON directive FOR EACH ROW
BEGIN
  CALL sp_check_directive(NEW.note_id, NEW.minimum_energy_kwh);
END$$

CREATE TRIGGER trg_directive_bu BEFORE UPDATE ON directive FOR EACH ROW
BEGIN
  CALL sp_check_directive(NEW.note_id, NEW.minimum_energy_kwh);
END$$

-- ---------------------------------------------------------------------
-- sp_validate_plan : full audit of one plan. Returns a single 'VALID' row when nothing is wrong.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_validate_plan(IN p_plan_id INT UNSIGNED)
BEGIN
  DECLARE v_cnt INT;
  SELECT COUNT(*) INTO v_cnt FROM v_plan_violations WHERE plan_id = p_plan_id;
  IF v_cnt = 0 THEN
    SELECT p_plan_id AS plan_id, NULL AS hour_no, 'VALID' AS rule_code, 'all rules satisfied' AS detail;
  ELSE
    SELECT plan_id, hour_no, rule_code, detail
      FROM v_plan_violations WHERE plan_id = p_plan_id
     ORDER BY hour_no, rule_code;
  END IF;
END$$

-- ---------------------------------------------------------------------
-- sp_plan_report : hour-by-hour report + running cost (window function)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_plan_report(IN p_plan_id INT UNSIGNED)
BEGIN
  SELECT r.hour_no, r.tariff_bdt_per_kwh AS tariff, r.demand_kwh, r.solar_kwh, r.effective_solar_kwh,
         r.solar_used_kwh, r.grid_kwh, r.battery_action, r.battery_kwh, r.energy_after_kwh,
         r.hour_cost_bdt,
         SUM(r.hour_cost_bdt) OVER (ORDER BY r.hour_no) AS cumulative_cost_bdt,
         r.no_charge, r.no_discharge, r.max_grid_kwh, r.min_energy_kwh
    FROM v_plan_rows r
   WHERE r.plan_id = p_plan_id
   ORDER BY r.hour_no;
END$$

-- ---------------------------------------------------------------------
-- sp_create_baseline_plan : creates a plan that keeps the battery idle all day (inside a transaction).
--   If a directive makes it invalid the trigger blocks it, and we ROLLBACK and return the reason.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_create_baseline_plan(
  IN p_scenario_id VARCHAR(30), IN p_plan_name VARCHAR(60),
  OUT p_ok TINYINT, OUT p_msg VARCHAR(255))
BEGIN
  DECLARE v_plan_id INT UNSIGNED;
  DECLARE v_hours INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 p_msg = MESSAGE_TEXT;
    ROLLBACK;
    SET p_ok = 0;
  END;

  SET p_ok = 1;
  SET p_msg = 'OK';

  SELECT COUNT(*) INTO v_hours FROM hourly_input WHERE scenario_id = p_scenario_id;
  IF v_hours <> 24 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'scenario must have exactly 24 hourly_input rows';
  END IF;

  START TRANSACTION;
    INSERT INTO plan (scenario_id, plan_name, plan_summary)
    VALUES (p_scenario_id, p_plan_name,
            'Baseline: battery stays idle all day; solar used first, remaining demand from grid.');
    SET v_plan_id = LAST_INSERT_ID();

    INSERT INTO hourly_plan (plan_id, hour_no, grid_kwh, solar_used_kwh, battery_action, battery_kwh, energy_after_kwh)
    SELECT v_plan_id, c.hour_no,
           c.demand_kwh - LEAST(c.effective_solar_kwh, c.demand_kwh),
           LEAST(c.effective_solar_kwh, c.demand_kwh),
           'idle', 0, c.initial_energy_kwh
      FROM v_hour_constraints c
     WHERE c.scenario_id = p_scenario_id
     ORDER BY c.hour_no;
  COMMIT;
END$$

-- ---------------------------------------------------------------------
-- sp_add_directive : the SAFE way to add a directive together with its hours.
--   A trigger cannot see the hours (they live in directive_hour and are inserted AFTER the
--   directive row), so this procedure checks them first and inserts everything in ONE transaction.
--   p_hours is a comma list, e.g. '13,14'. An active directive with no hours is rejected;
--   no_op must have no hours; every hour must be an integer 0..23; duplicates are rejected by the PK.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_add_directive(
  IN p_scenario_id VARCHAR(30), IN p_note_index TINYINT UNSIGNED, IN p_type VARCHAR(30),
  IN p_factor DECIMAL(5,4), IN p_reserve DECIMAL(10,2), IN p_max_grid DECIMAL(10,2),
  IN p_hours VARCHAR(100), IN p_explanation VARCHAR(500))
BEGIN
  DECLARE v_note_id INT UNSIGNED DEFAULT NULL;
  DECLARE v_dir_id  INT UNSIGNED;
  DECLARE v_rest    VARCHAR(100);
  DECLARE v_item    VARCHAR(100);
  DECLARE v_pos     INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_rest = REPLACE(IFNULL(p_hours, ''), ' ', '');

  SELECT note_id INTO v_note_id FROM operator_note
   WHERE scenario_id = p_scenario_id AND note_index = p_note_index;
  IF v_note_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'GUARDRAIL: operator note not found for this scenario/note_index';
  END IF;
  IF p_type = 'no_op' AND v_rest <> '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'GUARDRAIL: no_op must not have hours';
  END IF;
  IF p_type <> 'no_op' AND v_rest = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'GUARDRAIL: an active directive needs at least one hour';
  END IF;

  START TRANSACTION;
    INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh, explanation)
    VALUES (v_note_id, p_type, IF(p_type = 'no_op', 0, 1), p_factor, p_reserve, p_max_grid, p_explanation);
    SET v_dir_id = LAST_INSERT_ID();

    WHILE v_rest <> '' DO
      SET v_pos = LOCATE(',', v_rest);
      IF v_pos = 0 THEN
        SET v_item = v_rest;  SET v_rest = '';
      ELSE
        SET v_item = LEFT(v_rest, v_pos - 1);  SET v_rest = SUBSTRING(v_rest, v_pos + 1);
      END IF;
      IF v_item NOT REGEXP '^[0-9]{1,2}$' OR CAST(v_item AS UNSIGNED) > 23 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'GUARDRAIL: every hour must be an integer from 0 to 23';
      END IF;
      INSERT INTO directive_hour (directive_id, hour_no) VALUES (v_dir_id, CAST(v_item AS UNSIGNED));
    END WHILE;
  COMMIT;
END$$

DELIMITER ;