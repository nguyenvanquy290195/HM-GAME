<?php
declare(strict_types=1);
require __DIR__ . '/lib.php';

$secure = (!empty($_SERVER['HTTPS']) && strtolower((string)$_SERVER['HTTPS']) !== 'off');
session_set_cookie_params(['httponly'=>true,'secure'=>$secure,'samesite'=>'Strict']);
session_start();

function csrf_token(): string { if (empty($_SESSION['csrf'])) $_SESSION['csrf']=bin2hex(random_bytes(24)); return (string)$_SESSION['csrf']; }
function require_csrf(): void { $sent=(string)($_POST['csrf']??''); if ($sent===''||!hash_equals(csrf_token(),$sent)) throw new RuntimeException('Phiên làm việc không hợp lệ. Tải lại trang và thử lại.'); }

$message=''; $error=''; $generatedKey=''; $settings=panel_settings();
if (isset($_GET['logout'])) { $_SESSION=[]; session_destroy(); header('Location: admin.php'); exit; }
if (isset($_POST['login'])) {
    $password=(string)($_POST['password']??'');
    if (hash_equals((string)$settings['admin_password'],$password)) { session_regenerate_id(true); $_SESSION['authenticated']=true; header('Location: admin.php'); exit; }
    $error='Sai mật khẩu.';
}
$authenticated=!empty($_SESSION['authenticated']);
if (!$authenticated):
?><!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HM GAMING Admin</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0b0c10;color:#f8fafc;margin:0}.login{max-width:390px;margin:12vh auto;background:#151820;padding:28px;border:1px solid #2b3040;border-radius:20px;box-shadow:0 16px 44px #0008}.login h1{margin:0 0 6px}.muted{color:#8f98a8;font-size:14px}input,button{font:inherit}input[type=password]{width:100%;box-sizing:border-box;padding:12px;border:1px solid #343b4d;background:#0f1117;color:white;border-radius:10px;margin:18px 0 12px}button{border:0;border-radius:10px;padding:11px 15px;background:#7c3aed;color:#fff;font-weight:700;cursor:pointer;width:100%}.err{background:#451a1a;color:#fecaca;padding:10px;border-radius:10px;margin-top:12px}</style>
</head><body><div class="login"><h1>HM GAMING</h1><div class="muted">Quản lý chức năng và key riêng</div><?php if($error!==''):?><div class="err"><?=h($error)?></div><?php endif;?><form method="post"><input type="password" name="password" placeholder="Mật khẩu admin" required><button name="login" value="1">Đăng nhập</button></form></div></body></html>
<?php exit; endif;

