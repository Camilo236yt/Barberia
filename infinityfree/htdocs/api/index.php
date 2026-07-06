<?php
declare(strict_types=1);

final class HttpError extends RuntimeException
{
    public function __construct(string $message, public int $status = 400)
    {
        parent::__construct($message);
    }
}

function jsonResponse(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function headerValue(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    return trim((string)($_SERVER[$key] ?? ''));
}

function requestBody(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        throw new HttpError('JSON inválido.');
    }
    return $decoded;
}

function config(): array
{
    static $config;
    if (is_array($config)) {
        return $config;
    }
    $path = __DIR__ . '/config.php';
    if (!is_file($path)) {
        throw new HttpError(
            'Falta api/config.php. Copia config.example.php y completa MySQL.',
            503
        );
    }
    $config = require $path;
    foreach (['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'ADMIN_TOKEN', 'IMPORT_SECRET'] as $key) {
        if (empty($config[$key]) || str_contains((string)$config[$key], 'CAMBIA_')) {
            throw new HttpError("La configuración $key no está lista.", 503);
        }
    }
    date_default_timezone_set((string)($config['TIMEZONE'] ?? 'America/Bogota'));
    return $config;
}

function pdo(): PDO
{
    static $pdo;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $cfg = config();
    $dsn = sprintf(
        'mysql:host=%s;dbname=%s;charset=utf8mb4',
        $cfg['DB_HOST'],
        $cfg['DB_NAME']
    );
    $pdo = new PDO($dsn, $cfg['DB_USER'], $cfg['DB_PASSWORD'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false,
    ]);
    $pdo->exec(
        'CREATE TABLE IF NOT EXISTS cg_state (
            id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
            data LONGTEXT NOT NULL,
            version BIGINT UNSIGNED NOT NULL DEFAULT 1,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
    );
    $pdo->exec(
        'CREATE TABLE IF NOT EXISTS cg_devices (
            device_id VARCHAR(80) NOT NULL PRIMARY KEY,
            branch_id VARCHAR(64) NULL,
            role_name VARCHAR(20) NOT NULL DEFAULT "online",
            last_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_cg_devices_seen (last_seen)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
    );
    return $pdo;
}

function defaultState(): array
{
    return [
        'branches' => [
            ['id' => 'barberia-1', 'name' => 'Barbería de Arriba', 'active' => true],
            ['id' => 'barberia-2', 'name' => 'Barbería de Abajo', 'active' => true],
        ],
        'barbers' => [
            ['id' => 'jose', 'name' => 'Jose', 'active' => true, 'branch_id' => 'barberia-1', 'commission_rate' => 0.5],
            ['id' => 'luis', 'name' => 'Luís', 'active' => true, 'branch_id' => 'barberia-1', 'commission_rate' => 0.5],
            ['id' => 'samuel', 'name' => 'Samuel', 'active' => true, 'branch_id' => 'barberia-1', 'commission_rate' => 0.5],
            ['id' => 'omar', 'name' => 'Omar', 'active' => true, 'branch_id' => 'barberia-2', 'commission_rate' => 0.6],
            ['id' => 'randy', 'name' => 'Randy', 'active' => true, 'branch_id' => 'barberia-2', 'commission_rate' => 0.5],
            ['id' => 'juan', 'name' => 'Juan', 'active' => true, 'branch_id' => 'barberia-2', 'commission_rate' => 0.5],
        ],
        'services' => [
            ['id' => 'tijeras', 'name' => 'Corte con tijeras', 'price' => 30000, 'branch_id' => 'barberia-1'],
            ['id' => 'basico', 'name' => 'Corte básico', 'price' => 25000, 'branch_id' => 'barberia-1'],
            ['id' => 'barba', 'name' => 'Barba', 'price' => 15000, 'branch_id' => 'barberia-1'],
            ['id' => 'combo', 'name' => 'Corte y barba', 'price' => 40000, 'branch_id' => 'barberia-1'],
            ['id' => 'combo-tijeras', 'name' => 'Corte con tijeras y barba', 'price' => 40000, 'branch_id' => 'barberia-1'],
            ['id' => 'tijeras-b2', 'name' => 'Corte con tijeras', 'price' => 30000, 'branch_id' => 'barberia-2'],
            ['id' => 'basico-b2', 'name' => 'Corte básico', 'price' => 25000, 'branch_id' => 'barberia-2'],
            ['id' => 'barba-b2', 'name' => 'Barba', 'price' => 15000, 'branch_id' => 'barberia-2'],
            ['id' => 'combo-b2', 'name' => 'Corte y barba', 'price' => 40000, 'branch_id' => 'barberia-2'],
            ['id' => 'combo-tijeras-b2', 'name' => 'Corte con tijeras y barba', 'price' => 40000, 'branch_id' => 'barberia-2'],
        ],
        'sales' => [],
        'closures' => [],
        'expenses' => [],
        'settings' => [
            'commission_rate' => 0.5,
            'currency' => 'COP',
            'business_whatsapp_country_code' => '57',
            'catalog_version' => 3,
        ],
    ];
}

function normalizeState(array $state): array
{
    $defaults = defaultState();
    foreach (['branches', 'barbers', 'services', 'sales', 'closures', 'expenses'] as $key) {
        if (!isset($state[$key]) || !is_array($state[$key])) {
            $state[$key] = $defaults[$key];
        }
    }
    $state['settings'] = array_merge(
        $defaults['settings'],
        is_array($state['settings'] ?? null) ? $state['settings'] : []
    );
    foreach ($state['sales'] as &$sale) {
        if (!in_array($sale['sale_kind'] ?? '', ['service', 'product'], true)) {
            $sale['sale_kind'] = empty($sale['barber_id']) ? 'product' : 'service';
        }
        if ($sale['sale_kind'] === 'product') {
            $sale['barber_id'] = null;
            $sale['barber_name'] = 'Barbería · Nevera';
            $sale['service_id'] = 'nevera';
            $sale['base_amount'] = (int)($sale['amount'] ?? 0);
            $sale['listed_price'] = null;
            $sale['tip_amount'] = 0;
        }
    }
    unset($sale);
    return $state;
}

function readState(bool $forUpdate = false): array
{
    $sql = 'SELECT data FROM cg_state WHERE id = 1' . ($forUpdate ? ' FOR UPDATE' : '');
    $row = pdo()->query($sql)->fetch();
    if (!$row) {
        $state = defaultState();
        $statement = pdo()->prepare('INSERT INTO cg_state (id, data, version) VALUES (1, ?, 1)');
        $statement->execute([json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)]);
        return $state;
    }
    $state = json_decode((string)$row['data'], true);
    if (!is_array($state)) {
        throw new HttpError('La base cloud contiene un estado no válido.', 500);
    }
    return normalizeState($state);
}

