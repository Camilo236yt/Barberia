<?php
declare(strict_types=1);

function githubSettings(): array
{
    $cfg = config();
    $repository = trim((string)($cfg['Camilo236yt/Barberia'] ?? ''));
    $token = trim((string)($cfg['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'] ?? ''));
    $branch = trim((string)($cfg['historial-datos'] ?? 'historial-datos'));
    if (
        !preg_match('#^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$#', $repository) ||
        $token === '' ||
        str_contains($token, 'CAMBIA_') ||
        !preg_match('/^[A-Za-z0-9._\/-]{1,120}$/', $branch)
    ) {
        throw new HttpError(
            'Falta configurar GITHUB_REPOSITORY y GITHUB_TOKEN en api/config.php.',
            503
        );
    }
    return [
        'repository' => $repository,
        'token' => $token,
        'branch' => $branch,
    ];
}

function githubBackupStatus(): array
{
    $state = readState();
    $saved = $state['settings']['github_backup_status'] ?? null;
    if (is_array($saved)) {
        return $saved;
    }
    return [
        'state' => 'queued',
        'progress' => 0,
        'message' => 'GitHub todavía no ha recibido un respaldo cloud.',
        'date' => '',
        'at' => nowIso(),
    ];
}

function setGithubBackupStatus(string $stateName, string $date, string $message): void
{
    mutateState(function (array &$state) use ($stateName, $date, $message): array {
        $state['settings']['github_backup_status'] = [
            'state' => $stateName,
            'progress' => in_array($stateName, ['success', 'error'], true) ? 100 : 55,
            'message' => $message,
            'date' => $date,
            'at' => nowIso(),
        ];
        return ['ok' => true];
    });
}

function githubBackupWithStatus(string $date): array
{
    setGithubBackupStatus('uploading', $date, 'Subiendo el respaldo a GitHub...');
    try {
        $result = githubBackupDate(readState(), $date);
        setGithubBackupStatus(
            'success',
            $date,
            "Historial $date respaldado correctamente en GitHub."
        );
        return $result;
    } catch (Throwable $error) {
        $message = $error instanceof HttpError
            ? $error->getMessage()
            : 'GitHub no pudo completar el respaldo.';
        setGithubBackupStatus('error', $date, $message);
        throw $error;
    }
}

function githubRequest(
    string $method,
    string $path,
    ?array $payload = null,
    array $acceptedStatuses = [200]
): array {
    $settings = githubSettings();
    $url = 'https://api.github.com/repos/' . $settings['repository'] . $path;
    $headers = [
        'Accept: application/vnd.github+json',
        'Authorization: Bearer ' . $settings['token'],
        'User-Agent: Capitan-Gold-Cloud',
        'X-GitHub-Api-Version: 2026-03-10',
    ];
    $body = $payload === null
        ? null
        : json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($body !== null) {
        $headers[] = 'Content-Type: application/json';
    }

    $status = 0;
    $responseBody = '';
    if (function_exists('curl_init')) {
        $curl = curl_init($url);
        if ($curl === false) {
            throw new HttpError('No se pudo preparar la conexión con GitHub.', 502);
        }
        curl_setopt_array($curl, [
            CURLOPT_CUSTOMREQUEST => strtoupper($method),
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 12,
            CURLOPT_TIMEOUT => 45,
            CURLOPT_FOLLOWLOCATION => false,
        ]);
        if ($body !== null) {
            curl_setopt($curl, CURLOPT_POSTFIELDS, $body);
        }
        $raw = curl_exec($curl);
        if ($raw === false) {
            $message = curl_error($curl);
            curl_close($curl);
            throw new HttpError("No se pudo conectar con GitHub: $message", 502);
        }
        $status = (int)curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        $responseBody = (string)$raw;
        curl_close($curl);
    } else {
        $context = stream_context_create([
            'http' => [
                'method' => strtoupper($method),
                'header' => implode("\r\n", $headers),
                'content' => $body ?? '',
                'ignore_errors' => true,
                'timeout' => 45,
            ],
        ]);
        $raw = @file_get_contents($url, false, $context);
        $responseBody = $raw === false ? '' : (string)$raw;
        foreach ($http_response_header ?? [] as $header) {
            if (preg_match('#^HTTP/\S+\s+(\d{3})#', $header, $match)) {
                $status = (int)$match[1];
            }
        }
        if ($status === 0) {
            throw new HttpError('InfinityFree no pudo conectarse con GitHub.', 502);
        }
    }

    $decoded = $responseBody === '' ? [] : json_decode($responseBody, true);
    $data = is_array($decoded) ? $decoded : [];
    if (!in_array($status, $acceptedStatuses, true)) {
        $githubMessage = trim((string)($data['message'] ?? ''));
        if (in_array($status, [401, 403], true)) {
            throw new HttpError(
                'GitHub rechazó la clave. Revisa que el token tenga permiso Contents: Read and write.',
                502
            );
        }
        if ($status === 404) {
            throw new HttpError(
                'GitHub no encontró el repositorio o la rama historial-datos.',
                502
            );
        }
        throw new HttpError(
            $githubMessage !== ''
                ? "GitHub respondió: $githubMessage"
                : "GitHub respondió con el estado $status.",
            502
        );
    }
    return ['status' => $status, 'data' => $data];
}

