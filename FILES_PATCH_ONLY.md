# 3105 v1.1.1 custom — Free Fire + Files + Patch

Bản custom này giữ phần **Tệp** và **Patch**, đồng thời thêm tab **Free Fire** dành riêng cho Free Fire thường và Free Fire MAX.

## Free Fire module

- Game cố định: `com.dts.freefireth` và `com.dts.freefiremax`.
- Danh sách chức năng lấy từ server qua HTTPS.
- Mỗi chức năng có File bật, File gốc và đường dẫn đích riêng.
- Bật: tải File bật, xác minh SHA-256, thay file trong data game.
- Tắt: tải File gốc, xác minh SHA-256, khôi phục cùng đường dẫn.
- Đường dẫn được kiểm tra để không thoát khỏi data container.
- Trạng thái bật được lưu trên máy để có thể rollback khi chức năng bị ẩn/xóa trên server.

Thư mục `server-ff/` chứa API + trang admin PHP dùng cho cPanel/Hpanel. Xem `server-ff/README-VI.md`.
