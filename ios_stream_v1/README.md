# iOS screen stream lên web bằng WDA trên Ubuntu

Dự án này chọn hướng **WebDriverAgent MJPEG** làm nguồn ảnh chính, rồi Node.js server có thể encode lại thành H.264 binary websocket cho các decoder trong trình duyệt:

- dễ ghép vào Node.js hơn
- không cần dùng luồng H.264 từ IPA trên iOS
- vẫn dùng **WebDriverAgent** để điều khiển tap/swipe/home

## Kiến trúc

```text
[iPhone/iPad]
  |- WebDriverAgent HTTP     -> device port 8000
  |- WebDriverAgent MJPEG    -> device port 8001
  |- Realtime control        -> device port 8003
  |- Realtime control mesh   -> device port 8003 (default)
        ^
        | USB / tunnel / forward
        v
[Ubuntu]
  |- go-ios / usbmux tunnel + port forward
  |- Node.js server (server.js)
       |- proxy /stream.mjpeg
       |- /ws/h264 server-side MJPEG -> H264 bridge
       |- /ws/realtime-control -> realtime touch or pointArray (build-driven)
       |- /ws/realtime-control-mesh -> swipe
       |- POST /api/tap
       |- POST /api/swipe
       |- POST /api/home
       |- web UI
```

## Trước khi chạy

### Điều kiện tiên quyết rất quan trọng

1. **WDA phải đã được ký và cài được lên máy iOS**.
2. Với iPhone thật, đây là phần dễ vướng nhất. Nếu IPA/WDA chưa trust hoặc ký sai certificate/provisioning profile thì Ubuntu không cứu được bước này.
3. Dự án này **không cần Appium server**, chỉ cần **WDA đang chạy được** và **port 8000/8001** truy cập được từ Ubuntu. Forward thêm `8003` nếu dùng realtime control.

## Ubuntu setup

Ví dụ trên Ubuntu 22.04/24.04:

```bash
sudo apt-get update
sudo apt-get install -y curl usbmuxd libimobiledevice6 libimobiledevice-utils build-essential

# Node.js 20+
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# go-ios
npm install -g go-ios

# kiểm tra
ios --version
node -v
npm -v
```

## Chuẩn bị iPhone/iPad

- bật **Developer Mode** nếu máy yêu cầu
- cắm USB và bấm **Trust This Computer**
- nếu máy iOS 17+ thì cần tunnel trước khi dùng `go-ios`

### Pair + mount developer image

```bash
ios pair
ios devmode enable
ios image auto
```

> Với iOS 17+, mở thêm một terminal riêng và chạy:

```bash
sudo ios tunnel start --userspace
```

Nếu bản `go-ios` của bạn chạy ổn với tunnel kernel mode thì có thể thử bỏ `--userspace`.

## Cài và chạy WDA

### Cách 1 - bạn đã có IPA WDA đã ký sẵn

```bash
ios install --path=/path/to/WebDriverAgentRunner-Runner.ipa
```

Sau đó thử chạy WDA bằng `go-ios`:

```bash
ios runwda \
  --bundleid=solumate.driver.automation \
  --testrunnerbundleid=solumate.driver.automation \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --log-output=-
```

Bundle id WDA cố định là `solumate.driver.automation`.

### Cách 2 - WDA đã chạy sẵn

Nếu bạn đã có môi trường khác khởi động được WDA, chỉ cần đảm bảo trên Ubuntu truy cập được:

```bash
curl http://127.0.0.1:8000/status
curl -I http://127.0.0.1:8001/
```

## Forward port từ device về Ubuntu

Mở **2 terminal** riêng:

```bash
ios forward 8000 8000
```

```bash
ios forward 8001 8001
```

Nếu `go-ios` không hợp máy bạn, có thể thay bằng `iproxy` tương đương:

```bash
iproxy 8000 8000
iproxy 8001 8001
```

## Windows 10 / 11 setup

Bản Node.js trong repo này chạy được trên Windows. Phần helper script ban đầu là Bash cho Ubuntu, và repo hiện đã có thêm bản PowerShell trong thư mục `scripts/`.

### Cài công cụ

Mở **PowerShell** với quyền bình thường hoặc quyền admin khi cần thiết:

```powershell
winget install OpenJS.NodeJS.LTS
npm install -g go-ios
```

Với `go-ios` trên Windows, hãy chép `wintun.dll` vào `C:\Windows\System32` theo hướng dẫn của repo `go-ios`.

### Chuẩn bị thiết bị

```powershell
ios pair
ios devmode enable
ios image auto
```

Với iOS 17+, mở thêm một PowerShell riêng và chạy:

```powershell
ios tunnel start
```

### Cài và chạy WDA

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-wda-go-ios.ps1 `
  -IpaPath "C:\path\to\WebDriverAgentRunner-Runner.ipa" `
  -BundleId "solumate.driver.automation"
```

### Forward port

Mở thêm một PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\forward-go-ios.ps1
```

### Kiểm tra WDA

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check-wda.ps1
```

### Chạy server web

```powershell
npm start
```

Sau đó mở trình duyệt tại:

```text
http://localhost:3000
```

## Chạy web server

```bash
cd ios-wda-stream-server
npm start
```

Mở trình duyệt:

```text
http://<IP-Ubuntu>:3000
```

## Cách dùng

- bấm **Kết nối WDA**
- vùng màn hình stream:
  - **tap** = click nhanh
  - **swipe** = kéo chuột / kéo tay
- nút **Home** = gửi lệnh home screen
- phần **Cấu hình MJPEG** cho phép đổi:
  - FPS
  - JPEG quality
  - scaling
  - fix orientation

## Biến môi trường hỗ trợ

```bash
export PORT=3000
export WDA_BASE=http://127.0.0.1:8000
export MJPEG_URL=http://127.0.0.1:8001
export MJPEG_FRAMERATE=10
export MJPEG_QUALITY=40
export MJPEG_SCALE=100
export MJPEG_FIX_ORIENTATION=true
npm start
```

## API chính

### Tạo/refresh WDA session

```bash
curl -X POST http://127.0.0.1:3000/api/connect
```

### Tap

```bash
curl -X POST http://127.0.0.1:3000/api/tap \
  -H 'content-type: application/json' \
  -d '{"x":120,"y":300}'
```

### Swipe

```bash
curl -X POST http://127.0.0.1:3000/api/swipe \
  -H 'content-type: application/json' \
  -d '{"fromX":100,"fromY":500,"toX":300,"toY":500,"duration":0.01}'
```

### Home

```bash
curl -X POST http://127.0.0.1:3000/api/home
```

### Đổi MJPEG settings

```bash
curl -X POST http://127.0.0.1:3000/api/settings \
  -H 'content-type: application/json' \
  -d '{
    "mjpegServerFramerate": 15,
    "mjpegServerScreenshotQuality": 55,
    "mjpegScalingFactor": 80,
    "mjpegFixOrientation": true
  }'
```

## Troubleshooting

### 1) `curl http://127.0.0.1:8000/status` không lên

- WDA chưa chạy
- bundle id sai
- WDA chưa được trust trên iPhone
- certificate đã hết hạn hoặc provisioning profile sai
- iOS 17+ chưa mở tunnel

### 2) Có `/status` nhưng không có video ở `8001`

- MJPEG chưa forward đúng port
- WDA session chưa được tạo
- WDA bị treo sau khi khởi chạy
- thử bấm **Kết nối WDA** lại hoặc `POST /api/restart-session`

### 3) Ảnh đúng nhưng tap lệch

- bật lại `Fix orientation`
- bấm **Kết nối WDA** lại để lấy lại `screenSize`
- tránh scale của trình duyệt quá lạ hoặc CSS custom khác

### 4) `ios runwda` lỗi nhưng app WDA đã cài

- thử mở WDA trực tiếp trên máy nếu icon đã xuất hiện và profile đã trust
- nếu vẫn không lên, gần như chắc cần build/sign lại WDA đúng team/certificate

## Khi nào nên dùng nguồn video riêng

Hãy cân nhắc nguồn video riêng nếu bạn cần:

- latency thấp hơn MJPEG
- H.264 thay vì chuỗi JPEG
- nhiều client và băng thông tối ưu hơn

Mặc định hiện tại không dùng H.264 từ IPA; các decoder H.264 trong web nhận dữ liệu từ bridge MJPEG -> H.264 của Node.js server.
