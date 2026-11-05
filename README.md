# GridWise Database System Project

A Relational Database Management System (RDBMS) implementation for the Smart Campus Energy Optimization domain (adapted from BUP CSE Fest 2026 Hackathon problem specification).

Designed for XAMPP (MySQL / MariaDB 10.4+) and standard MySQL 8.0+.

---

## 1. Project Overview

This project models, stores, audits, and enforces the operational constraints of a smart campus microgrid directly inside the relational database engine. While originally presented as an optimization challenge, this implementation focuses strictly on Database Management Systems (DBMS) principles:
- Relational schema modeling and normalization (1NF, 2NF, 3NF, BCNF).
- Declarative integrity constraints (Primary Keys, Foreign Keys with cascading actions, CHECK constraints).
- Procedural integrity and domain business rule enforcement via Triggers and Stored Procedures.
- Advanced querying using Common Table Expressions (CTE), Window Functions (RANK, LAG, Running SUM), and Complex Joins.
- ACID transaction processing, SAVEPOINT handling, and automated audit logging.

---

## 2. Database Features and Statistics

| Component | Quantity | Key Technical Details |
|---|---|---|
| Tables | 10 | Normalized to 3NF/BCNF; Composite PKs, FKs, CHECK constraints, secondary indexes |
| Views | 11 | Constraint aggregation, plan status validation, hourly reconciliation, financial summaries |
| Triggers | 6 | BEFORE INSERT / BEFORE UPDATE validation, AFTER UPDATE / DELETE audit logging |
| Stored Procedures | 7 | Row-level constraint checker, whole-plan validator, baseline generator, test runner |
| Functions | 1 | Deterministic plan cost computation (fn_plan_cost) |
| Analytical Queries | 26 | CTEs, Window functions, Subqueries, GROUP BY / HAVING, EXPLAIN query optimization |
| Automated Tests | 18 | sp_selftest suite validating integrity rules and negative test rejection |
| Seed Dataset | 70 Scenarios | 10 public reference cases, 60 synthetic cases, 137 plans, 3,288 hourly records |

---

## 3. System Architecture and Relational Model

The database schema (`gridwise_db`) models the microgrid domain through 10 interrelated tables:

1. `scenario`: Core metadata for a 24-hour campus energy scenario.
2. `battery_config`: 1-to-1 relationship with `scenario` defining capacity, baseline reserve, and hourly charge/discharge limits.
3. `hourly_input`: 24 hourly records per scenario containing demand (kWh), forecasted solar (kWh), and grid tariff (BDT/kWh).
4. `operator_note`: 1 to 3 natural language operational advisories attached to a scenario.
5. `directive_type`: Reference lookup table of valid directive types (solar_reduction, minimum_battery_reserve, no_charge_window, no_discharge_window, max_grid_window, no_op).
6. `directive`: Structured interpretation of an operator note.
7. `directive_hour`: Applicable hours (0-23) for each active directive.
8. `plan`: 24-hour energy operating plans evaluated for a scenario.
9. `hourly_plan`: 24 hourly dispatch rows per plan (grid import, solar consumed, battery action, battery level).
10. `plan_audit`: Historical change log populated automatically by database triggers.

---

## 4. Prerequisites

- Operating System: Windows 10 / 11, Linux, or macOS.
- Local Server Stack: XAMPP 8.0+ (Apache + MariaDB 10.4+ or MySQL 8.0+).
- Web Browser: Google Chrome, Mozilla Firefox, or Microsoft Edge.
- Optional: Python 3.8+ (only if regenerating synthetic data).

---

## 5. Step-by-Step Installation Guide (XAMPP on Windows)

### Step 5.1: Start XAMPP Services
1. Open the XAMPP Control Panel.
2. Start the **Apache** service.
3. Start the **MySQL** service.
4. Verify both show green status indicators in the control panel.

### Step 5.2: Deploy the Web Application Directory
1. Locate your web project directory containing `index.html` and the `api/` directory.
2. Copy this directory into your XAMPP web root:
   Target path: `C:\xampp\htdocs\gridwise\`
3. Confirm the folder structure matches:
   ```
   C:\xampp\htdocs\gridwise\
   |-- index.html
   |-- api\
       |-- db.php
       |-- cases.php
       |-- plans.php
       |-- test.php
   ```

### Step 5.3: Configure Database Connection (Optional)
If your XAMPP MySQL root user has a password:
1. Open `C:\xampp\htdocs\gridwise\api\db.php` in a text editor.
2. Modify the password variable:
   ```php
   $pass = 'your_mysql_password';
   ```
   If default XAMPP settings are used (user `root` with no password), no modification is required.

### Step 5.4: Import Database Schema and Data

#### Method A: Using phpMyAdmin (Recommended for GUI)
1. Open your browser and navigate to: `http://localhost/phpmyadmin/`
2. Click on the **Import** tab at the top.
3. Click **Choose File** and select:
   `E:\Gridwise_db\sql\install_all.sql`
4. Click **Go** at the bottom of the page.
5. Verify that the `gridwise_db` database is created with 10 tables and 11 views.

Note: If your phpMyAdmin configuration limits upload file size below the size of `install_all.sql`, import the modular files sequentially:
- `sql/01_schema.sql`
- `sql/02_views.sql`
- `sql/03_routines_triggers.sql`
- `sql/04_seed_samples.sql`
- `sql/05_seed_synthetic.sql`

