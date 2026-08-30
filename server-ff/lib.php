<?php
declare(strict_types=1);

function panel_settings(): array
{
    static $settings;
    if ($settings === null) {
        $settings = require __DIR__ . '/config.php';
    }
    return $settings;
}

function storage_file(): string { return __DIR__ . '/data/config.json'; }
function uploads_dir(): string { return __DIR__ . '/uploads'; }
function sessions_dir(): string { return __DIR__ . '/data/sessions'; }
function download_tokens_dir(): string { return __DIR__ . '/data/download_tokens'; }
function secret_file(): string { return __DIR__ . '/data/server-secret.key'; }

function default_data(): array
{
    return [
        'version' => 1,
        'updated_at' => gmdate('c'),
        'games' => [
            'freefire' => ['name' => 'Free Fire', 'features' => []],
            'freefiremax' => ['name' => 'Free Fire MAX', 'features' => []],
        ],
    ];
}

function ensure_directory_only(): void
{
    foreach ([__DIR__ . '/data', uploads_dir(), sessions_dir(), download_tokens_dir()] as $dir) {
        if (!is_dir($dir) && !mkdir($dir, 0755, true) && !is_dir($dir)) {
            throw new RuntimeException('Cannot create storage directory: ' . $dir);
        }
    }
}

function server_secret(): string
{
    ensure_directory_only();
    $file = secret_file();
    if (is_file($file)) {
        $secret = trim((string)file_get_contents($file));
        if (preg_match('/^[a-f0-9]{64}$/', $secret)) return $secret;
    }
    $secret = bin2hex(random_bytes(32));
    if (file_put_contents($file, $secret . PHP_EOL, LOCK_EX) === false) {
        throw new RuntimeException('Cannot create server secret.');
    }
    @chmod($file, 0600);
    return $secret;
}

function ensure_storage(): void
{
    ensure_directory_only();
    if (!is_file(storage_file())) save_data(default_data(), false);
    server_secret();
}

function read_data(): array
{
    ensure_storage();
    $raw = file_get_contents(storage_file());
    if ($raw === false) throw new RuntimeException('Cannot read configuration.');
    $data = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
    if (!is_array($data)) throw new RuntimeException('Invalid configuration.');

    foreach (['freefire', 'freefiremax'] as $game) {
        if (!isset($data['games'][$game]) || !is_array($data['games'][$game])) {
            $data['games'][$game] = default_data()['games'][$game];
        }
        if (!isset($data['games'][$game]['features']) || !is_array($data['games'][$game]['features'])) {
            $data['games'][$game]['features'] = [];
        }
        foreach ($data['games'][$game]['features'] as &$feature) {
            if (!is_array($feature)) $feature = [];
            if (!isset($feature['keys']) || !is_array($feature['keys'])) $feature['keys'] = [];
        }
        unset($feature);
    }
    return $data;
}

function save_data(array $data, bool $bumpVersion = true): void
{
    ensure_directory_only();
    if ($bumpVersion) {
        $data['version'] = max(1, (int)($data['version'] ?? 0) + 1);
        $data['updated_at'] = gmdate('c');
    }
    $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    $tmp = storage_file() . '.tmp-' . bin2hex(random_bytes(4));
    if (file_put_contents($tmp, $json . PHP_EOL, LOCK_EX) === false) throw new RuntimeException('Cannot write configuration.');
    if (!rename($tmp, storage_file())) { @unlink($tmp); throw new RuntimeException('Cannot replace configuration.'); }
}

function valid_game(string $game): bool { return in_array($game, ['freefire', 'freefiremax'], true); }

function normalize_destination_path(string $path): string
{
    $path = trim($path);
    if ($path === '' || strlen($path) > 2048 || str_starts_with($path, '/') || str_contains($path, '\\')) {
        throw new InvalidArgumentException('Đường dẫn phải là đường dẫn tương đối bên trong data game.');
    }
    $parts = array_values(array_filter(explode('/', $path), static fn($part) => $part !== ''));
    if (!$parts || count($parts) > 128) throw new InvalidArgumentException('Đường dẫn không hợp lệ.');
    foreach ($parts as $part) {
        if ($part === '.' || $part === '..' || str_contains($part, "\0")) throw new InvalidArgumentException('Đường dẫn không hợp lệ.');
    }
    return implode('/', $parts);
}