function mutateState(callable $callback): array
{
    $database = pdo();
    $database->beginTransaction();
    try {
        $state = readState(true);
        $result = $callback($state);
        $statement = $database->prepare(
            'UPDATE cg_state SET data = ?, version = version + 1 WHERE id = 1'
        );
        $statement->execute([
            json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ]);
        $database->commit();
        return $result;
    } catch (Throwable $error) {
        if ($database->inTransaction()) {
            $database->rollBack();
        }
        throw $error;
    }
}

function findIndex(array $items, ?string $id): int
{
    foreach ($items as $index => $item) {
        if ((string)($item['id'] ?? '') === (string)$id) {
            return $index;
        }
    }
    return -1;
}

function newId(string $prefix = ''): string
{
    return $prefix . bin2hex(random_bytes(6));
}

function nowIso(): string
{
    return date('Y-m-d\TH:i:s');
}

function todayKey(): string
{
    return date('Y-m-d');
}

function itemDay(array $item): string
{
    return substr((string)($item['created_at'] ?? ''), 0, 10);
}

function requiredName(mixed $value, string $label): string
{
    $name = trim((string)$value);
    $length = function_exists('mb_strlen') ? mb_strlen($name) : strlen($name);
    if ($length < 2 || $length > 60) {
        throw new HttpError("El nombre del $label debe tener entre 2 y 60 caracteres.");
    }
    return $name;
}

function money(mixed $value): int
{
    $amount = (int)round((float)$value);
    if ($amount <= 0) {
        throw new HttpError('El valor debe ser mayor a cero.');
    }
    return $amount;
}

function saleTip(array $sale): int
{
    $amount = (int)($sale['amount'] ?? 0);
    $tip = (int)($sale['tip_amount'] ?? 0);
    return $tip >= 0 && $tip <= $amount ? $tip : 0;
}

function saleBase(array $sale): int
{
    return (int)($sale['amount'] ?? 0) - saleTip($sale);
}

function barberRate(array $barber): float
{
    $default = (($barber['id'] ?? '') === 'omar' || strtolower(trim((string)($barber['name'] ?? ''))) === 'omar')
        ? 0.6
        : 0.5;
    $rate = (float)($barber['commission_rate'] ?? $default);
    return $rate > 0 && $rate <= 1 ? $rate : $default;
}

function findClosureIndex(array $state, string $date, string $branchId): int
{
    foreach ($state['closures'] as $index => $closure) {
        if (($closure['date'] ?? '') === $date && ($closure['branch_id'] ?? '') === $branchId) {
            return $index;
        }
    }
    return -1;
}

function closureEvent(array $snapshot): array
{
    return [
        'type' => 'closed',
        'at' => $snapshot['closed_at'],
        'counted_cash' => $snapshot['counted_cash'],
        'expected_cash' => $snapshot['expected_cash'],
        'cash_difference' => $snapshot['cash_difference'],
        'total_confirmed' => $snapshot['total_confirmed'],
        'cash_total' => $snapshot['cash_total'],
        'nequi_confirmed' => $snapshot['nequi_confirmed'],
        'sales_count' => $snapshot['sales_count'],
    ];
}

function closureSnapshot(array $state, string $date, int $countedCash, array $branch): array
{
    $sales = array_values(array_filter(
        $state['sales'],
        fn(array $sale): bool =>
            itemDay($sale) === $date &&
            ($sale['branch_id'] ?? '') === $branch['id'] &&
            !in_array($sale['status'] ?? '', ['annulled', 'rejected'], true)
    ));
    $confirmed = array_values(array_filter(
        $sales,
        fn(array $sale): bool => ($sale['status'] ?? '') === 'confirmed'
    ));
    $pending = array_values(array_filter(
        $sales,
        fn(array $sale): bool => ($sale['status'] ?? '') === 'pending_review'
    ));
    $sum = fn(array $items): int => array_sum(array_map(
        fn(array $sale): int => (int)($sale['amount'] ?? 0),
        $items
    ));
    $cash = array_values(array_filter($confirmed, fn(array $sale): bool => ($sale['payment_method'] ?? '') === 'cash'));
    $nequi = array_values(array_filter($confirmed, fn(array $sale): bool => ($sale['payment_method'] ?? '') === 'nequi'));
    $pendingNequi = array_values(array_filter($pending, fn(array $sale): bool => ($sale['payment_method'] ?? '') === 'nequi'));

    $barberIds = [];
    foreach ($state['barbers'] as $barber) {
        if (($barber['branch_id'] ?? '') === $branch['id']) {
            $barberIds[] = (string)$barber['id'];
        }
    }
    foreach ($confirmed as $sale) {
        $barberId = (string)($sale['barber_id'] ?? '');
        if ($barberId !== '' && !in_array($barberId, $barberIds, true)) {
            $barberIds[] = $barberId;
        }
    }

    $barberTotals = [];
    foreach ($barberIds as $barberId) {
        $barberSales = array_values(array_filter(
            $confirmed,
            fn(array $sale): bool => ($sale['barber_id'] ?? '') === $barberId
        ));
        $barberIndex = findIndex($state['barbers'], $barberId);
        $barber = $barberIndex >= 0
            ? $state['barbers'][$barberIndex]
            : ['id' => $barberId, 'name' => $barberSales[0]['barber_name'] ?? 'Barbero', 'commission_rate' => 0.5];
        $total = $sum($barberSales);
        $tipTotal = array_sum(array_map('saleTip', $barberSales));
        $baseTotal = array_sum(array_map('saleBase', $barberSales));
        $cashSales = array_values(array_filter($barberSales, fn(array $sale): bool => ($sale['payment_method'] ?? '') === 'cash'));
        $nequiSales = array_values(array_filter($barberSales, fn(array $sale): bool => ($sale['payment_method'] ?? '') === 'nequi'));
        $cashTotal = $sum($cashSales);
        $nequiTotal = $sum($nequiSales);
        $cashBase = array_sum(array_map('saleBase', $cashSales));
        $nequiBase = array_sum(array_map('saleBase', $nequiSales));
        $rate = barberRate($barber);
        // Fórmula vigente del programa de escritorio:
        // porcentaje sobre base + propina completa para el barbero.
        $baseCommission = (int)round($baseTotal * $rate);
        $commission = $baseCommission + $tipTotal;
        $barberTotals[] = [
            'barber_id' => $barberId,
            'barber_name' => $barber['name'],
            'sales_count' => count($barberSales),
            'total' => $total,
            'base_total' => $baseTotal,
            'tip_total' => $tipTotal,
            'nequi_total' => $nequiTotal,
            'cash_payment_total' => $cashTotal,
            'cash_base_total' => $cashBase,
            'cash_shop_share' => $cashBase - (int)round($cashBase * $rate),
            'nequi_base_total' => $nequiBase,
            'nequi_shop_share' => $nequiBase - (int)round($nequiBase * $rate),
            'commission_rate' => $rate,
            'commission' => $commission,
            'shop_share' => $baseTotal - $baseCommission,
        ];
    }

    $cashTotal = $sum($cash);
    return [
        'date' => $date,
        'branch_id' => $branch['id'],
        'branch_name' => $branch['name'],
        'closed_at' => nowIso(),
        'status' => 'closed',
        'counted_cash' => $countedCash,
        'expected_cash' => $cashTotal,
        'cash_difference' => $countedCash - $cashTotal,
        'total_confirmed' => $sum($confirmed),
        'cash_total' => $cashTotal,
        'nequi_confirmed' => $sum($nequi),
        'nequi_pending' => $sum($pendingNequi),
        'sales_count' => count($confirmed),
        'pending_nequi_count' => count($pending),
        'commission_rate' => (float)($state['settings']['commission_rate'] ?? 0.5),
        'barbers' => $barberTotals,
    ];
}

