<?php
declare(strict_types=1);

$indexFile = __DIR__ . '/index.html';
if (!is_file($indexFile)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Falta index.html en la carpeta htdocs.';
    exit;
}

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-cache, must-revalidate');
readfile($indexFile);