function githubSnapshot(): array
{
    $settings = githubSettings();
    $branch = rawurlencode($settings['branch']);
    $ref = githubRequest('GET', "/git/ref/heads/$branch")['data'];
    $headSha = (string)($ref['object']['sha'] ?? '');
    if ($headSha === '') {
        throw new HttpError('GitHub no devolvió el estado de historial-datos.', 502);
    }
    $commit = githubRequest('GET', "/git/commits/$headSha")['data'];
    $treeSha = (string)($commit['tree']['sha'] ?? '');
    if ($treeSha === '') {
        throw new HttpError('GitHub no devolvió el árbol del respaldo.', 502);
    }
    $tree = githubRequest('GET', "/git/trees/$treeSha?recursive=1")['data'];
    $entries = [];
    foreach ($tree['tree'] ?? [] as $entry) {
        if (($entry['type'] ?? '') === 'blob' && isset($entry['path'], $entry['sha'])) {
            $entries[(string)$entry['path']] = (string)$entry['sha'];
        }
    }
    return [
        'head_sha' => $headSha,
        'tree_sha' => $treeSha,
        'entries' => $entries,
    ];
}

function githubCreateBlob(string $content): string
{
    $result = githubRequest('POST', '/git/blobs', [
        'content' => base64_encode($content),
        'encoding' => 'base64',
    ], [201])['data'];
    $sha = (string)($result['sha'] ?? '');
    if ($sha === '') {
        throw new HttpError('GitHub no confirmó el archivo del respaldo.', 502);
    }
    return $sha;
}

function githubBlobContent(string $sha): string
{
    if (!preg_match('/^[a-f0-9]{40,64}$/', $sha)) {
        throw new HttpError('GitHub devolvió un archivo no válido.', 502);
    }
    $blob = githubRequest('GET', "/git/blobs/$sha")['data'];
    $encoded = preg_replace('/\s+/', '', (string)($blob['content'] ?? ''));
    $content = base64_decode((string)$encoded, true);
    if ($content === false) {
        throw new HttpError('No se pudo verificar un archivo descargado de GitHub.', 502);
    }
    return $content;
}

function githubDayPayload(array $state, string $date): array
{
    return [
        'version' => 1,
        'month' => substr($date, 0, 7),
        'date' => $date,
        'generated_at' => nowIso(),
        'branches' => $state['branches'],
        'barbers' => $state['barbers'],
        'services' => $state['services'],
        'settings' => $state['settings'],
        'sales' => array_values(array_filter(
            $state['sales'],
            fn(array $sale): bool => itemDay($sale) === $date
        )),
        'closures' => array_values(array_filter(
            $state['closures'],
            fn(array $closure): bool => ($closure['date'] ?? '') === $date
        )),
        'expenses' => array_values(array_filter(
            $state['expenses'],
            fn(array $expense): bool => ($expense['date'] ?? '') === $date
        )),
    ];
}

