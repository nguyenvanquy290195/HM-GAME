# Build / cài đặt bản 3105 v1.1.1 custom

## Có gì trong bản này

Thanh tab gồm:

1. **Free Fire** — chức năng tải file từ server và thay vào data game.
2. **Tệp** — App Data Browser của 3105 v1.1.1.
3. **Patch** — hệ thống Patch của 3105 v1.1.1.

Module Free Fire chỉ cho phép hai bundle ID cố định:

- Free Fire: `com.dts.freefireth`
- Free Fire MAX: `com.dts.freefiremax`

## Build IPA bằng GitHub Actions

Upload toàn bộ source lên repo GitHub. Workflow đã có sẵn ở:

`.github/workflows/build-ios.yml`

Vào **Actions → Build 3105 FF + Files + Patch IPA → Run workflow**.
Artifact tạo ra: `3105-v1.1.1-FF-Files-Patch-unsigned-ipa`.

## Cấu hình server

Xem `server-ff/README-VI.md`.

Sau khi server chạy, trong app mở tab **Free Fire** → biểu tượng server ở góc phải → nhập URL dạng:

`https://domain.com/3105ff/api.php`

## Hoạt động file

Mỗi ô chức năng trên server có:

- Tên chức năng
- File bật
- File gốc
- Đường dẫn đích riêng
- Trạng thái hiển thị

Bật chức năng: tải File bật → kiểm tra SHA-256 → thay file đích.
Tắt chức năng: tải File gốc → kiểm tra SHA-256 → khôi phục file đích.

Đường dẫn mẫu đã được điền sẵn trong form Admin:

`Documents/contentcache/Compulsory/ios/gameassetbundles/cache_res.CfnFf59sr1SbsqQ6JqTKsEusjKs~3D`

Đường dẫn là tương đối từ root data container, không nhập `/var/mobile/...`.