#### Method B: Using MySQL Command Line
Open PowerShell or Command Prompt and run:
```bash
cd E:\Gridwise_db\sql
C:\xampp\mysql\bin\mysql.exe -u root -p < install_all.sql
```

---

## 6. Verification and Demonstration

### 6.1 Run Automated Unit Tests (sp_selftest)
The database includes an integrated test harness that executes 18 automated validation assertions (including intentional rule violations to confirm trigger blocking).

1. Open phpMyAdmin and select `gridwise_db`.
2. Click on the **SQL** tab.
3. Execute:
   ```sql
   CALL sp_selftest();
   ```
4. Verify that all 18 test cases output `PASS`.

### 6.2 Test Database Trigger Enforcement
To demonstrate that business rules are enforced strictly inside MySQL:
1. Open the web interface at `http://localhost/gridwise/index.html`.
2. Navigate to the **Import a case (API)** tab.
3. Click **Template with a bad plan** followed by **Import / Validate via API**.
4. Observe the response: MySQL triggers reject the invalid rows with a `45000` SQL state, and the transaction is automatically rolled back, leaving the database consistent.

### 6.3 Execute ACID Transaction and Audit Log Demonstration
1. Open `sql/08_transaction_demo.sql`.
2. Run the queries step by step in phpMyAdmin or the MySQL client.
3. This demonstration illustrates:
   - Starting a transaction (`START TRANSACTION`).
   - Inserting an hourly record.
   - Verifying the trigger-populated entry in `plan_audit`.
   - Setting a `SAVEPOINT`.
   - Rolling back changes (`ROLLBACK`) and confirming that data integrity is maintained.

### 6.4 Inspect Plan Violation View
To confirm that all existing plans in the database adhere to physical and operational constraints:
```sql
SELECT * FROM v_plan_violations;
```
Expected result: Empty set (0 rows returned), confirming zero violations across all stored plans.

---

## 7. Analytical and Optimization Queries

The file `sql/06_queries.sql` contains 26 structured queries demonstrating advanced SQL features:

- **Q01 to Q05:** Multi-table relational joins, scenario summaries, and battery profiles.
- **Q06 to Q10:** Directives analysis, solar impact calculations, and affected hour aggregations.
- **Q11 to Q15:** Hourly plan reconciliation, energy balance verification, and solar curtailment detection.
- **Q16 to Q20:** Window functions (`RANK() OVER (...)`, `LAG() OVER (...)` for battery rate tracking, and running cumulative costs).
- **Q21 to Q24:** Set operations, subqueries with `NOT EXISTS`, and schema constraint sanity checks.
- **Q25 to Q26:** Index performance comparison and query execution plan analysis via `EXPLAIN`.

---

## 8. File Directory Reference

```
E:\Gridwise_db\
|-- README.md                    Project documentation and setup guide
|-- docs\
|   |-- ER_and_normalization.md  Database design documentation and 3NF/BCNF proofs
|   |-- ER_diagram.mmd           Mermaid source for Entity-Relationship diagram
|   |-- ER_diagram.png           Rendered ER diagram image
|-- sql\
|   |-- 01_schema.sql            DDL: Tables, primary keys, foreign keys, CHECK constraints
|   |-- 02_views.sql             Views for business logic and analytical reporting
|   |-- 03_routines_triggers.sql Stored procedures, triggers, and functions
|   |-- 04_seed_samples.sql      Reference datasets from 10 public hackathon cases
|   |-- 05_seed_synthetic.sql    60 synthetic scenarios and validated plans
|   |-- 06_queries.sql           26 comprehensive evaluation queries
|   |-- 07_selftest.sql          Automated test suite procedure (sp_selftest)
|   |-- 08_transaction_demo.sql  ACID transaction and trigger audit walkthrough
|   |-- install_all.sql          Consolidated deployment script
|-- tools\
|   |-- build_seed.py            Converts public JSON sample cases into SQL seed
|   |-- gen_synthetic.py         Generates synthetic scenario SQL seed
```

---

## 9. Academic Justification (For Database Course Evaluation)

This project satisfies all fundamental requirements of an advanced university-level Database Systems course:

1. **Relational Modeling & Normalization:**
   Deconstructed complex nested JSON structures into 10 tables in Boyce-Codd Normal Form (BCNF), eliminating update, insertion, and deletion anomalies.

2. **Integrity Constraints:**
   Utilizes composite primary keys, foreign keys with referential integrity (`ON DELETE CASCADE`), and domain CHECK constraints enforcing non-negative values, percentage limits, and state bounds.

3. **In-Database Business Logic:**
   Energy balance equations ($Demand + Charge = Grid + Solar + Discharge$) and battery physical boundaries are validated through BEFORE INSERT / BEFORE UPDATE triggers using `SIGNAL SQLSTATE '45000'`.

4. **Audit and Historical Logging:**
   AFTER UPDATE and AFTER DELETE triggers write record state changes into a dedicated `plan_audit` table.

5. **Advanced SQL Capabilities:**
   Demonstrates Common Table Expressions (WITH clauses), Window Functions (`RANK`, `LAG`, `SUM() OVER`), Aggregations (`GROUP BY`, `HAVING`), and query optimization using `EXPLAIN`.
