<?php
// GridWise REST API (PHP + PDO + MySQL/MariaDB)
// Usage:  index.php?action=<name>[&param=...]
//   GET : health | scenarios | scenario&id= | plan&id= | stats | validate&plan_id=
//   POST: baseline | import_case | delete_scenario
require __DIR__ . '/db.php';

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type');
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$action = $_GET['action'] ?? 'health';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

function body_json(): array {
    $raw = file_get_contents('php://input');
    $data = json_decode($raw ?: '', true);
    if (!is_array($data)) {
        json_out(['error' => 'Malformed JSON body'], 400);
    }
    return $data;
}

try {
    $pdo = db();

    switch ($action) {
        case 'health':
            $v = $pdo->query('SELECT VERSION() AS v')->fetch()['v'];
            json_out(['status' => 'ok', 'db_version' => $v]);

        case 'scenarios':
            $rows = $pdo->query(
                "SELECT o.*, 
                        (SELECT COUNT(*) FROM v_plan_status s WHERE s.scenario_id = o.scenario_id AND s.status = 'INVALID') AS invalid_plans
                   FROM v_scenario_overview o ORDER BY o.source, o.scenario_id"
            )->fetchAll();
            json_out($rows);

        case 'scenario':
            $id = $_GET['id'] ?? '';
            $st = $pdo->prepare('SELECT * FROM scenario WHERE scenario_id = ?');
            $st->execute([$id]);
            $scn = $st->fetch();
            if (!$scn) json_out(['error' => 'Scenario not found'], 404);

            $q = fn(string $sql) => (function () use ($pdo, $sql, $id) {
                $s = $pdo->prepare($sql);
                $s->execute([$id]);
                return $s->fetchAll();
            })();
            json_out([
                'scenario' => $scn,
                'battery'  => $q('SELECT * FROM battery_config WHERE scenario_id = ?')[0] ?? null,
                'hours'    => $q('SELECT * FROM v_hour_constraints WHERE scenario_id = ? ORDER BY hour_no'),
                'notes'    => $q('SELECT * FROM v_directive_summary WHERE scenario_id = ? ORDER BY note_index'),
                'plans'    => $q('SELECT * FROM v_plan_status WHERE scenario_id = ? ORDER BY plan_id'),
            ]);

        case 'plan':
            $pid = (int)($_GET['id'] ?? 0);
            $st = $pdo->prepare('SELECT * FROM v_plan_totals WHERE plan_id = ?');
            $st->execute([$pid]);
            $tot = $st->fetch();
            if (!$tot) json_out(['error' => 'Plan not found'], 404);
            $st = $pdo->prepare('SELECT plan_summary FROM plan WHERE plan_id = ?');
            $st->execute([$pid]);
            $summary = $st->fetch()['plan_summary'] ?? null;
            $st = $pdo->prepare(
                'SELECT hour_no, tariff_bdt_per_kwh, demand_kwh, solar_kwh, effective_solar_kwh, solar_used_kwh, grid_kwh,
                        battery_action, battery_kwh, energy_after_kwh, hour_cost_bdt,
                        no_charge, no_discharge, max_grid_kwh, min_energy_kwh, capacity_kwh
                   FROM v_plan_rows WHERE plan_id = ? ORDER BY hour_no'
            );
            $st->execute([$pid]);
            $rows = $st->fetchAll();
            $st = $pdo->prepare('SELECT hour_no, rule_code, detail FROM v_plan_violations WHERE plan_id = ? ORDER BY hour_no, rule_code');
            $st->execute([$pid]);
            json_out(['totals' => $tot, 'summary' => $summary, 'rows' => $rows, 'violations' => $st->fetchAll()]);

        case 'validate':
            $pid = (int)($_GET['plan_id'] ?? 0);
            $st = $pdo->prepare('CALL sp_validate_plan(?)');
            $st->execute([$pid]);
            $rows = $st->fetchAll();
            $st->closeCursor();
            json_out(['plan_id' => $pid, 'valid' => count($rows) === 1 && $rows[0]['rule_code'] === 'VALID', 'result' => $rows]);

        case 'stats':
            json_out([
                'counts' => $pdo->query(
                    "SELECT (SELECT COUNT(*) FROM scenario) AS scenarios,
                            (SELECT COUNT(*) FROM operator_note) AS notes,
                            (SELECT COUNT(*) FROM directive WHERE applies = 1) AS active_directives,
                            (SELECT COUNT(*) FROM plan) AS plans,
                            (SELECT COUNT(*) FROM v_plan_status WHERE status = 'VALID') AS valid_plans,
                            (SELECT COUNT(*) FROM hourly_plan) AS plan_rows"
                )->fetch(),
                'by_plan_type' => $pdo->query(
                    "SELECT plan_name, COUNT(*) AS plans, ROUND(AVG(savings_pct), 2) AS avg_saving_pct
                       FROM v_plan_comparison GROUP BY plan_name ORDER BY avg_saving_pct DESC"
                )->fetchAll(),
                'directive_types' => $pdo->query(
                    "SELECT dt.type_code, COUNT(d.directive_id) AS used_times
                       FROM directive_type dt LEFT JOIN directive d ON d.type_code = dt.type_code
                      GROUP BY dt.type_code ORDER BY used_times DESC"
                )->fetchAll(),
                'sample_comparison' => $pdo->query(
                    "SELECT s.scenario_id,
                            MAX(CASE WHEN t.plan_name = 'reference_optimal'   THEN t.total_cost_bdt END) AS reference_cost,
                            MAX(CASE WHEN t.plan_name = 'baseline_no_battery' THEN t.total_cost_bdt END) AS baseline_cost,
                            MAX(nb.no_battery_cost_bdt) AS no_battery_cost
                       FROM scenario s
                       JOIN v_plan_totals t ON t.scenario_id = s.scenario_id
                       JOIN v_no_battery_cost nb ON nb.scenario_id = s.scenario_id
                      WHERE s.source = 'public_sample' GROUP BY s.scenario_id ORDER BY s.scenario_id"
                )->fetchAll(),
            ]);

        case 'baseline':
            if ($method !== 'POST') json_out(['error' => 'POST required'], 405);
            $b = body_json();
            $sid = (string)($b['scenario_id'] ?? '');
            $name = trim((string)($b['plan_name'] ?? '')) ?: 'baseline_no_battery';
            $pdo->prepare('CALL sp_create_baseline_plan(?, ?, @ok, @msg)')->execute([$sid, $name]);
            $r = $pdo->query('SELECT @ok AS ok, @msg AS msg')->fetch();
            $ok = (int)$r['ok'] === 1;
            json_out(['ok' => $ok, 'message' => $r['msg']], $ok ? 200 : 422);

        case 'delete_scenario':
            if ($method !== 'POST') json_out(['error' => 'POST required'], 405);
            $b = body_json();
            $st = $pdo->prepare("DELETE FROM scenario WHERE scenario_id = ? AND source = 'user'");
            $st->execute([(string)($b['scenario_id'] ?? '')]);
            if ($st->rowCount() === 0) json_out(['error' => "Only scenarios imported by a user can be deleted"], 403);
            json_out(['ok' => true]);

        case 'import_case':
            if ($method !== 'POST') json_out(['error' => 'POST required'], 405);
            import_case($pdo, body_json());

        default:
            json_out(['error' => 'Unknown action'], 404);
    }
} catch (PDOException $e) {
    json_out(['error' => 'Database error', 'detail' => db_message($e)], 500);
} catch (Throwable $e) {
    json_out(['error' => 'Server error'], 500);
}