function githubBackupDate(array $state, string $date): array
{
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date) || $date > todayKey()) {
        throw new HttpError('Selecciona una fecha válida para respaldar.');
    }
    $state = normalizeState($state);
    unset($state['settings']['github_backup_status']);
    $day = githubDayPayload($state, $date);
    if (
        count($day['sales']) === 0 &&
        count($day['closures']) === 0 &&
        count($day['expenses']) === 0
    ) {
        throw new HttpError("No hay datos guardados para el $date.");
    }

    $stateJson = json_encode(
        $state,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT
    );
    $dayJson = json_encode(
        $day,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT
    );
    if ($stateJson === false || $dayJson === false) {
        throw new HttpError('No se pudo preparar el JSON del respaldo.', 500);
    }
    $stateBlob = githubCreateBlob($stateJson);
    $dayBlob = githubCreateBlob($dayJson);

    $snapshot = githubSnapshot();
    $treeItems = [
        [
            'path' => 'cloud/estado.json',
            'mode' => '100644',
            'type' => 'blob',
            'sha' => $stateBlob,
        ],
        [
            'path' => 'cloud/dias/' . substr($date, 0, 7) . "/$date.json",
            'mode' => '100644',
            'type' => 'blob',
            'sha' => $dayBlob,
        ],
    ];
    $proofCount = 0;
    $uploadsDirectory = dirname(__DIR__) . '/uploads';
    $proofNames = [];
    foreach ($day['sales'] as $sale) {
        $proofUrl = (string)($sale['proof_url'] ?? '');
        if (str_starts_with($proofUrl, '/uploads/')) {
            $proofNames[basename($proofUrl)] = true;
        }
    }
    foreach (array_keys($proofNames) as $filename) {
        if (!preg_match('/^[A-Za-z0-9._-]{1,180}$/', $filename)) {
            continue;
        }
        $source = $uploadsDirectory . '/' . $filename;
        if (!is_file($source)) {
            continue;
        }
        $content = file_get_contents($source);
        if ($content === false) {
            continue;
        }
        $path = "cloud/uploads/$filename";
        $gitSha = sha1('blob ' . strlen($content) . "\0" . $content);
        if (($snapshot['entries'][$path] ?? '') === $gitSha) {
            continue;
        }
        $treeItems[] = [
            'path' => $path,
            'mode' => '100644',
            'type' => 'blob',
            'sha' => githubCreateBlob($content),
        ];
        $proofCount++;
    }

    for ($attempt = 1; $attempt <= 3; $attempt++) {
        if ($attempt > 1) {
            $snapshot = githubSnapshot();
        }
        $tree = githubRequest('POST', '/git/trees', [
            'base_tree' => $snapshot['tree_sha'],
            'tree' => $treeItems,
        ], [201])['data'];
        $treeSha = (string)($tree['sha'] ?? '');
        $commit = githubRequest('POST', '/git/commits', [
            'message' => "Respaldo cloud $date",
            'tree' => $treeSha,
            'parents' => [$snapshot['head_sha']],
        ], [201])['data'];
        $commitSha = (string)($commit['sha'] ?? '');
        $settings = githubSettings();
        $branch = rawurlencode($settings['branch']);
        $updated = githubRequest('PATCH', "/git/refs/heads/$branch", [
            'sha' => $commitSha,
            'force' => false,
        ], [200, 409, 422]);
        if ($updated['status'] === 200) {
            return [
                'ok' => true,
                'backup_date' => $date,
                'commit' => $commitSha,
                'proofs_uploaded' => $proofCount,
            ];
        }
    }
    throw new HttpError('GitHub recibió otro respaldo al mismo tiempo. Intenta nuevamente.', 409);
}

function githubRemoteMonths(): array
{
    $months = [];
    foreach (array_keys(githubSnapshot()['entries']) as $path) {
        if (preg_match('#^cloud/dias/(\d{4}-\d{2})/\d{4}-\d{2}-\d{2}\.json$#', $path, $match)) {
            $months[$match[1]] = true;
        }
    }
    $result = array_keys($months);
    rsort($result);
    return $result;
}

function githubDownloadMonth(string $month): array
{
    if (!preg_match('/^\d{4}-\d{2}$/', $month)) {
        throw new HttpError('El mes debe tener el formato AAAA-MM.');
    }
    $snapshot = githubSnapshot();
    $dayEntries = [];
    foreach ($snapshot['entries'] as $path => $sha) {
        if (preg_match('#^cloud/dias/' . preg_quote($month, '#') . '/\d{4}-\d{2}-\d{2}\.json$#', $path)) {
            $dayEntries[$path] = $sha;
        }
    }
    ksort($dayEntries);
    if (count($dayEntries) === 0) {
        throw new HttpError("No hay respaldos cloud de $month en GitHub.", 404);
    }

    $incoming = [
        'branches' => [],
        'barbers' => [],
        'services' => [],
        'sales' => [],
        'closures' => [],
        'expenses' => [],
        'settings' => [],
    ];
    foreach ($dayEntries as $sha) {
        $decoded = json_decode(githubBlobContent($sha), true);
        if (!is_array($decoded)) {
            throw new HttpError('Uno de los respaldos de GitHub está dañado.', 502);
        }
        foreach (['branches', 'barbers', 'services', 'sales', 'closures', 'expenses'] as $key) {
            $incoming[$key] = mergeById($incoming[$key], $decoded[$key] ?? []);
        }
        $incoming['settings'] = array_merge(
            $incoming['settings'],
            is_array($decoded['settings'] ?? null) ? $decoded['settings'] : []
        );
    }

    $proofs = [];
    foreach ($incoming['sales'] as $sale) {
        $proofUrl = (string)($sale['proof_url'] ?? '');
        $filename = basename($proofUrl);
        $path = "cloud/uploads/$filename";
        if (
            str_starts_with($proofUrl, '/uploads/') &&
            preg_match('/^[A-Za-z0-9._-]{1,180}$/', $filename) &&
            isset($snapshot['entries'][$path])
        ) {
            $proofs[$filename] = githubBlobContent($snapshot['entries'][$path]);
        }
    }
    return [
        'state' => $incoming,
        'proofs' => $proofs,
        'files' => count($dayEntries),
    ];
}