try {
    $data=read_data();
    if ($_SERVER['REQUEST_METHOD']==='POST' && !isset($_POST['login'])) {
        require_csrf();
        $action=(string)($_POST['action']??'');
        $game=(string)($_POST['game']??'');
        if(!valid_game($game)) throw new InvalidArgumentException('Game không hợp lệ.');
        $features =& $data['games'][$game]['features'];

        if ($action==='save_feature') {
            $id=trim((string)($_POST['id']??'')); $isNew=$id==='';
            if($isNew){$id=bin2hex(random_bytes(6));$index=null;$current=[];}
            else{$index=find_feature_index($features,$id);if($index===null)throw new RuntimeException('Không tìm thấy chức năng.');$current=$features[$index];}
            $name=trim((string)($_POST['name']??'')); if($name===''||mb_strlen($name)>80)throw new InvalidArgumentException('Tên chức năng phải từ 1 đến 80 ký tự.');
            $path=normalize_destination_path((string)($_POST['destination_path']??''));
            $active=$current['active_file']??null; $original=$current['original_file']??null;
            try{$active=store_upload($_FILES['active_file']??[]);}catch(InvalidArgumentException $e){if($e->getMessage()!=='NO_FILE')throw $e;}
            try{$original=store_upload($_FILES['original_file']??[]);}catch(InvalidArgumentException $e){if($e->getMessage()!=='NO_FILE')throw $e;}
            if(!is_array($active)||!is_array($original))throw new InvalidArgumentException('Chức năng mới phải có cả File bật và File gốc.');
            $feature=['id'=>$id,'name'=>$name,'enabled'=>isset($_POST['enabled']),'destination_path'=>$path,'active_file'=>$active,'original_file'=>$original,'keys'=>is_array($current['keys']??null)?$current['keys']:[],'updated_at'=>gmdate('c')];
            if($isNew)$features[]=$feature;else$features[$index]=$feature;
            save_data($data);$data=read_data();$message=$isNew?'Đã thêm chức năng.':'Đã lưu thay đổi.';
        } elseif ($action==='delete_feature') {
            $id=(string)($_POST['id']??'');$index=find_feature_index($features,$id);if($index===null)throw new RuntimeException('Không tìm thấy chức năng.');
            array_splice($features,$index,1);save_data($data);$data=read_data();$message='Đã xóa chức năng. File cũ vẫn được giữ để hỗ trợ khôi phục.';
        } elseif ($action==='create_key') {
            $featureID=(string)($_POST['feature_id']??'');$fi=find_feature_index($features,$featureID);if($fi===null)throw new RuntimeException('Không tìm thấy chức năng.');
            $custom=normalize_key((string)($_POST['custom_key']??''));$plain=$custom!==''?$custom:make_key_value('HM');
            if(strlen($plain)<6||strlen($plain)>160)throw new InvalidArgumentException('Key phải từ 6 đến 160 ký tự.');
            $hash=key_hash($plain);foreach((array)($features[$fi]['keys']??[]) as $existing){if(is_array($existing)&&isset($existing['hash'])&&hash_equals((string)$existing['hash'],$hash))throw new InvalidArgumentException('Key này đã tồn tại trong chức năng.');}
            $days=max(0,min(3650,(int)($_POST['days']??0)));$maxDevices=max(1,min(100,(int)($_POST['max_devices']??1)));$label=trim((string)($_POST['label']??''));if(mb_strlen($label)>80)$label=mb_substr($label,0,80);
            $expires=$days>0?gmdate('c',time()+$days*86400):'';
            $features[$fi]['keys'][]=['id'=>bin2hex(random_bytes(6)),'hash'=>$hash,'suffix'=>substr($plain,-5),'label'=>$label,'enabled'=>true,'expires_at'=>$expires,'max_devices'=>$maxDevices,'devices'=>[],'created_at'=>gmdate('c')];
            save_data($data);$data=read_data();$generatedKey=$plain;$message='Đã tạo key cho '.(string)$features[$fi]['name'].'. Hãy sao chép key ngay — server chỉ lưu bản băm.';
        } elseif (in_array($action,['toggle_key','delete_key','reset_devices'],true)) {
            $featureID=(string)($_POST['feature_id']??'');$keyID=(string)($_POST['key_id']??'');$fi=find_feature_index($features,$featureID);if($fi===null)throw new RuntimeException('Không tìm thấy chức năng.');
            $keys =& $features[$fi]['keys'];$ki=find_key_index((array)$keys,$keyID);if($ki===null)throw new RuntimeException('Không tìm thấy key.');
            if($action==='toggle_key'){$keys[$ki]['enabled']=empty($keys[$ki]['enabled']);$message=!empty($keys[$ki]['enabled'])?'Đã mở key.':'Đã khóa key.';}
            elseif($action==='reset_devices'){$keys[$ki]['devices']=[];$message='Đã reset danh sách thiết bị của key.';}
            else{array_splice($keys,$ki,1);$message='Đã xóa key.';}
            save_data($data);$data=read_data();
        }
    }
} catch(Throwable $e){$error=$e->getMessage();try{$data=read_data();}catch(Throwable $ignored){$data=default_data();}}