function refreshClosure(array &$state, string $date, array $branch): void
{
    $index = findClosureIndex($state, $date, (string)$branch['id']);
    if ($index < 0) {
        return;
    }
    $existing = $state['closures'][$index];
    $snapshot = closureSnapshot($state, $date, (int)($existing['counted_cash'] ?? 0), $branch);
    foreach ([
        'expected_cash', 'cash_difference', 'total_confirmed', 'cash_total',
        'nequi_confirmed', 'nequi_pending', 'sales_count',
        'pending_nequi_count', 'commission_rate', 'barbers'
    ] as $field) {
        $existing[$field] = $snapshot[$field];
    }
    $existing['modified_at'] = nowIso();
    $state['closures'][$index] = $existing;
}

function saveProof(?string $dataUrl, string $saleId): ?string
{
    if ($dataUrl === null || $dataUrl === '') {
        return null;
    }
    if (!preg_match('#^data:(image/[A-Za-z0-9.+-]+);base64,(.+)$#s', $dataUrl, $matches)) {
        throw new HttpError('El comprobante debe ser una imagen válida.');
    }
    $raw = base64_decode($matches[2], true);
    if ($raw === false || strlen($raw) > 8 * 1024 * 1024) {
        throw new HttpError('La imagen no es válida o supera 8 MB.');
    }
    $extensions = [
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
    ];
    $extension = $extensions[strtolower($matches[1])] ?? 'jpg';
    $directory = dirname(__DIR__) . '/uploads';
    if (!is_dir($directory) && !mkdir($directory, 0755, true) && !is_dir($directory)) {
        throw new HttpError('No se pudo crear la carpeta de comprobantes.', 500);
    }
    $filename = $saleId . '.' . $extension;
    if (file_put_contents($directory . '/' . $filename, $raw, LOCK_EX) === false) {
        throw new HttpError('No se pudo guardar el comprobante.', 500);
    }
    return '/uploads/' . $filename;
}

function barberPortalOptions(): never
{
    $state = readState();
    $branches = array_values(array_filter(
        $state['branches'],
        fn(array $branch): bool => ($branch['active'] ?? true) !== false
    ));
    $branchIds = array_map(fn(array $branch): string => (string)($branch['id'] ?? ''), $branches);
    $barbers = array_values(array_filter(
        $state['barbers'],
        fn(array $barber): bool =>
            ($barber['active'] ?? true) !== false &&
            in_array((string)($barber['branch_id'] ?? ''), $branchIds, true)
    ));
    $services = array_values(array_filter(
        $state['services'],
        fn(array $service): bool => in_array((string)($service['branch_id'] ?? ''), $branchIds, true)
    ));
    jsonResponse([
        'branches' => $branches,
        'barbers' => $barbers,
        'services' => $services,
        'settings' => $state['settings'],
        'date' => todayKey(),
    ]);
}

function barberPortalBootstrap(): never
{
    $barberId = trim((string)($_GET['barber_id'] ?? ''));
    $date = trim((string)($_GET['date'] ?? todayKey()));
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date) || $date > todayKey()) {
        throw new HttpError('Selecciona una fecha válida.');
    }
    $state = readState();
    $barberIndex = findIndex($state['barbers'], $barberId);
    if ($barberIndex < 0 || ($state['barbers'][$barberIndex]['active'] ?? true) === false) {
        throw new HttpError('Selecciona un barbero válido.', 404);
    }
    $barber = $state['barbers'][$barberIndex];
    $branchIndex = findIndex($state['branches'], (string)($barber['branch_id'] ?? ''));
    if ($branchIndex < 0 || ($state['branches'][$branchIndex]['active'] ?? true) === false) {
        throw new HttpError('La barbería de este barbero no está activa.', 404);
    }
    $branch = $state['branches'][$branchIndex];
    $sales = array_values(array_filter(
        $state['sales'],
        fn(array $sale): bool =>
            itemDay($sale) === $date &&
            ($sale['barber_id'] ?? '') === $barberId &&
            !in_array($sale['status'] ?? '', ['annulled', 'rejected'], true)
    ));
    $expenses = array_values(array_filter(
        $state['expenses'],
        fn(array $expense): bool =>
            ($expense['date'] ?? '') === $date &&
            ($expense['expense_type'] ?? '') === 'barber' &&
            ($expense['barber_id'] ?? '') === $barberId
    ));
    $closures = array_values(array_filter(
        $state['closures'],
        fn(array $closure): bool =>
            ($closure['date'] ?? '') === $date &&
            ($closure['branch_id'] ?? '') === ($branch['id'] ?? '')
    ));
    $services = array_values(array_filter(
        $state['services'],
        fn(array $service): bool => ($service['branch_id'] ?? '') === ($branch['id'] ?? '')
    ));
    jsonResponse([
        'branch' => $branch,
        'barber' => $barber,
        'services' => $services,
        'sales' => $sales,
        'expenses' => $expenses,
        'closures' => $closures,
        'settings' => $state['settings'],
        'date' => $date,
        'closed' => count(array_filter($closures, fn(array $closure): bool => ($closure['status'] ?? '') === 'closed')) > 0,
    ]);
}

