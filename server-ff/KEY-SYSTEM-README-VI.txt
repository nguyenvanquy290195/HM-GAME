HM GAMING - KEY RIÊNG TỪNG CHỨC NĂNG

Luồng app:
1. App tải danh sách chức năng từ api.php. API KHÔNG trả URL file thật.
2. Bật chức năng lần đầu -> app hỏi key.
3. App gửi game + feature_id + key + device_id tới access.php.
4. Server kiểm tra đúng chức năng, trạng thái key, hạn key và giới hạn thiết bị.
5. Hợp lệ -> server cấp access_token + link download.php tạm thời (90 giây).
6. App tự tải file, kiểm tra SHA-256 và cài. Token tải không hiển thị trên giao diện.
7. Access token được lưu trong Keychain. Lần sau app tự xác thực lại với server, không cần nhập key nếu key vẫn hợp lệ.
8. Khi tắt -> app dùng access token để xin file gốc tạm thời và khôi phục, không hỏi key lại.

Admin:
- Mỗi chức năng có kho key riêng.
- Tạo key tự động hoặc nhập key tùy chọn.
- Chọn số ngày: 0 = vô hạn.
- Chọn giới hạn thiết bị.
- Có thể khóa/mở key, reset thiết bị, xóa key.
- Key tự tạo chỉ hiện đầy đủ ngay sau khi tạo. Server chỉ lưu hash + 5 ký tự cuối.

CẬP NHẬT SERVER ĐANG DÙNG:
- KHÔNG xóa /proxy/data/config.json
- KHÔNG xóa /proxy/uploads/
- KHÔNG ghi đè config.php nếu bạn đã đổi mật khẩu/domain.
- Dùng gói SERVER-UPDATE để ghi đè các file PHP. Thư mục runtime sẽ tự tạo.
- Sau cập nhật, file.php cũ bị khóa; tải file chỉ qua download.php + token tạm.

Thứ tự khuyến nghị:
1. Sao lưu thư mục /proxy trước.
2. Up SERVER-UPDATE lên /proxy (giữ config.php, data, uploads).
3. Vào admin.php, mở từng chức năng và tạo ít nhất 1 key.
4. Build/cài app mới.
