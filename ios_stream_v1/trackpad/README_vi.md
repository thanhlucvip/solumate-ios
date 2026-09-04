# Bộ kết quả WDA an toàn hơn cho `pointArray`

## Những gì đã kiểm tra

Tôi đã bóc tách và so sánh 2 gói bạn gửi:

- `solumate-agent（IOS15-26）2026-03-06.ipa`
- `WebDriverAgentRunner-Runner-v11.4.1.zip`

Kết luận kỹ thuật chính:

1. `solumate-agent` là một bản WDA đã bị tuỳ biến thêm route `POST /session/:id/wda/swipe/pointArray`.
2. `solumate-agent` có thêm các thành phần không nên giữ nếu mục tiêu là "an toàn hơn":
   - `hhhhsd.dylib`
   - `amazoncloud`
3. binary runner trong `solumate-agent` có load command `@executable_path/hhhhsd.dylib`, trong khi bản `v11.4.1` sạch thì không có.
4. route `pointArray` hiện tại trong `solumate-agent` gọi thẳng vào `fb_synthSwipePointArray:` và **không validate** kích thước dữ liệu, thời gian, biên màn hình, cũng như **không dùng `st`** để xác thực.

## Những file trong thư mục này

### 1) IPA unsigned đã gọt sạch

- `WebDriverAgentRunner-Runner-v11.4.1-safe-pointarray-unsigned.ipa`

Đây là IPA tạo bằng cách:

- lấy runner sạch từ `WebDriverAgentRunner-Runner-v11.4.1`
- chỉ transplant `WebDriverAgentLib.framework/WebDriverAgentLib` từ `solumate-agent` để giữ route `pointArray`
- loại bỏ:
  - `_CodeSignature`
  - `embedded.mobileprovision`
  - `amazoncloud`
  - `hhhhsd.dylib`
  - dSYM thừa

Lưu ý:

- IPA này **chưa ký** và cần ký lại trên macOS/Xcode hoặc `codesign`.
- IPA này **an toàn hơn bản solumate-agent gốc**, nhưng route `pointArray` trong binary ghép này vẫn là route cũ của `solumate-agent`, nghĩa là **chưa có auth/validate thật sự**.

### 2) Patch source-level khuyến nghị

- `manual_patch_safe_pointarray.md`
- `call_wda_swipe_pointarray_secure.js`

Đây mới là hướng nên dùng nếu bạn muốn:

- giữ `POST /wda/swipe/pointArray`
- bỏ hoàn toàn `hhhhsd.dylib`
- thêm validate nghiêm ngặt
- buộc route chỉ chạy khi bật cờ
- hỗ trợ `st` dạng HMAC-SHA256 thực sự

## Hướng dùng khuyến nghị

### Cách nhanh

1. Re-sign IPA unsigned.
2. Cài lên máy.
3. Dùng script Node để gọi.

### Cách sạch và an toàn nhất

1. Lấy source Appium WebDriverAgent tương ứng.
2. Áp dụng nội dung trong `manual_patch_safe_pointarray.md`.
3. Build lại bằng Xcode.
4. Ký bằng certificate/team của bạn.
5. Chạy script Node `call_wda_swipe_pointarray_secure.js` với `--secret`.

## Biến môi trường / cấu hình

Patch source-level trong bộ này dùng 2 biến môi trường runtime:

- `SOLUMATE_WDA_ENABLE_POINT_ARRAY=1`
- `SOLUMATE_WDA_SWIPE_SECRET=<secret>`

Nếu bạn không truyền `SOLUMATE_WDA_SWIPE_SECRET`, bản hardening sẽ từ chối `pointArray` trừ khi bạn cố tình bật `SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY=1` cho môi trường test.

Trackpad server mặc định bind `127.0.0.1`. Nếu cần mở ra LAN, nên bật token:

```bash
HOST=0.0.0.0 STREAM_AUTH_TOKEN=<token> node trackpad_server.js
```

Mở trang bằng `http://<ip-may>:3002/?auth=<token>`.

## Ràng buộc thực tế

Trong môi trường hiện tại tôi **không thể build và ký một IPA iOS mới hoàn chỉnh bằng Xcode**, nên tôi cung cấp:

- một IPA unsigned đã được làm sạch ở mức binary
- patch source-level để bạn build sạch thật sự trên macOS
- script Node mới tương thích với `st` HMAC