function createBarberPortalSale(): never
{
    $payload = requestBody();
    $result = mutateState(function (array &$state) use ($payload): array {
        $barberId = trim((string)($payload['barber_id'] ?? ''));
        $requestId = trim((string)($payload['client_request_id'] ?? ''));
        if ($requestId !== '' && !preg_match('/^[A-Za-z0-9-]{8,160}$/', $requestId)) {
            throw new HttpError('El identificador local de la venta no es válido.');
        }
        $barberIndex = findIndex($state['barbers'], $barberId);
        if ($barberIndex < 0 || ($state['barbers'][$barberIndex]['active'] ?? true) === false) {
            throw new HttpError('Selecciona un barbero válido.');
        }
        $barber = $state['barbers'][$barberIndex];
        $branchId = (string)($barber['branch_id'] ?? '');
        $branchIndex = findIndex($state['branches'], $branchId);
        if ($branchIndex < 0 || ($state['branches'][$branchIndex]['active'] ?? true) === false) {
            throw new HttpError('La barbería de este barbero no está activa.');
        }
        $date = todayKey();
        $closureIndex = findClosureIndex($state, $date, $branchId);
        if ($closureIndex >= 0 && ($state['closures'][$closureIndex]['status'] ?? '') === 'closed') {
            throw new HttpError('La caja de esta barbería ya está cerrada.');
        }
        if ($requestId !== '') {
            foreach ($state['sales'] as $existing) {
                if (($existing['client_request_id'] ?? '') === $requestId && ($existing['barber_id'] ?? '') === $barberId) {
                    return ['sale' => $existing, 'already_synchronized' => true];
                }
            }
        }
        $payment = (string)($payload['payment_method'] ?? '');
        if (!in_array($payment, ['cash', 'nequi'], true)) {
            throw new HttpError('Selecciona efectivo o Nequi.');
        }
        $amount = money($payload['amount'] ?? 0);
        $custom = trim((string)($payload['custom_service_name'] ?? ''));
        if ($custom !== '') {
            $serviceId = 'especial';
            $serviceName = requiredName($custom, 'servicio especial');
            $listedPrice = null;
            $baseAmount = $amount;
            $tipAmount = 0;
        } else {
            $serviceIndex = findIndex($state['services'], (string)($payload['service_id'] ?? ''));
            if ($serviceIndex < 0 || ($state['services'][$serviceIndex]['branch_id'] ?? '') !== $branchId) {
                throw new HttpError('Servicio no encontrado.');
            }
            $service = $state['services'][$serviceIndex];
            $serviceId = $service['id'];
            $serviceName = $service['name'];
            $listedPrice = (int)$service['price'];
            $tipAmount = max(0, $amount - $listedPrice);
            $baseAmount = $amount - $tipAmount;
        }
        $saleId = newId();
        $proof = null;
        if ($payment === 'nequi') {
            $proof = saveProof((string)($payload['proof_image'] ?? ''), $saleId);
            if ($proof === null) {
                throw new HttpError('El comprobante de Nequi es obligatorio.');
            }
        }
        $sale = [
            'id' => $saleId,
            'client_request_id' => $requestId ?: null,
            'created_at' => $date . 'T' . date('H:i') . ':00',
            'branch_id' => $branchId,
            'branch_name' => $state['branches'][$branchIndex]['name'] ?? 'Barbería',
            'sale_kind' => 'service',
            'barber_id' => $barber['id'],
            'barber_name' => $barber['name'],
            'service_id' => $serviceId,
            'service_name' => $serviceName,
            'amount' => $amount,
            'base_amount' => $baseAmount,
            'listed_price' => $listedPrice,
            'tip_amount' => $tipAmount,
            'payment_method' => $payment,
            'proof_url' => $proof,
            'proof_note' => substr(trim((string)($payload['proof_note'] ?? '')), 0, 120),
            'client_name' => substr(trim((string)($payload['client_name'] ?? '')), 0, 80),
            'status' => $payment === 'cash' ? 'confirmed' : 'pending_review',
            'created_by' => 'barber_portal',
        ];
        array_unshift($state['sales'], $sale);
        refreshClosure($state, $date, $state['branches'][$branchIndex]);
        return ['sale' => $sale];
    });
    jsonResponse($result, isset($result['already_synchronized']) ? 200 : 201);
}

function authenticate(): string
{
    $cfg = config();
    $token = headerValue('X-Admin-Token');
    if ($token === '') {
        $token = trim((string)($_GET['token'] ?? ''));
    }
    if ($token === '' || !hash_equals((string)$cfg['ADMIN_TOKEN'], $token)) {
        throw new HttpError('El enlace administrativo cloud no es válido.', 403);
    }
    $deviceId = headerValue('X-Device-Id');
    if (!preg_match('/^[A-Za-z0-9-]{8,80}$/', $deviceId)) {
        throw new HttpError('Este dispositivo no tiene una identificación válida.', 403);
    }
    $database = pdo();
    $database->exec('DELETE FROM cg_devices WHERE last_seen < (NOW() - INTERVAL 10 MINUTE)');
    $statement = $database->prepare('SELECT device_id FROM cg_devices WHERE device_id = ?');
    $statement->execute([$deviceId]);
    $exists = (bool)$statement->fetch();
    if (!$exists) {
        $count = (int)$database->query('SELECT COUNT(*) FROM cg_devices')->fetchColumn();
        if ($count >= (int)($cfg['MAX_DEVICES'] ?? 10)) {
            throw new HttpError('Ya se alcanzó el máximo de dispositivos conectados.', 403);
        }
    }
    $statement = $database->prepare(
        'INSERT INTO cg_devices (device_id, role_name, last_seen)
         VALUES (?, "online", NOW())
         ON DUPLICATE KEY UPDATE role_name = "online", last_seen = NOW()'
    );
    $statement->execute([$deviceId]);
    return $deviceId;
}