$game=(string)($_GET['game']??$_POST['game']??'freefire');if(!valid_game($game))$game='freefire';$gameName=$game==='freefire'?'Free Fire':'Free Fire MAX';$features=$data['games'][$game]['features']??[];
try{$apiURL=public_base_url().'/api.php';}catch(Throwable $e){$apiURL='Cấu hình public_base_url trong config.php';}
?><!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HM GAMING Admin</title>
<style>
*{box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0b0c10;color:#f3f4f6;margin:0}.wrap{max-width:1120px;margin:auto;padding:20px}.top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:16px}.top h1{margin:0;font-size:25px}.logout{color:#fb7185;text-decoration:none;font-weight:650}.tabs{display:flex;gap:8px;margin:14px 0}.tabs a{padding:10px 14px;border-radius:10px;text-decoration:none;background:#151820;color:#9ca3af;font-weight:700;border:1px solid #2b3040}.tabs a.on{background:#7c3aed;color:#fff;border-color:#8b5cf6}.box,.card{background:#14171d;border:1px solid #2a2f3a;border-radius:17px;padding:16px;margin-bottom:14px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.full{grid-column:1/-1}label{display:block;font-size:13px;font-weight:700;margin-bottom:6px;color:#cbd5e1}input[type=text],input[type=number],input[type=file]{width:100%;padding:10px;border:1px solid #343a46;border-radius:9px;background:#0d0f14;color:#fff}.row{display:flex;align-items:center;gap:10px}.actions{display:flex;gap:8px;justify-content:flex-end;margin-top:12px;flex-wrap:wrap}button{font:inherit;border:0;border-radius:9px;padding:10px 14px;background:#7c3aed;color:#fff;font-weight:700;cursor:pointer}.secondary{background:#252a34}.danger{background:#be123c}.muted{color:#8f98a8;font-size:13px;line-height:1.45}.ok,.err,.keyout{padding:11px 13px;border-radius:10px;margin-bottom:12px}.ok{background:#123524;color:#86efac}.err{background:#401b20;color:#fecaca}.keyout{background:#172554;color:#bfdbfe;border:1px solid #1d4ed8}.keyvalue{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:16px;font-weight:800;word-break:break-all;user-select:all}.badge{display:inline-flex;padding:4px 8px;border-radius:999px;background:#242833;color:#cbd5e1;font-size:12px}.badge.good{background:#123524;color:#86efac}.badge.bad{background:#401b20;color:#fda4af}.api{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}.titleline{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:12px}.titleline h2{margin:0;font-size:18px}.empty{text-align:center;padding:28px;color:#6b7280}.keys{margin-top:16px;border-top:1px solid #2a2f3a;padding-top:15px}.keyrow{display:grid;grid-template-columns:1.4fr .8fr .8fr auto;gap:10px;align-items:center;padding:11px 0;border-bottom:1px solid #242934}.keyrow:last-child{border-bottom:0}.smallform{display:inline}.smallform button{padding:7px 9px;font-size:12px}.createkey{background:#0f1218;border:1px solid #2a2f3a;border-radius:13px;padding:13px;margin-top:12px}.createkey .grid{grid-template-columns:1.2fr 1fr .65fr .65fr}.subtitle{font-size:14px;font-weight:800;margin-bottom:8px}@media(max-width:780px){.grid,.createkey .grid,.keyrow{grid-template-columns:1fr}.full{grid-column:auto}.wrap{padding:12px}.actions{justify-content:stretch}.actions button{flex:1}}
</style></head><body><div class="wrap">
<div class="top"><div><h1>HM GAMING Admin</h1><div class="muted">API metadata: <span class="api"><?=h($apiURL)?></span><br>File thật không còn công khai; app phải xác thực key để nhận link tạm.</div></div><a class="logout" href="?logout=1">Đăng xuất</a></div>
<div class="tabs"><a class="<?=$game==='freefire'?'on':''?>" href="?game=freefire">Free Fire</a><a class="<?=$game==='freefiremax'?'on':''?>" href="?game=freefiremax">Free Fire MAX</a></div>
<?php if($message!==''):?><div class="ok"><?=h($message)?></div><?php endif;?><?php if($generatedKey!==''):?><div class="keyout">KEY VỪA TẠO — sao chép ngay:<div class="keyvalue"><?=h($generatedKey)?></div></div><?php endif;?><?php if($error!==''):?><div class="err"><?=h($error)?></div><?php endif;?>

<div class="box"><div class="titleline"><h2>Thêm chức năng — <?=h($gameName)?></h2><span class="badge">Mới</span></div><form method="post" enctype="multipart/form-data"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="save_feature"><input type="hidden" name="game" value="<?=h($game)?>"><div class="grid"><div><label>Tên chức năng</label><input type="text" name="name" required></div><div><label>Đường dẫn đích</label><input type="text" name="destination_path" value="Documents/contentcache/Compulsory/ios/gameassetbundles/cache_res.CfnFf59sr1SbsqQ6JqTKsEusjKs~3D" required></div><div><label>File bật</label><input type="file" name="active_file" required></div><div><label>File gốc khi tắt</label><input type="file" name="original_file" required></div><div class="full row"><input type="checkbox" id="new-enabled" name="enabled" checked><label for="new-enabled" style="margin:0">Hiển thị / cho phép bật trên app</label></div></div><div class="actions"><button type="submit">Thêm chức năng</button></div></form></div>

<?php if(!$features):?><div class="box empty">Chưa có chức năng nào cho <?=h($gameName)?>.</div><?php endif;?>
<?php foreach($features as $feature):$id=(string)($feature['id']??'');$keys=is_array($feature['keys']??null)?$feature['keys']:[];?>
<div class="card"><div class="titleline"><h2><?=h((string)($feature['name']??'Chức năng'))?></h2><span class="badge <?=!empty($feature['enabled'])?'good':'bad'?>"><?=!empty($feature['enabled'])?'Đang hiển thị':'Đang ẩn'?></span></div>
<form method="post" enctype="multipart/form-data"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="save_feature"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="id" value="<?=h($id)?>"><div class="grid"><div><label>Tên chức năng</label><input type="text" name="name" value="<?=h((string)($feature['name']??''))?>" required></div><div><label>Đường dẫn đích</label><input type="text" name="destination_path" value="<?=h((string)($feature['destination_path']??''))?>" required></div><div><label>Thay File bật</label><input type="file" name="active_file"><div class="muted"><?=h((string)($feature['active_file']['original_name']??''))?> • <?=format_bytes((int)($feature['active_file']['size']??0))?></div></div><div><label>Thay File gốc</label><input type="file" name="original_file"><div class="muted"><?=h((string)($feature['original_file']['original_name']??''))?> • <?=format_bytes((int)($feature['original_file']['size']??0))?></div></div><div class="full row"><input type="checkbox" id="enabled-<?=h($id)?>" name="enabled" <?=!empty($feature['enabled'])?'checked':''?>><label for="enabled-<?=h($id)?>" style="margin:0">Hiển thị / cho phép bật</label></div></div><div class="actions"><button type="submit">Lưu thay đổi</button></div></form>

<div class="keys"><div class="subtitle">Kho key riêng — <?=count($keys)?> key</div>
<div class="createkey"><form method="post"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="create_key"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="feature_id" value="<?=h($id)?>"><div class="grid"><div><label>Key tùy chọn (để trống = tự tạo)</label><input type="text" name="custom_key" placeholder="HM-XXXXX-XXXXX-XXXXX"></div><div><label>Ghi chú</label><input type="text" name="label" placeholder="Khách A"></div><div><label>Số ngày (0 = vô hạn)</label><input type="number" name="days" value="7" min="0" max="3650"></div><div><label>Thiết bị</label><input type="number" name="max_devices" value="1" min="1" max="100"></div></div><div class="actions"><button type="submit">Tạo key</button></div></form></div>
<?php if(!$keys):?><div class="muted" style="margin-top:10px">Chưa có key. Chức năng này sẽ không bật được cho tới khi có key hợp lệ.</div><?php endif;?>
<?php foreach($keys as $key):$kid=(string)($key['id']??'');$expired=key_is_expired($key);$enabled=!empty($key['enabled']);$deviceCount=count((array)($key['devices']??[]));$maxDevices=max(1,(int)($key['max_devices']??1));?>
<div class="keyrow"><div><strong><?=h((string)($key['label']??'Key'))?></strong> <span class="badge">…<?=h((string)($key['suffix']??''))?></span><div class="muted"><?=h($kid)?> • Tạo <?=h((string)($key['created_at']??''))?></div></div><div><span class="badge <?=$enabled&&!$expired?'good':'bad'?>"><?=$expired?'Hết hạn':($enabled?'Hoạt động':'Đã khóa')?></span><div class="muted"><?=trim((string)($key['expires_at']??''))===''?'Vô hạn':h((string)$key['expires_at'])?></div></div><div><strong><?=$deviceCount?> / <?=$maxDevices?> thiết bị</strong><div class="muted">Reset để đổi máy</div></div><div class="actions" style="margin:0"><form class="smallform" method="post"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="toggle_key"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="feature_id" value="<?=h($id)?>"><input type="hidden" name="key_id" value="<?=h($kid)?>"><button class="secondary"><?=$enabled?'Khóa':'Mở'?></button></form><form class="smallform" method="post"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="reset_devices"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="feature_id" value="<?=h($id)?>"><input type="hidden" name="key_id" value="<?=h($kid)?>"><button class="secondary">Reset máy</button></form><form class="smallform" method="post" onsubmit="return confirm('Xóa key này?');"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="delete_key"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="feature_id" value="<?=h($id)?>"><input type="hidden" name="key_id" value="<?=h($kid)?>"><button class="danger">Xóa</button></form></div></div>
<?php endforeach;?></div>
<form method="post" onsubmit="return confirm('Xóa chức năng này?');"><input type="hidden" name="csrf" value="<?=h(csrf_token())?>"><input type="hidden" name="action" value="delete_feature"><input type="hidden" name="game" value="<?=h($game)?>"><input type="hidden" name="id" value="<?=h($id)?>"><div class="actions"><button class="danger">Xóa chức năng</button></div></form></div>
<?php endforeach;?>
<div class="box"><div class="muted"><strong>Cơ chế:</strong> api.php chỉ trả metadata. Khi người dùng bật chức năng, app gửi key + ID chức năng + ID thiết bị sang access.php. Server hợp lệ mới cấp link tải tạm khoảng 90 giây. Khi tắt, app dùng phiên đã lưu để lấy file gốc mà không hỏi key lại. file.php cũ đã bị khóa.</div></div>
</div></body></html>