function store_upload(array $upload): array
{
    if (!isset($upload['error']) || (int)$upload['error'] === UPLOAD_ERR_NO_FILE) throw new InvalidArgumentException('NO_FILE');
    if ((int)$upload['error'] !== UPLOAD_ERR_OK) throw new RuntimeException('Upload lỗi, mã: ' . (int)$upload['error']);
    $size = (int)($upload['size'] ?? 0);
    $limit = (int)(panel_settings()['max_upload_bytes'] ?? 0);
    if ($size <= 0 || ($limit > 0 && $size > $limit)) throw new RuntimeException('File rỗng hoặc vượt giới hạn upload của panel.');
    $tmp = (string)($upload['tmp_name'] ?? '');
    if ($tmp === '' || !is_uploaded_file($tmp)) throw new RuntimeException('File upload không hợp lệ.');

    ensure_directory_only();
    $token = bin2hex(random_bytes(16)) . '.bin';
    $destination = uploads_dir() . '/' . $token;
    if (!move_uploaded_file($tmp, $destination)) throw new RuntimeException('Không thể lưu file upload.');
    @chmod($destination, 0644);
    $sha = hash_file('sha256', $destination);
    if ($sha === false) { @unlink($destination); throw new RuntimeException('Không thể tính SHA-256.'); }
    return [
        'token' => $token,
        'sha256' => $sha,
        'size' => filesize($destination) ?: $size,
        'original_name' => basename((string)($upload['name'] ?? 'file')),
    ];
}

function public_base_url(): string
{
    $configured = trim((string)(panel_settings()['public_base_url'] ?? ''));
    if ($configured !== '') {
        if (!preg_match('#^https://#i', $configured)) throw new RuntimeException('public_base_url must use HTTPS.');
        return rtrim($configured, '/');
    }
    $forwarded = strtolower(trim(explode(',', (string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? ''))[0] ?? ''));
    $https = (!empty($_SERVER['HTTPS']) && strtolower((string)$_SERVER['HTTPS']) !== 'off') || $forwarded === 'https';
    if (!$https) throw new RuntimeException('HTTPS is required. Set public_base_url in config.php.');
    $host = (string)($_SERVER['HTTP_HOST'] ?? '');
    if (!preg_match('/^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$/', $host)) throw new RuntimeException('Invalid host. Set public_base_url in config.php.');
    $script = str_replace('\\', '/', (string)($_SERVER['SCRIPT_NAME'] ?? ''));
    $dir = rtrim(str_replace('//', '/', dirname($script)), '/.');
    return 'https://' . $host . ($dir === '' ? '' : $dir);
}