function selectedBranch(string $deviceId, bool $required = true): string
{
    $statement = pdo()->prepare('SELECT branch_id FROM cg_devices WHERE device_id = ?');
    $statement->execute([$deviceId]);
    $branch = (string)($statement->fetchColumn() ?: '');
    $headerBranch = headerValue('X-Branch-Id');
    if ($required && ($branch === '' || $headerBranch === '' || $branch !== $headerBranch)) {
        throw new HttpError('Esta sesión no tiene asignada esa barbería.', 403);
    }
    return $branch;
}

function mergeById(array $current, array $incoming): array
{
    $merged = [];
    foreach ($current as $item) {
        if (isset($item['id'])) {
            $merged[(string)$item['id']] = $item;
        }
    }
    foreach ($incoming as $item) {
        if (is_array($item) && isset($item['id'])) {
            $merged[(string)$item['id']] = $item;
        }
    }
    return array_values($merged);
}

function routePath(): string
{
    $path = (string)(parse_url($_SERVER['REQUEST_URI'] ?? '/api', PHP_URL_PATH) ?: '/api');
    $position = strpos($path, '/api');
    if ($position !== false) {
        $path = substr($path, $position + 4);
    }
    return $path === '' ? '/' : '/' . ltrim($path, '/');
}

require_once __DIR__ . '/github.php';

if (defined('CAPITAN_GOLD_LIBRARY_ONLY') && CAPITAN_GOLD_LIBRARY_ONLY === true) {
    return;
}

