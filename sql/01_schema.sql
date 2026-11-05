-- =====================================================================
--  GridWise Database Project  |  File 1: Schema (tables, keys, constraints, indexes)
--  Target: XAMPP MySQL / MariaDB (10.4+); also runs on MySQL 8
--  How to run: phpMyAdmin > Import, or  mysql -u root < 01_schema.sql
-- =====================================================================
SET NAMES utf8mb4;
CREATE DATABASE IF NOT EXISTS gridwise_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE gridwise_db;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS plan_audit;
DROP TABLE IF EXISTS hourly_plan;
DROP TABLE IF EXISTS plan;
DROP TABLE IF EXISTS directive_hour;
DROP TABLE IF EXISTS directive;
DROP TABLE IF EXISTS directive_type;
DROP TABLE IF EXISTS operator_note;
DROP TABLE IF EXISTS hourly_input;
DROP TABLE IF EXISTS battery_config;
DROP TABLE IF EXISTS scenario;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 1. scenario : one 24-hour case (scenario_id from the JSON)
-- ---------------------------------------------------------------------
CREATE TABLE scenario (
  scenario_id  VARCHAR(30)  NOT NULL,
  label        VARCHAR(120) NOT NULL,
  source       ENUM('public_sample','synthetic','user') NOT NULL DEFAULT 'user',
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (scenario_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 2. battery_config : 1:1 relationship with scenario
--    (kept as a separate table so battery data is its own entity)
-- ---------------------------------------------------------------------
CREATE TABLE battery_config (
  scenario_id                 VARCHAR(30)   NOT NULL,
  capacity_kwh                DECIMAL(10,2) NOT NULL,
  initial_energy_kwh          DECIMAL(10,2) NOT NULL,
  minimum_energy_kwh          DECIMAL(10,2) NOT NULL,
  max_charge_kwh_per_hour     DECIMAL(10,2) NOT NULL,
  max_discharge_kwh_per_hour  DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (scenario_id),
  CONSTRAINT fk_battery_scenario FOREIGN KEY (scenario_id)
    REFERENCES scenario (scenario_id) ON DELETE CASCADE,
  CONSTRAINT ck_battery_capacity  CHECK (capacity_kwh > 0),
  CONSTRAINT ck_battery_levels    CHECK (minimum_energy_kwh >= 0
                                     AND minimum_energy_kwh <= initial_energy_kwh
                                     AND initial_energy_kwh <= capacity_kwh),
  CONSTRAINT ck_battery_rates     CHECK (max_charge_kwh_per_hour > 0
                                     AND max_discharge_kwh_per_hour > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 3. hourly_input : 24 hourly rows of demand / solar / tariff per scenario
--    PK (scenario_id, hour_no) = composite key
-- ---------------------------------------------------------------------
CREATE TABLE hourly_input (
  scenario_id         VARCHAR(30)      NOT NULL,
  hour_no             TINYINT UNSIGNED NOT NULL,
  demand_kwh          DECIMAL(10,2)    NOT NULL,
  solar_kwh           DECIMAL(10,2)    NOT NULL,
  tariff_bdt_per_kwh  DECIMAL(10,2)    NOT NULL,
  PRIMARY KEY (scenario_id, hour_no),
  CONSTRAINT fk_input_scenario FOREIGN KEY (scenario_id)
    REFERENCES scenario (scenario_id) ON DELETE CASCADE,
  CONSTRAINT ck_input_hour   CHECK (hour_no BETWEEN 0 AND 23),
  CONSTRAINT ck_input_values CHECK (demand_kwh >= 0 AND solar_kwh >= 0 AND tariff_bdt_per_kwh >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 4. operator_note : 1-3 natural-language notes per scenario (utf8mb4)
-- ---------------------------------------------------------------------
CREATE TABLE operator_note (
  note_id      INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  scenario_id  VARCHAR(30)      NOT NULL,
  note_index   TINYINT UNSIGNED NOT NULL,
  note_text    VARCHAR(600)     NOT NULL,
  PRIMARY KEY (note_id),
  UNIQUE KEY uq_note_position (scenario_id, note_index),
  FULLTEXT KEY ft_note_text (note_text),
  CONSTRAINT fk_note_scenario FOREIGN KEY (scenario_id)
    REFERENCES scenario (scenario_id) ON DELETE CASCADE,
  CONSTRAINT ck_note_index CHECK (note_index BETWEEN 0 AND 2),
  CONSTRAINT ck_note_text  CHECK (CHAR_LENGTH(TRIM(note_text)) > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 5. directive_type : lookup table (a separate table instead of an ENUM = better normalization)
-- ---------------------------------------------------------------------
CREATE TABLE directive_type (
  type_code    VARCHAR(30)  NOT NULL,
  description  VARCHAR(200) NOT NULL,
  param_name   VARCHAR(30)  NULL,
  PRIMARY KEY (type_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO directive_type (type_code, description, param_name) VALUES
 ('solar_reduction',        'Usable solar is reduced in the listed hours (factor = fraction that remains)', 'factor'),
 ('minimum_battery_reserve','Battery energy must not drop below a reserve level in the listed hours',             'minimum_energy_kwh'),
 ('no_charge_window',       'Battery charging is not allowed in the listed hours',                          NULL),
 ('no_discharge_window',    'Battery discharging is not allowed in the listed hours',                       NULL),
 ('max_grid_window',        'Grid import is capped at max_grid_kwh in the listed hours',               'max_grid_kwh'),
 ('no_op',                  'The note has no effect on today''s 24-hour schedule',                     NULL);

-- ---------------------------------------------------------------------
-- 6. directive : exactly one directive per note (note_id UNIQUE => 1:1)
--    the parameter required by each type is enforced with CHECK constraints
-- ---------------------------------------------------------------------
CREATE TABLE directive (
  directive_id        INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  note_id             INT UNSIGNED  NOT NULL,
  type_code           VARCHAR(30)   NOT NULL,
  applies             TINYINT(1)    NOT NULL,
  factor              DECIMAL(5,4)  NULL,
  minimum_energy_kwh  DECIMAL(10,2) NULL,
  max_grid_kwh        DECIMAL(10,2) NULL,
  explanation         VARCHAR(500)  NULL,
  PRIMARY KEY (directive_id),
  UNIQUE KEY uq_directive_note (note_id),
  KEY idx_directive_type (type_code),
  CONSTRAINT fk_directive_note FOREIGN KEY (note_id)
    REFERENCES operator_note (note_id) ON DELETE CASCADE,
  CONSTRAINT fk_directive_type FOREIGN KEY (type_code)
    REFERENCES directive_type (type_code),
  -- no_op => applies=0, every other type => applies=1
  CONSTRAINT ck_directive_applies CHECK (
        (type_code = 'no_op' AND applies = 0)
     OR (type_code <> 'no_op' AND applies = 1)),
  -- each type may carry only its own parameter
  CONSTRAINT ck_directive_factor CHECK (
        (type_code = 'solar_reduction' AND factor IS NOT NULL AND factor BETWEEN 0 AND 1)
     OR (type_code <> 'solar_reduction' AND factor IS NULL)),
  CONSTRAINT ck_directive_reserve CHECK (
        (type_code = 'minimum_battery_reserve' AND minimum_energy_kwh IS NOT NULL AND minimum_energy_kwh >= 0)
     OR (type_code <> 'minimum_battery_reserve' AND minimum_energy_kwh IS NULL)),
  CONSTRAINT ck_directive_gridcap CHECK (
        (type_code = 'max_grid_window' AND max_grid_kwh IS NOT NULL AND max_grid_kwh >= 0)
     OR (type_code <> 'max_grid_window' AND max_grid_kwh IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 7. directive_hour : the JSON "hours":[..] array split into separate rows (1NF)
-- ---------------------------------------------------------------------
CREATE TABLE directive_hour (
  directive_id  INT UNSIGNED     NOT NULL,
  hour_no       TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (directive_id, hour_no),
  KEY idx_dirhour_hour (hour_no),
  CONSTRAINT fk_dirhour_directive FOREIGN KEY (directive_id)
    REFERENCES directive (directive_id) ON DELETE CASCADE,
  CONSTRAINT ck_dirhour_hour CHECK (hour_no BETWEEN 0 AND 23)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 8. plan : a scenario can have several plans (reference, baseline, your own ...)
-- ---------------------------------------------------------------------
CREATE TABLE plan (
  plan_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
  scenario_id  VARCHAR(30)  NOT NULL,
  plan_name    VARCHAR(60)  NOT NULL,
  plan_summary VARCHAR(700) NULL,
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id),
  UNIQUE KEY uq_plan_name (scenario_id, plan_name),
  CONSTRAINT fk_plan_scenario FOREIGN KEY (scenario_id)
    REFERENCES scenario (scenario_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 9. hourly_plan : the 24 rows of a plan
--    total_grid / total_cost / peak_grid are NOT stored here because they are derived
--    (computed by view v_plan_totals) => keeps the schema in 3NF, no redundancy
-- ---------------------------------------------------------------------
CREATE TABLE hourly_plan (
  plan_id            INT UNSIGNED     NOT NULL,
  hour_no            TINYINT UNSIGNED NOT NULL,
  grid_kwh           DECIMAL(10,2)    NOT NULL,
  solar_used_kwh     DECIMAL(10,2)    NOT NULL,
  battery_action     ENUM('charge','discharge','idle') NOT NULL,
  battery_kwh        DECIMAL(10,2)    NOT NULL,
  energy_after_kwh   DECIMAL(10,2)    NOT NULL,
  PRIMARY KEY (plan_id, hour_no),
  KEY idx_hplan_action (battery_action),
  CONSTRAINT fk_hplan_plan FOREIGN KEY (plan_id)
    REFERENCES plan (plan_id) ON DELETE CASCADE,
  CONSTRAINT ck_hplan_hour   CHECK (hour_no BETWEEN 0 AND 23),
  CONSTRAINT ck_hplan_values CHECK (grid_kwh >= 0 AND solar_used_kwh >= 0
                                AND battery_kwh >= 0 AND energy_after_kwh >= 0),
  CONSTRAINT ck_hplan_idle   CHECK (battery_action <> 'idle' OR battery_kwh = 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 10. plan_audit : triggers log every UPDATE / DELETE of hourly_plan here
-- ---------------------------------------------------------------------
CREATE TABLE plan_audit (
  audit_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  plan_id      INT UNSIGNED    NOT NULL,
  hour_no      TINYINT UNSIGNED NOT NULL,
  action_type  ENUM('UPDATE','DELETE') NOT NULL,
  old_grid_kwh DECIMAL(10,2)   NULL,
  new_grid_kwh DECIMAL(10,2)   NULL,
  old_action   VARCHAR(10)     NULL,
  new_action   VARCHAR(10)     NULL,
  changed_at   TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (audit_id),
  KEY idx_audit_plan (plan_id, hour_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- Extra index (06_queries.sql has a before/after EXPLAIN demo)
-- ---------------------------------------------------------------------
CREATE INDEX idx_input_tariff ON hourly_input (tariff_bdt_per_kwh);
