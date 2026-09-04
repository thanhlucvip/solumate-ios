# Báo cáo đọc file và so sánh

## 1) Hai gói đã đọc

- `solumate-agent（IOS15-26）2026-03-06.ipa`
- `WebDriverAgentRunner-Runner-v11.4.1.zip`

## 2) Cấu trúc thực tế

### `solumate-agent` IPA

Bên trong có:

- `Payload/WebDriverAgentRunner-Runner.app/WebDriverAgentRunner-Runner`
- `Payload/WebDriverAgentRunner-Runner.app/Info.plist`
- `Payload/WebDriverAgentRunner-Runner.app/PlugIns/WebDriverAgentRunner.xctest/...`
- `Payload/WebDriverAgentRunner-Runner.app/Frameworks/libXCTestSwiftSupport.dylib`
- `Payload/WebDriverAgentRunner-Runner.app/amazoncloud`
- `Payload/WebDriverAgentRunner-Runner.app/hhhhsd.dylib`

### `WebDriverAgentRunner-Runner-v11.4.1.zip`

Là app runner sạch hơn, không có `hhhhsd.dylib`, không có `amazoncloud`.

## 3) So sánh Info.plist

### IPA app

- Bundle ID: `com.mrph.svc`
- Bundle Name: `idb-agent`
- Version: `1.9`
- Minimum iOS: `13.0`

### Clean runner app

- Bundle ID: `solumate.driver.automation`
- Bundle Name: `WebDriverAgentRunner-Runner`
- Version: `1.0`
- Minimum iOS: `13.0`

## 4) Điểm rủi ro đã thấy

### 4.1 `hhhhsd.dylib` bị inject vào app runner

Binary `WebDriverAgentRunner-Runner` trong IPA có load command:

- `@executable_path/hhhhsd.dylib`

Bản sạch `v11.4.1` không có load command này.

### 4.2 `hhhhsd.dylib` chứa dấu hiệu không nên giữ

Trong strings có các dấu hiệu:

- domain `dylib.heima911.com`
- `TimeLock.swift`
- `Reachability`
- `KeychainItemWrapper`
- khối key kiểu PEM

Điều này đủ để coi đây là thành phần không nên dùng lại nếu mục tiêu là bản an toàn hơn.

## 5) Phần tính năng bạn cần nằm ở đâu

Tính năng bạn đang gọi bằng Node.js là:

- `POST /session/:sid/wda/swipe/pointArray`

Kết quả phân tích binary cho thấy:

- route này **có trong** `solumate-agent`
- route này **không có trong** `WebDriverAgentRunner-Runner-v11.4.1` sạch

Phần route nằm trong `WebDriverAgentLib.framework/WebDriverAgentLib`, không phải trong `hhhhsd.dylib`.

## 6) Kết quả reverse engineering route `pointArray`

### 6.1 Handler route

`+[FBCustomCommands handleDeviceSwipePointArray:]` làm các việc chính sau:

- đọc `request.arguments[@"pointArray"]`
- gọi `[XCUIDevice.sharedDevice fb_synthSwipePointArray:pointArray]`
- trả `FBResponseWithOK()`

### 6.2 Điều quan trọng

Field `st` trong payload **không được dùng** trong route hiện tại.

Tức là đoạn Node.js hiện nay có gửi `st`, nhưng binary `solumate-agent` hiện tại không xác thực bằng `st`.

### 6.3 Hàm synth swipe pointArray

`fb_synthSwipePointArray:` dùng private XCTest APIs kiểu:

- `XCPointerEventPath`
- `XCSynthesizedEventRecord`
- `moveToPoint:atOffset:`
- `liftUpAtOffset:`

Nó dựng path từ point đầu tiên, sau đó đi qua từng point còn lại bằng offset thời gian tuyệt đối.

### 6.4 Hạn chế của bản cũ

Bản `solumate-agent` hiện tại không kiểm các điểm sau:

- số lượng điểm tối đa
- toạ độ có nằm trong màn hình không
- phần tử có đúng kiểu số hay không
- offset thời gian có tăng dần hay không
- thời lượng tổng có quá dài không
- xác thực `st`

## 7) Kết luận kỹ thuật

Nếu mục tiêu là **vừa có `pointArray`, vừa an toàn hơn**, thì hướng đúng là:

1. lấy runner sạch `v11.4.1`
2. không giữ `hhhhsd.dylib`
3. không giữ `amazoncloud`
4. build lại route `pointArray` từ source WebDriverAgent sạch
5. thêm validate + HMAC `st`

## 8) Những gì đã tạo ra

- `WebDriverAgentRunner-Runner-v11.4.1-safe-pointarray-unsigned.ipa`
  - phương án nhanh, binary-only
  - đã bỏ phần inject đáng ngờ
  - nhưng vẫn mượn custom `WebDriverAgentLib` từ `solumate-agent`

- `manual_patch_safe_pointarray.md`
  - phương án chuẩn để build sạch từ source

- `call_wda_swipe_pointarray_secure.js`
  - script Node.js mới để tạo `st` bằng HMAC-SHA256 và validate client-side