try {
    $path = routePath();
    $method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));

    if ($path === '/health') {
        pdo();
        jsonResponse(['ok' => true, 'mode' => 'infinityfree-php']);
    }

    if (in_array($path, ['/import', '/migrar-datos'], true) && $method === 'POST') {
        $provided = headerValue('X-Import-Secret');
        if ($provided === '') {
            $provided = trim((string)($_POST['import_secret'] ?? ''));
        }
        if ($provided === '' || !hash_equals((string)config()['IMPORT_SECRET'], $provided)) {
            throw new HttpError('Clave de importación incorrecta.', 403);
        }
        $file = __DIR__ . '/migration-data.json';
        if (!is_file($file)) {
            throw new HttpError('No se encontró api/migration-data.json.');
        }
        $incoming = json_decode((string)file_get_contents($file), true);
        if (!is_array($incoming)) {
            throw new HttpError('El archivo de migración no es válido.');
        }
        $result = mutateState(function (array &$state) use ($incoming): array {
            foreach (['branches', 'barbers', 'services', 'sales', 'closures', 'expenses'] as $key) {
                $state[$key] = mergeById($state[$key] ?? [], $incoming[$key] ?? []);
            }
            $state['settings'] = array_merge($state['settings'] ?? [], $incoming['settings'] ?? []);
            $state = normalizeState($state);
            return [
                'ok' => true,
                'sales' => count($state['sales']),
                'closures' => count($state['closures']),
                'expenses' => count($state['expenses']),
            ];
        });
        $result['migration_file_deleted'] = @unlink($file);
        jsonResponse($result);
    }

    if ($path === '/barber-portal/options' && $method === 'GET') {
        barberPortalOptions();
    }

    if ($path === '/barber-portal/bootstrap' && $method === 'GET') {
        barberPortalBootstrap();
    }

    if ($path === '/barber-portal/sales' && $method === 'POST') {
        createBarberPortalSale();
    }

    $deviceId = authenticate();

    if ($path === '/local-ui/heartbeat' || $path === '/local-ui/close') {
        requestBody();
        jsonResponse(['ok' => true]);
    }

    if ($path === '/admin/options' && $method === 'GET') {
        $branchId = selectedBranch($deviceId, false);
        $state = readState();
        $count = (int)pdo()->query('SELECT COUNT(*) FROM cg_devices')->fetchColumn();
        jsonResponse([
            'role' => 'online',
            'selected_branch_id' => $branchId ?: null,
            'occupied_branch_id' => null,
            'connected_devices' => $count,
            'max_devices' => (int)(config()['MAX_DEVICES'] ?? 10),
            'branches' => array_values(array_filter($state['branches'], fn(array $branch): bool => ($branch['active'] ?? true) !== false)),
        ]);
    }

    if ($path === '/admin/select-branch' && $method === 'POST') {
        $payload = requestBody();
        $branchId = trim((string)($payload['branch_id'] ?? ''));
        $state = readState();
        $index = findIndex($state['branches'], $branchId);
        if ($index < 0 || ($state['branches'][$index]['active'] ?? true) === false) {
            throw new HttpError('Selecciona una barbería válida.');
        }
        $statement = pdo()->prepare(
            'UPDATE cg_devices SET branch_id = ?, last_seen = NOW() WHERE device_id = ?'
        );
        $statement->execute([$branchId, $deviceId]);
        jsonResponse(['role' => 'online', 'branch' => $state['branches'][$index]]);
    }

    $branchId = selectedBranch($deviceId);

    if ($path === '/bootstrap' && $method === 'GET') {
        $state = readState();
        $branchIndex = findIndex($state['branches'], $branchId);
        if ($branchIndex < 0) {
            throw new HttpError('Barbería no encontrada.', 404);
        }
        jsonResponse([
            'branches' => [$state['branches'][$branchIndex]],
            'barbers' => array_values(array_filter($state['barbers'], fn(array $item): bool => ($item['branch_id'] ?? '') === $branchId)),
            'services' => array_values(array_filter($state['services'], fn(array $item): bool => ($item['branch_id'] ?? '') === $branchId)),
            'sales' => array_values(array_filter($state['sales'], fn(array $item): bool => ($item['branch_id'] ?? '') === $branchId)),
            'closures' => array_values(array_filter($state['closures'], fn(array $item): bool => ($item['branch_id'] ?? '') === $branchId)),
            'expenses' => array_values(array_filter($state['expenses'], fn(array $item): bool => ($item['branch_id'] ?? '') === $branchId)),
            'settings' => $state['settings'],
            'capabilities' => [
                'historical_sales' => true,
                'strict_date_filtering' => true,
                'cloud_mysql' => true,
            ],
        ]);
    }

    if ($path === '/history-backups' && $method === 'GET') {
        $localMonths = [];
        foreach (readState()['sales'] as $sale) {
            if (($sale['branch_id'] ?? '') === $branchId) {
                $month = substr(itemDay($sale), 0, 7);
                if (preg_match('/^\d{4}-\d{2}$/', $month)) {
                    $localMonths[$month] = true;
                }
            }
        }
        $localMonths = array_keys($localMonths);
        rsort($localMonths);
        $remoteMonths = [];
        $remoteError = null;
        try {
            $remoteMonths = githubRemoteMonths();
        } catch (Throwable $error) {
            $remoteError = $error instanceof HttpError
                ? $error->getMessage()
                : 'No se pudo consultar GitHub.';
        }
        jsonResponse([
            'local_months' => $localMonths,
            'remote_months' => $remoteMonths,
            'remote_error' => $remoteError,
            'status' => [
                'state' => $remoteError === null ? 'success' : 'error',
                'message' => $remoteError ?? 'GitHub y MySQL cloud están conectados.',
            ],
        ]);
    }

    if ($path === '/history-backup-status' && $method === 'GET') {
        jsonResponse(['status' => githubBackupStatus()]);
    }

    if ($path === '/history-backups/download' && $method === 'POST') {
        $payload = requestBody();
        $month = trim((string)($payload['month'] ?? ''));
        $download = githubDownloadMonth($month);
        mutateState(function (array &$state) use ($download): array {
            $incoming = $download['state'];
            foreach (['branches', 'barbers', 'services', 'sales', 'closures', 'expenses'] as $key) {
                $state[$key] = mergeById($state[$key] ?? [], $incoming[$key] ?? []);
            }
            $state['settings'] = array_merge(
                $state['settings'] ?? [],
                $incoming['settings'] ?? []
            );
            $state = normalizeState($state);
            return ['ok' => true];
        });
        $uploadsDirectory = dirname(__DIR__) . '/uploads';
        if (!is_dir($uploadsDirectory)) {
            @mkdir($uploadsDirectory, 0755, true);
        }
        foreach ($download['proofs'] as $filename => $content) {
            file_put_contents($uploadsDirectory . '/' . $filename, $content, LOCK_EX);
        }
        jsonResponse([
            'ok' => true,
            'month' => $month,
            'downloaded' => $download['files'],
            'skipped' => 0,
            'proofs' => count($download['proofs']),
        ]);
    }

    if ($path === '/history-backups/upload' && $method === 'POST') {
        $payload = requestBody();
        $date = trim((string)($payload['date'] ?? todayKey()));
        $backup = githubBackupWithStatus($date);
        jsonResponse([
            'ok' => true,
            'backup_date' => $date,
            'commit' => $backup['commit'],
            'proofs_uploaded' => $backup['proofs_uploaded'],
            'message' => "Los datos del $date se guardaron correctamente en GitHub.",
        ]);
    }

    if ($path === '/barbers' && $method === 'POST') {
        $payload = requestBody();
        $barber = mutateState(function (array &$state) use ($payload, $branchId): array {
            $name = requiredName($payload['name'] ?? '', 'barbero');
            $barber = [
                'id' => newId('barbero-'),
                'name' => $name,
                'active' => true,
                'branch_id' => $branchId,
                'commission_rate' => strtolower($name) === 'omar' ? 0.6 : 0.5,
            ];
            array_unshift($state['barbers'], $barber);
            return $barber;
        });
        jsonResponse(['barber' => $barber], 201);
    }

    if (preg_match('#^/barbers/([^/]+)(/delete)?$#', $path, $match) && $method === 'POST') {
        $barberId = rawurldecode($match[1]);
        $deleting = !empty($match[2]);
        $payload = requestBody();
        $result = mutateState(function (array &$state) use ($barberId, $branchId, $deleting, $payload): array {
            $index = findIndex($state['barbers'], $barberId);
            if ($index < 0 || ($state['barbers'][$index]['branch_id'] ?? '') !== $branchId) {
                throw new HttpError('Barbero no encontrado.', 404);
            }
            if ($deleting) {
                array_splice($state['barbers'], $index, 1);
                return ['deleted' => $barberId];
            }
            $state['barbers'][$index]['name'] = requiredName($payload['name'] ?? '', 'barbero');
            return ['barber' => $state['barbers'][$index]];
        });
        jsonResponse($result);
    }

    if ($path === '/services' && $method === 'POST') {
        $payload = requestBody();
        $service = mutateState(function (array &$state) use ($payload, $branchId): array {
            $service = [
                'id' => newId('servicio-'),
                'name' => requiredName($payload['name'] ?? '', 'servicio'),
                'price' => money($payload['price'] ?? 0),
                'branch_id' => $branchId,
            ];
            array_unshift($state['services'], $service);
            return $service;
        });
        jsonResponse(['service' => $service], 201);
    }

    if (preg_match('#^/services/([^/]+)(/delete)?$#', $path, $match) && $method === 'POST') {
        $serviceId = rawurldecode($match[1]);
        $deleting = !empty($match[2]);
        $payload = requestBody();
        $result = mutateState(function (array &$state) use ($serviceId, $branchId, $deleting, $payload): array {
            $index = findIndex($state['services'], $serviceId);
            if ($index < 0 || ($state['services'][$index]['branch_id'] ?? '') !== $branchId) {
                throw new HttpError('Servicio no encontrado.', 404);
            }
            if ($deleting) {
                array_splice($state['services'], $index, 1);
                return ['deleted' => $serviceId];
            }
            $state['services'][$index]['name'] = requiredName($payload['name'] ?? '', 'servicio');
            $state['services'][$index]['price'] = money($payload['price'] ?? 0);
            return ['service' => $state['services'][$index]];
        });
        jsonResponse($result);
    }

    if ($path === '/expenses' && $method === 'POST') {
        $payload = requestBody();
        $expense = mutateState(function (array &$state) use ($payload, $branchId): array {
            $date = trim((string)($payload['date'] ?? todayKey()));
            if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date) || $date > todayKey()) {
                throw new HttpError('Selecciona una fecha válida para el gasto.');
            }
            $type = ($payload['expense_type'] ?? 'shop') === 'barber' ? 'barber' : 'shop';
            $barber = null;
            if ($type === 'barber') {
                $index = findIndex($state['barbers'], (string)($payload['barber_id'] ?? ''));
                if ($index < 0 || ($state['barbers'][$index]['branch_id'] ?? '') !== $branchId) {
                    throw new HttpError('Selecciona el barbero al que se le descontará.');
                }
                $barber = $state['barbers'][$index];
            }
            $expense = [
                'id' => newId('gasto-'),
                'date' => $date,
                'created_at' => nowIso(),
                'branch_id' => $branchId,
                'description' => requiredName($payload['description'] ?? '', 'gasto'),
                'amount' => money($payload['amount'] ?? 0),
                'expense_type' => $type,
                'barber_id' => $barber['id'] ?? null,
                'barber_name' => $barber['name'] ?? null,
            ];
            array_unshift($state['expenses'], $expense);
            return $expense;
        });
        jsonResponse(['expense' => $expense], 201);
    }

    if (preg_match('#^/expenses/([^/]+)/delete$#', $path, $match) && $method === 'POST') {
        requestBody();
        $expenseId = rawurldecode($match[1]);
        $result = mutateState(function (array &$state) use ($expenseId, $branchId): array {
            $index = findIndex($state['expenses'], $expenseId);
            if ($index < 0 || ($state['expenses'][$index]['branch_id'] ?? '') !== $branchId) {
                throw new HttpError('Gasto no encontrado.', 404);
            }
            array_splice($state['expenses'], $index, 1);
            return ['deleted' => $expenseId];
        });
        jsonResponse($result);
    }

    if ($path === '/sales' && $method === 'POST') {
        $payload = requestBody();
        $result = mutateState(function (array &$state) use ($payload, $branchId): array {
            $requestId = trim((string)($payload['client_request_id'] ?? ''));
            if ($requestId !== '' && !preg_match('/^[A-Za-z0-9-]{8,160}$/', $requestId)) {
                throw new HttpError('El identificador local de la venta no es válido.');
            }
            foreach ($state['sales'] as $existing) {
                if (
                    $requestId !== '' &&
                    ($existing['client_request_id'] ?? '') === $requestId &&
                    ($existing['branch_id'] ?? '') === $branchId
                ) {
                    return ['sale' => $existing, 'already_synchronized' => true];
                }
            }
            $payment = (string)($payload['payment_method'] ?? '');
            if (!in_array($payment, ['cash', 'nequi'], true)) {
                throw new HttpError('Selecciona efectivo o Nequi.');
            }
            $date = trim((string)($payload['sale_date'] ?? todayKey()));
            $time = trim((string)($payload['sale_time'] ?? date('H:i')));
            if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date) || $date > todayKey()) {
                throw new HttpError('Selecciona una fecha válida para la venta.');
            }
            if (!preg_match('/^(?:[01]\d|2[0-3]):[0-5]\d$/', $time)) {
                throw new HttpError('Selecciona una hora válida para la venta.');
            }
            $closureIndex = findClosureIndex($state, $date, $branchId);
            if ($date === todayKey() && $closureIndex >= 0 && ($state['closures'][$closureIndex]['status'] ?? '') === 'closed') {
                throw new HttpError('La caja de esta barbería ya está cerrada.');
            }
            $amount = money($payload['amount'] ?? 0);
            $kind = ($payload['sale_kind'] ?? 'service') === 'product' ? 'product' : 'service';
            $barber = null;
            if ($kind === 'product') {
                $serviceId = 'nevera';
                $serviceName = requiredName($payload['custom_service_name'] ?? '', 'producto de nevera');
                $listedPrice = null;
                $baseAmount = $amount;
                $tipAmount = 0;
            } else {
                $barberIndex = findIndex($state['barbers'], (string)($payload['barber_id'] ?? ''));
                if ($barberIndex < 0 || ($state['barbers'][$barberIndex]['branch_id'] ?? '') !== $branchId) {
                    throw new HttpError('Barbero no encontrado.');
                }
                $barber = $state['barbers'][$barberIndex];
                $custom = trim((string)($payload['custom_service_name'] ?? ''));
                if ($custom !== '') {
                    $serviceId = 'especial';
                    $serviceName = requiredName($custom, 'servicio especial');
                    $listedPrice = null;
                    $baseAmount = $amount;
                    $tipAmount = 0;
                } else {
                    $serviceIndex = findIndex($state['services'], (string)($payload['service_id'] ?? ''));
                    if ($serviceIndex < 0 || ($state['services'][$serviceIndex]['branch_id'] ?? '') !== $branchId) {
                        throw new HttpError('Servicio no encontrado.');
                    }
                    $service = $state['services'][$serviceIndex];
                    $serviceId = $service['id'];
                    $serviceName = $service['name'];
                    $listedPrice = (int)$service['price'];
                    $tipAmount = max(0, $amount - $listedPrice);
                    $baseAmount = $amount - $tipAmount;
                }
            }
            $saleId = newId();
            $proof = null;
            if ($payment === 'nequi') {
                $proof = saveProof((string)($payload['proof_image'] ?? ''), $saleId);
                if ($proof === null) {
                    throw new HttpError('El comprobante de Nequi es obligatorio.');
                }
            }
            $branchIndex = findIndex($state['branches'], $branchId);
            $sale = [
                'id' => $saleId,
                'client_request_id' => $requestId ?: null,
                'created_at' => $date . 'T' . $time . ':00',
                'branch_id' => $branchId,
                'branch_name' => $state['branches'][$branchIndex]['name'] ?? 'Barbería',
                'sale_kind' => $kind,
                'barber_id' => $barber['id'] ?? null,
                'barber_name' => $barber['name'] ?? 'Barbería · Nevera',
                'service_id' => $serviceId,
                'service_name' => $serviceName,
                'amount' => $amount,
                'base_amount' => $baseAmount,
                'listed_price' => $listedPrice,
                'tip_amount' => $tipAmount,
                'payment_method' => $payment,
                'proof_url' => $proof,
                'proof_note' => substr(trim((string)($payload['proof_note'] ?? '')), 0, 120),
                'client_name' => substr(trim((string)($payload['client_name'] ?? '')), 0, 80),
                'status' => $payment === 'cash' ? 'confirmed' : 'pending_review',
            ];
            array_unshift($state['sales'], $sale);
            if ($branchIndex >= 0) {
                refreshClosure($state, $date, $state['branches'][$branchIndex]);
            }
            return ['sale' => $sale];
        });
        jsonResponse($result, isset($result['already_synchronized']) ? 200 : 201);
    }

    if (preg_match('#^/sales/([^/]+)(?:/(delete|status))?$#', $path, $match) && $method === 'POST') {
        $saleId = rawurldecode($match[1]);
        $action = $match[2] ?? 'update';
        $payload = requestBody();
        $result = mutateState(function (array &$state) use ($saleId, $action, $payload, $branchId): array {
            $index = findIndex($state['sales'], $saleId);
            if ($index < 0 || ($state['sales'][$index]['branch_id'] ?? '') !== $branchId) {
                throw new HttpError('Venta no encontrada.', 404);
            }
            $sale = $state['sales'][$index];
            $date = itemDay($sale);
            $branchIndex = findIndex($state['branches'], $branchId);
            if ($action === 'delete') {
                array_splice($state['sales'], $index, 1);
                if ($branchIndex >= 0) {
                    refreshClosure($state, $date, $state['branches'][$branchIndex]);
                }
                return ['deleted' => $saleId];
            }
            if ($action === 'status') {
                $status = (string)($payload['status'] ?? '');
                if (!in_array($status, ['confirmed', 'pending_review', 'rejected', 'annulled'], true)) {
                    throw new HttpError('Estado de venta no permitido.');
                }
                $sale['status'] = $status;
                $sale['reviewed_at'] = nowIso();
            } else {
                $amount = money($payload['amount'] ?? 0);
                $payment = (string)($payload['payment_method'] ?? '');
                if (!in_array($payment, ['cash', 'nequi'], true)) {
                    throw new HttpError('Selecciona efectivo o Nequi.');
                }
                $product = ($sale['sale_kind'] ?? '') === 'product' || empty($sale['barber_id']);
                if (!$product) {
                    $barberIndex = findIndex($state['barbers'], (string)($payload['barber_id'] ?? ''));
                    if ($barberIndex >= 0 && ($state['barbers'][$barberIndex]['branch_id'] ?? '') === $branchId) {
                        $sale['barber_id'] = $state['barbers'][$barberIndex]['id'];
                        $sale['barber_name'] = $state['barbers'][$barberIndex]['name'];
                    } elseif (($payload['barber_id'] ?? '') !== ($sale['barber_id'] ?? '')) {
                        throw new HttpError('Selecciona un barbero válido.');
                    }
                }
                if ($payment === 'nequi' && empty($sale['proof_url'])) {
                    throw new HttpError('No puedes cambiar a Nequi una venta sin comprobante.');
                }
                $listed = $product ? null : ($sale['listed_price'] ?? null);
                $tip = $listed ? max(0, $amount - (int)$listed) : 0;
                $sale['sale_kind'] = $product ? 'product' : 'service';
                $sale['barber_id'] = $product ? null : $sale['barber_id'];
                $sale['barber_name'] = $product ? 'Barbería · Nevera' : $sale['barber_name'];
                $sale['service_name'] = requiredName($payload['service_name'] ?? '', $product ? 'producto' : 'servicio');
                $sale['amount'] = $amount;
                $sale['base_amount'] = $amount - $tip;
                $sale['tip_amount'] = $tip;
                $sale['payment_method'] = $payment;
                $sale['client_name'] = substr(trim((string)($payload['client_name'] ?? '')), 0, 80);
                $sale['proof_note'] = substr(trim((string)($payload['proof_note'] ?? '')), 0, 120);
                $sale['updated_at'] = nowIso();
                if ($payment === 'cash' && ($sale['status'] ?? '') === 'pending_review') {
                    $sale['status'] = 'confirmed';
                }
            }
            $state['sales'][$index] = $sale;
            if ($branchIndex >= 0) {
                refreshClosure($state, $date, $state['branches'][$branchIndex]);
            }
            return ['sale' => $sale];
        });
        jsonResponse($result);
    }

    if ($path === '/day/close' && $method === 'POST') {
        $payload = requestBody();
        $result = mutateState(function (array &$state) use ($payload, $branchId): array {
            $date = todayKey();
            $branchIndex = findIndex($state['branches'], $branchId);
            if ($branchIndex < 0) {
                throw new HttpError('Barbería no encontrada.');
            }
            foreach ($state['sales'] as $sale) {
                if (
                    itemDay($sale) === $date &&
                    ($sale['branch_id'] ?? '') === $branchId &&
                    ($sale['status'] ?? '') === 'pending_review'
                ) {
                    throw new HttpError('Confirma o rechaza los pagos Nequi pendientes antes de cerrar.');
                }
            }
            $counted = max(0, (int)round((float)($payload['counted_cash'] ?? 0)));
            $snapshot = closureSnapshot($state, $date, $counted, $state['branches'][$branchIndex]);
            $index = findClosureIndex($state, $date, $branchId);
            if ($index >= 0 && ($state['closures'][$index]['status'] ?? '') === 'closed') {
                throw new HttpError('El día ya se encuentra cerrado.');
            }
            if ($index >= 0) {
                $closure = array_merge($state['closures'][$index], $snapshot);
                $closure['events'] = array_merge($closure['events'] ?? [], [closureEvent($snapshot)]);
                $state['closures'][$index] = $closure;
            } else {
                $closure = array_merge(['id' => newId()], $snapshot);
                $closure['events'] = [closureEvent($snapshot)];
                array_unshift($state['closures'], $closure);
            }
            return ['closure' => $closure, 'backup_date' => $date];
        });
        try {
            githubBackupWithStatus((string)$result['backup_date']);
        } catch (Throwable $backupError) {
            error_log('GitHub backup after close: ' . $backupError->getMessage());
        }
        jsonResponse($result);
    }

    if ($path === '/day/reopen' && $method === 'POST') {
        requestBody();
        $result = mutateState(function (array &$state) use ($branchId): array {
            $date = todayKey();
            $index = findClosureIndex($state, $date, $branchId);
            if ($index < 0 || ($state['closures'][$index]['status'] ?? '') !== 'closed') {
                throw new HttpError('No hay un cierre activo para reabrir.');
            }
            $state['closures'][$index]['status'] = 'reopened';
            $state['closures'][$index]['reopened_at'] = nowIso();
            $state['closures'][$index]['events'] = array_merge(
                $state['closures'][$index]['events'] ?? [],
                [['type' => 'reopened', 'at' => $state['closures'][$index]['reopened_at']]]
            );
            return ['closure' => $state['closures'][$index], 'backup_date' => $date];
        });
        try {
            githubBackupWithStatus((string)$result['backup_date']);
        } catch (Throwable $backupError) {
            error_log('GitHub backup after reopen: ' . $backupError->getMessage());
        }
        jsonResponse($result);
    }

    throw new HttpError('Ruta no encontrada.', 404);
} catch (HttpError $error) {
    jsonResponse(['error' => $error->getMessage()], $error->status);
} catch (Throwable $error) {
    error_log((string)$error);
    jsonResponse(
        ['error' => 'El servidor cloud encontró un error interno. Revisa config.php y MySQL.'],
        500
    );
}