// ---------------------------------------------------------------------
// Inserts one full case (GridWise JSON format) in a single transaction.
// If a trigger/constraint fails at any step, everything is rolled back.
// Accepted shape: { scenario_id, operator_notes[], hours[24], battery{},
//                    directive_interpretation[]?, hourly_plan[]?, plan_summary?, label?, plan_name? }
// or one item of the sample file { input:{...}, expected_output:{...} }
// ---------------------------------------------------------------------
function import_case(PDO $pdo, array $body): void {
    if (isset($body['input']) && is_array($body['input'])) {
        $in  = $body['input'];
        $out = is_array($body['expected_output'] ?? null) ? $body['expected_output'] : [];
        $body = $in + [
            'directive_interpretation' => $out['directive_interpretation'] ?? null,
            'hourly_plan'              => $out['hourly_plan'] ?? null,
            'plan_summary'             => $out['plan_summary'] ?? null,
            'label'                    => $body['label'] ?? null,
        ];
    }
    $fail = fn(string $m, int $c = 422) => json_out(['error' => $m], $c);

    $sid = $body['scenario_id'] ?? null;
    if (!is_string($sid) || !preg_match('/^[A-Za-z0-9_\-]{1,30}$/', $sid)) $fail('scenario_id must be 1-30 chars: letters, digits, _ or -');

    $notes = $body['operator_notes'] ?? null;
    if (!is_array($notes) || count($notes) < 1 || count($notes) > 3) $fail('operator_notes must contain 1-3 notes');
    foreach ($notes as $n) if (!is_string($n) || trim($n) === '') $fail('every operator note must be a non-empty string');

    $hours = $body['hours'] ?? null;
    if (!is_array($hours) || count($hours) !== 24) $fail('hours must contain exactly 24 entries');
    $seen = [];
    foreach ($hours as $h) {
        foreach (['hour', 'demand_kwh', 'solar_kwh', 'tariff_bdt_per_kwh'] as $k) {
            if (!isset($h[$k]) || !is_numeric($h[$k]) || $h[$k] < 0) $fail("hours[].$k must be a non-negative number");
        }
        $seen[(int)$h['hour']] = true;
    }
    if (count($seen) !== 24 || min(array_keys($seen)) !== 0 || max(array_keys($seen)) !== 23) $fail('hours must be unique integers 0..23');

    $bat = $body['battery'] ?? null;
    foreach (['capacity_kwh', 'initial_energy_kwh', 'minimum_energy_kwh', 'max_charge_kwh_per_hour', 'max_discharge_kwh_per_hour'] as $k) {
        if (!is_array($bat) || !isset($bat[$k]) || !is_numeric($bat[$k]) || $bat[$k] < 0) $fail("battery.$k must be a non-negative number");
    }

    $interp = $body['directive_interpretation'] ?? null;
    if ($interp !== null && (!is_array($interp) || count($interp) !== count($notes))) $fail('directive_interpretation needs exactly one entry per note');
    $plan = $body['hourly_plan'] ?? null;
    if ($plan !== null && (!is_array($plan) || count($plan) !== 24)) $fail('hourly_plan must contain exactly 24 entries');

    $exists = $pdo->prepare('SELECT 1 FROM scenario WHERE scenario_id = ?');
    $exists->execute([$sid]);
    if ($exists->fetch()) $fail("scenario_id '$sid' already exists", 409);

    try {
        $pdo->beginTransaction();
        $label = trim((string)($body['label'] ?? '')) ?: "Imported via API: $sid";
        $pdo->prepare("INSERT INTO scenario (scenario_id, label, source) VALUES (?, ?, 'user')")->execute([$sid, mb_substr($label, 0, 120)]);
        $pdo->prepare('INSERT INTO battery_config VALUES (?, ?, ?, ?, ?, ?)')->execute([
            $sid, $bat['capacity_kwh'], $bat['initial_energy_kwh'], $bat['minimum_energy_kwh'],
            $bat['max_charge_kwh_per_hour'], $bat['max_discharge_kwh_per_hour'],
        ]);
        $ins = $pdo->prepare('INSERT INTO hourly_input VALUES (?, ?, ?, ?, ?)');
        usort($hours, fn($a, $b) => $a['hour'] <=> $b['hour']);
        foreach ($hours as $h) $ins->execute([$sid, (int)$h['hour'], $h['demand_kwh'], $h['solar_kwh'], $h['tariff_bdt_per_kwh']]);

        $insNote = $pdo->prepare('INSERT INTO operator_note (scenario_id, note_index, note_text) VALUES (?, ?, ?)');
        $insDir  = $pdo->prepare('INSERT INTO directive (note_id, type_code, applies, factor, minimum_energy_kwh, max_grid_kwh, explanation) VALUES (?, ?, ?, ?, ?, ?, ?)');
        $insHr   = $pdo->prepare('INSERT INTO directive_hour (directive_id, hour_no) VALUES (?, ?)');
        foreach (array_values($notes) as $i => $text) {
            $insNote->execute([$sid, $i, $text]);
            $noteId = (int)$pdo->lastInsertId();
            if ($interp === null) continue;               // without an interpretation the note is only stored
            $d = $interp[$i];
            $type = (string)($d['directive_type'] ?? '');
            $adj  = is_array($d['structured_adjustment'] ?? null) ? $d['structured_adjustment'] : [];
            $insDir->execute([
                $noteId, $type, !empty($d['applies']) ? 1 : 0,
                $adj['factor'] ?? null, $adj['minimum_energy_kwh'] ?? null, $adj['max_grid_kwh'] ?? null,
                isset($d['explanation']) ? mb_substr((string)$d['explanation'], 0, 500) : null,
            ]);
            $dirId = (int)$pdo->lastInsertId();
            $hrs = array_unique(array_map('intval', $adj['hours'] ?? []));
            sort($hrs);
            foreach ($hrs as $hr) $insHr->execute([$dirId, $hr]);
        }

        $planId = null;
        if ($plan !== null) {
            $pdo->prepare('INSERT INTO plan (scenario_id, plan_name, plan_summary) VALUES (?, ?, ?)')->execute([
                $sid, trim((string)($body['plan_name'] ?? '')) ?: 'imported_plan', mb_substr((string)($body['plan_summary'] ?? ''), 0, 700),
            ]);
            $planId = (int)$pdo->lastInsertId();
            usort($plan, fn($a, $b) => $a['hour'] <=> $b['hour']);
            $insP = $pdo->prepare('INSERT INTO hourly_plan VALUES (?, ?, ?, ?, ?, ?, ?)');
            foreach ($plan as $p) {
                $insP->execute([$planId, (int)$p['hour'], $p['grid_kwh'], $p['solar_used_kwh'], $p['battery_action'], $p['battery_kwh'], $p['battery_energy_after_kwh']]);
            }
        }
        $pdo->commit();
        json_out(['ok' => true, 'scenario_id' => $sid, 'plan_id' => $planId], 201);
    } catch (PDOException $e) {
        if ($pdo->inTransaction()) $pdo->rollBack();
        json_out(['error' => 'Rejected by database (transaction rolled back)', 'detail' => db_message($e)], 422);
    }
}
