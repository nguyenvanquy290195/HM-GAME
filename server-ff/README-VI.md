# Server Free Fire cho 3105 custom

## Cài trên cPanel/Hpanel

1. Upload toàn bộ thư mục `server-ff` lên host, ví dụ thành `public_html/3105ff/`.
2. Mở `config.php` và đổi `admin_password`.
3. Nên đặt `public_base_url` thành URL HTTPS chính xác, ví dụ `https://domain.com/3105ff`.
4. Đảm bảo PHP có quyền ghi vào `data/` và `uploads/` (thường 755 cho thư mục là đủ trên shared hosting).
5. Mở `https://domain.com/3105ff/admin.php` để quản lý.
6. Trong app 3105 → tab **Free Fire** → biểu tượng server → nhập `https://domain.com/3105ff/api.php`.

## Cơ chế

- Hai khu riêng: `Free Fire` và `Free Fire MAX`.
- Mỗi chức năng gồm: tên, đường dẫn đích, File bật, File gốc, trạng thái hiển thị.
- Bật trên app: tải File bật → kiểm tra SHA-256 → thay file tại đường dẫn đã cấu hình.
- Tắt trên app: tải File gốc → kiểm tra SHA-256 → thay lại file tại cùng đường dẫn.
- Bundle ID không lấy từ server. App khóa cố định `com.dts.freefireth` và `com.dts.freefiremax`.
- Đường dẫn server chỉ là đường dẫn tương đối bên trong data container; `..`, đường dẫn tuyệt đối và symbolic-link traversal bị chặn.
- Nếu nhiều chức năng dùng cùng một đường dẫn, bật chức năng mới sẽ thay thế chức năng cũ ở đường dẫn đó.
- Khi xóa/thay file trong Admin, binary cũ được giữ lại để thiết bị đã bật trước đó vẫn có thể dùng URL File gốc đã lưu để rollback.

## Ví dụ đường dẫn

`Documents/contentcache/Compulsory/ios/gameassetbundles/cache_res.CfnFf59sr1SbsqQ6JqTKsEusjKs~3D`

## Upload file lớn

Nếu upload bị giới hạn, tăng `upload_max_filesize` và `post_max_size` trong cấu hình PHP của hosting. Panel có giới hạn ứng dụng mặc định 250 MB trong `config.php`.
