<?php
declare(strict_types=1);
require __DIR__ . '/lib.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function fail_json(int $status, string $code, string $message): void {
    http_response_code($status);
    echo json_encode(['ok'=>false,'code'=>$code,'message'=>$message], JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
    exit;
}

try {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail_json(405,'method_not_allowed','Chỉ hỗ trợ POST.');
    $raw = file_get_contents('php://input');
    $req = json_decode(is_string($raw)?$raw:'', true, 128, JSON_THROW_ON_ERROR);
    if (!is_array($req)) fail_json(400,'invalid_request','Dữ liệu không hợp lệ.');

    $action = (string)($req['action'] ?? 'activate');
    $game = (string)($req['game'] ?? '');
    $featureID = (string)($req['feature_id'] ?? '');
    $device = trim((string)($req['device_id'] ?? ''));
    if (!valid_game($game) || !preg_match('/^[A-Za-z0-9_-]{1,64}$/',$featureID) || $device === '' || strlen($device) > 200) {
        fail_json(400,'invalid_request','Thiếu hoặc sai thông tin thiết bị/chức năng.');
    }
    $deviceHash = device_hash($device);
    $data = read_data();
    $features =& $data['games'][$game]['features'];
    $featureIndex = find_feature_index($features, $featureID);

    if ($action === 'restore') {
        $accessToken = (string)($req['access_token'] ?? '');
        $session = read_access_session($accessToken);
        if (!$session || !hash_equals((string)($session['device_hash']??''), $deviceHash) ||
            (string)($session['game']??'') !== $game || (string)($session['feature_id']??'') !== $featureID) {
            fail_json(401,'invalid_session','Phiên khôi phục không hợp lệ.');
        }
        $dl = issue_download_token((array)$session['original_file'], 'restore');
        echo json_encode([
            'ok'=>true,'action'=>'restore','download_url'=>$dl['url'],'download_sha256'=>$dl['sha256'],
            'expires_in'=>$dl['expires_in'],'destination_path'=>(string)$session['destination_path']
        ], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
        exit;
    }

    if ($action !== 'activate') fail_json(400,'invalid_action','Thao tác không hợp lệ.');
    if ($featureIndex === null) fail_json(404,'feature_not_found','Không tìm thấy chức năng.');
    $feature =& $features[$featureIndex];
    if (empty($feature['enabled'])) fail_json(403,'feature_disabled','Chức năng đang tắt trên máy chủ.');

    $matchedKeyIndex = null;
    $accessToken = trim((string)($req['access_token'] ?? ''));
    if ($accessToken !== '') {
        $session = read_access_session($accessToken);
        if ($session && hash_equals((string)($session['device_hash']??''), $deviceHash) &&
            (string)($session['game']??'') === $game && (string)($session['feature_id']??'') === $featureID) {
            $matchedKeyIndex = find_key_index((array)($feature['keys']??[]), (string)($session['key_id']??''));
        }
        if ($matchedKeyIndex === null) fail_json(401,'key_required','Cần nhập lại key cho chức năng này.');
    } else {
        $plainKey = normalize_key((string)($req['key'] ?? ''));
        if ($plainKey === '' || strlen($plainKey) > 160) fail_json(401,'key_required','Vui lòng nhập key.');
        $hash = key_hash($plainKey);
        foreach ((array)($feature['keys']??[]) as $i => $candidate) {
            if (is_array($candidate) && isset($candidate['hash']) && hash_equals((string)$candidate['hash'], $hash)) { $matchedKeyIndex=(int)$i; break; }
        }
        if ($matchedKeyIndex === null) fail_json(401,'invalid_key','Key không hợp lệ hoặc không thuộc chức năng này.');
    }

    $key =& $feature['keys'][$matchedKeyIndex];
    if (empty($key['enabled'])) fail_json(403,'key_disabled','Key đã bị khóa.');
    if (key_is_expired($key)) fail_json(403,'key_expired','Key đã hết hạn.');

    $devices = is_array($key['devices']??null) ? $key['devices'] : [];
    $foundDevice = false;
    foreach ($devices as $d) if (is_array($d) && hash_equals((string)($d['hash']??''), $deviceHash)) { $foundDevice=true; break; }
    $maxDevices = max(1, min(100, (int)($key['max_devices']??1)));
    if (!$foundDevice) {
        if (count($devices) >= $maxDevices) fail_json(403,'device_limit','Key đã đủ số lượng thiết bị.');
        $matchedKeyID = (string)($key['id'] ?? '');
        $devices[] = ['hash'=>$deviceHash,'added_at'=>gmdate('c'),'label'=>substr($device,0,24)];
        $key['devices'] = $devices;
        save_data($data);
        $data = read_data();
        $features =& $data['games'][$game]['features'];
        $featureIndex = find_feature_index($features,$featureID);
        if ($featureIndex === null) fail_json(404,'feature_not_found','Không tìm thấy chức năng.');
        $feature =& $features[$featureIndex];
        $matchedKeyIndex = find_key_index((array)$feature['keys'], $matchedKeyID);
        if ($matchedKeyIndex === null) fail_json(401,'key_required','Cần nhập lại key cho chức năng này.');
        $key =& $feature['keys'][$matchedKeyIndex];
    }

    if ($accessToken === '') $accessToken = issue_access_session($game,$feature,$key,$deviceHash);
    $dl = issue_download_token((array)$feature['active_file'], 'active');
    echo json_encode([
        'ok'=>true,'action'=>'activate','access_token'=>$accessToken,
        'download_url'=>$dl['url'],'download_sha256'=>$dl['sha256'],'expires_in'=>$dl['expires_in'],
        'destination_path'=>(string)$feature['destination_path'],
        'key_expires_at'=>(string)($key['expires_at']??''),
        'max_devices'=>$maxDevices,'device_count'=>count((array)($key['devices']??[])),
    ], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
} catch (JsonException $e) {
    fail_json(400,'invalid_json','Dữ liệu JSON không hợp lệ.');
} catch (Throwable $e) {
    fail_json(500,'server_error','Máy chủ gặp lỗi.');
}
