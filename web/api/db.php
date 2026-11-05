<?php
// Database connection. XAMPP defaults: user=root, empty password, port=3306.
// If yours differ, change the values below (or use the GRIDWISE_DB_* environment variables).
function db(): PDO {
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $host = getenv('GRIDWISE_DB_HOST') ?: '127.0.0.1';
    $port = getenv('GRIDWISE_DB_PORT') ?: '3306';
    $name = getenv('GRIDWISE_DB_NAME') ?: 'gridwise_db';
    $user = getenv('GRIDWISE_DB_USER') ?: 'root';
    $pass = getenv('GRIDWISE_DB_PASS') ?: '';
    $pdo = new PDO(
        "mysql:host=$host;port=$port;dbname=$name;charset=utf8mb4",
        $user,
        $pass,
        [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]
    );
    return $pdo;
}

function json_out($data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRESERVE_ZERO_FRACTION);
    exit;
}

// Extract the clean trigger/constraint message so it can be shown to the user
function db_message(PDOException $e): string {
    return isset($e->errorInfo[2]) ? (string)$e->errorInfo[2] : $e->getMessage();
}
