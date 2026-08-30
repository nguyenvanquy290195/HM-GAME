<?php
declare(strict_types=1);
require __DIR__ . '/lib.php';
$token = (string)($_GET['token'] ?? '');
$entry = read_download_token($token);
if (!$entry) { http_response_code(403); exit('Expired or invalid token'); }
$fileToken = (string)($entry['file_token'] ?? '');
if (!preg_match('/^[a-f0-9]{32}\.bin$/',$fileToken)) { http_response_code(400); exit('Invalid file'); }
$path = uploads_dir() . '/' . $fileToken;
if (!is_file($path)) { http_response_code(404); exit('Not found'); }
header('Content-Type: application/octet-stream');
header('Content-Length: '.(string)filesize($path));
header('Content-Disposition: attachment; filename="hm-data.bin"');
header('Cache-Control: private, no-store, max-age=0');
header('X-Content-Type-Options: nosniff');
readfile($path);