function h(string $value): string { return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

function format_bytes(int $bytes): string
{
    $units = ['B', 'KB', 'MB', 'GB']; $value = (float)$bytes; $unit = 0;
    while ($value >= 1024 && $unit < count($units) - 1) { $value /= 1024; $unit++; }
    return number_format($value, $unit === 0 ? 0 : 1) . ' ' . $units[$unit];
}

function normalize_key(string $key): string { return strtoupper(trim($key)); }
function key_hash(string $key): string { return hash_hmac('sha256', normalize_key($key), server_secret()); }
function device_hash(string $device): string { return hash_hmac('sha256', trim($device), server_secret()); }

function find_feature_index(array $features, string $id): ?int
{
    foreach ($features as $index => $feature) if ((string)($feature['id'] ?? '') === $id) return (int)$index;
    return null;
}

function find_key_index(array $keys, string $id): ?int
{
    foreach ($keys as $index => $key) if ((string)($key['id'] ?? '') === $id) return (int)$index;
    return null;
}

function make_key_value(string $prefix = 'HM'): string
{
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    $chunks = [];
    for ($c = 0; $c < 3; $c++) {
        $part = '';
        for ($i = 0; $i < 5; $i++) $part .= $alphabet[random_int(0, strlen($alphabet) - 1)];
        $chunks[] = $part;
    }
    return strtoupper($prefix) . '-' . implode('-', $chunks);
}

function key_is_expired(array $key): bool
{
    $expires = trim((string)($key['expires_at'] ?? ''));
    if ($expires === '') return false;
    $ts = strtotime($expires);
    return $ts !== false && $ts < time();
}

function clean_runtime_files(): void
{
    $now = time();
    foreach ([sessions_dir(), download_tokens_dir()] as $dir) {
        foreach (glob($dir . '/*.json') ?: [] as $file) {
            if (!is_file($file)) continue;
            $raw = @file_get_contents($file);
            $obj = is_string($raw) ? json_decode($raw, true) : null;
            if (!is_array($obj)) { @unlink($file); continue; }
            $expires = (int)($obj['expires_unix'] ?? 0);
            if ($expires > 0 && $expires < $now) @unlink($file);
        }
    }
}

function write_json_atomic(string $path, array $payload): void
{
    $tmp = $path . '.tmp-' . bin2hex(random_bytes(4));
    $json = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    if (file_put_contents($tmp, $json, LOCK_EX) === false) throw new RuntimeException('Cannot write runtime token.');
    if (!rename($tmp, $path)) { @unlink($tmp); throw new RuntimeException('Cannot save runtime token.'); }
}

function issue_access_session(string $game, array $feature, array $key, string $deviceHash): string
{
    clean_runtime_files();
    $token = bin2hex(random_bytes(32));
    $keyExpires = trim((string)($key['expires_at'] ?? ''));
    $keyExpiresUnix = $keyExpires !== '' ? (strtotime($keyExpires) ?: 0) : 0;
    // Keep a rollback session long enough to restore even after a short key expires.
    $restoreUntil = max(time() + 365 * 86400, $keyExpiresUnix);
    $payload = [
        'game' => $game,
        'feature_id' => (string)$feature['id'],
        'feature_name' => (string)$feature['name'],
        'key_id' => (string)$key['id'],
        'device_hash' => $deviceHash,
        'destination_path' => (string)$feature['destination_path'],
        'active_file' => $feature['active_file'],
        'original_file' => $feature['original_file'],
        'expires_unix' => $restoreUntil,
        'created_at' => gmdate('c'),
    ];
    write_json_atomic(sessions_dir() . '/' . hash('sha256', $token) . '.json', $payload);
    return $token;
}

function read_access_session(string $token): ?array
{
    if (!preg_match('/^[a-f0-9]{64}$/', $token)) return null;
    $path = sessions_dir() . '/' . hash('sha256', $token) . '.json';
    if (!is_file($path)) return null;
    $obj = json_decode((string)file_get_contents($path), true);
    if (!is_array($obj)) return null;
    if ((int)($obj['expires_unix'] ?? 0) < time()) { @unlink($path); return null; }
    return $obj;
}

function issue_download_token(array $file, string $purpose = 'active'): array
{
    clean_runtime_files();
    $token = bin2hex(random_bytes(32));
    $expires = time() + 90;
    $payload = [
        'file_token' => (string)($file['token'] ?? ''),
        'sha256' => (string)($file['sha256'] ?? ''),
        'purpose' => $purpose,
        'expires_unix' => $expires,
        'uses' => 0,
        'max_uses' => 3,
    ];
    if (!preg_match('/^[a-f0-9]{32}\.bin$/', $payload['file_token'])) throw new RuntimeException('Invalid file token.');
    write_json_atomic(download_tokens_dir() . '/' . hash('sha256', $token) . '.json', $payload);
    return [
        'token' => $token,
        'url' => public_base_url() . '/download.php?token=' . rawurlencode($token),
        'expires_in' => 90,
        'sha256' => $payload['sha256'],
    ];
}

function read_download_token(string $token): ?array
{
    if (!preg_match('/^[a-f0-9]{64}$/', $token)) return null;
    $path = download_tokens_dir() . '/' . hash('sha256', $token) . '.json';
    if (!is_file($path)) return null;
    $obj = json_decode((string)file_get_contents($path), true);
    if (!is_array($obj)) return null;
    if ((int)($obj['expires_unix'] ?? 0) < time()) { @unlink($path); return null; }
    $uses = (int)($obj['uses'] ?? 0);
    $max = max(1, (int)($obj['max_uses'] ?? 1));
    if ($uses >= $max) { @unlink($path); return null; }
    $obj['uses'] = $uses + 1;
    write_json_atomic($path, $obj);
    return $obj;
}
