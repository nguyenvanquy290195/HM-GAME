<?php
declare(strict_types=1);
require __DIR__ . '/lib.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('X-Content-Type-Options: nosniff');
try {
    $data = read_data();
    $result = ['version'=>(int)($data['version']??1),'generated_at'=>gmdate('c'),'games'=>[]];
    foreach (['freefire','freefiremax'] as $gameKey) {
        $game = $data['games'][$gameKey] ?? ['name'=>$gameKey,'features'=>[]];
        $features = [];
        foreach (($game['features']??[]) as $feature) {
            if (!is_array($feature) || empty($feature['id'])) continue;
            // Deliberately do NOT publish file URLs or upload tokens here.
            $features[] = [
                'id'=>(string)$feature['id'],
                'name'=>(string)($feature['name']??'Chức năng'),
                'enabled'=>(bool)($feature['enabled']??false),
                'destination_path'=>(string)($feature['destination_path']??''),
                'active_sha256'=>(string)($feature['active_file']['sha256']??''),
                'original_sha256'=>(string)($feature['original_file']['sha256']??''),
                'requires_key'=>true,
                'updated_at'=>(string)($feature['updated_at']??''),
            ];
        }
        $result['games'][$gameKey] = ['name'=>(string)($game['name']??$gameKey),'features'=>$features];
    }
    echo json_encode($result, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error'=>'server_error'], JSON_UNESCAPED_SLASHES);
}
