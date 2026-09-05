# Run Guide (Windows + go-ios + WDA)

## 0) Chuan bi

- PowerShell phai goi duoc lenh `ios`. Neu chua co:

```powershell
npm install -g go-ios
ios --version
```

- Tren Windows, dam bao da co `C:\Windows\System32\wintun.dll` truoc khi chay `ios tunnel start`.
- Cam iPhone vao may, da Trust computer
- Da pair thanh cong (`ios pair`)
- Da bat Developer Mode tren iPhone
- Neu iOS 17+ moi can chay tunnel truoc. iOS 16.x khong can `ios tunnel start`.
- WDA phai duoc sign/trust dung tren iPhone neu ban dung IPA tu build khac

## 0.1) Chay 1 lan truoc khi bat tunnel

```powershell
ios pair
ios devmode enable
ios image auto
ios image list
```

Ky vong:
- `ios image list` khong tra ve `none`.
- Neu `ios image list` van la `none`, dung lai o day va fix developer image truoc.

## 1) Terminal A - Start tunnel (giu cua so mo)

```powershell
ios --udid=f8a54e20748a1111f59ed7350bf71cb4f6ba8d4c tunnel start --userspace
```

Neu `--userspace` khong on, thu:

```powershell
ios --udid=00008020-000A1DE21E62002E tunnel start
```

Ghi chu:
- Warning `go-ios agent is not running` luc `tunnel start --userspace` thuong khong phai loi chinh neu tunnel van len.
- Phai giu cua so tunnel mo trong suot qua trinh chay WDA/forward.

## 2) Terminal B - Sanity check RSD/XPC

```powershell
ios devmode get
ios tunnel ls
```

Ky vong:
- `ios devmode get` tra ve thong tin binh thuong, khong bi `STREAM_CLOSED`.
- `ios tunnel ls` thay `udid`, `rsdPort`, `userspaceTunPort`.

Neu `ios devmode get` bao loi kieu:
- `could not connect to RSD`
- `failed to create xpc connection`
- `STREAM_CLOSED`

Thi dung lai o day. Day la loi tang `go-ios <-> tunnel <-> device`, chua nen chay `runwda` hay `forward`.

## 3) Terminal C - Run WDA (giu cua so mo)

Neu da cai WDA roi:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-wda-go-ios.ps1 -SkipInstall
```

Neu chua cai, truyen duong dan IPA that:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-wda-go-ios.ps1 -IpaPath "C:\DUONG_DAN_THAT\WebDriverAgentRunner-Runner.ipa"
```

Ghi chu:
- Script da tu set `USE_PORT=8000`, `MJPEG_SERVER_PORT=8001`, `H264_SERVER_PORT=-1` de tat H264 trong IPA, va `WDA_REALTIME_CONTROL_PORT=8003`.
- Script se tu kiem tra va thu `ios image auto` neu Developer Image chua mount.
- Neu IPA path sai, script se bao loi ngay.
- Neu gap `Timed out waiting for response for message:5 channel:0`, `XCTestManager_DaemonConnectionInterface`, hoac `cannot initiate a IDE session`, kha nang cao van la loi RSD/XPC hoac WDA sign/trust chua dung.
- Neu gap `unsupported iOS version 16.x` khi start tunnel, do la ban dang dung lenh tunnel tren may iOS 16; bo qua tunnel va chay lai `run-wda-go-ios.ps1`.

## 4) Terminal D - Forward port (giu cua so mo)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\forward-go-ios.ps1
```

Ghi chu:
- Neu `ios forward 8000 8000` bao `could not connect to RSD ... STREAM_CLOSED`, loi goc van la tang tunnel/RSD, khong phai script `forward-go-ios.ps1`.
- Neu `8001` log `new client connected` roi `close clientConn` ngay, thuong la co process local dang thu doc MJPEG nhung WDA/MJPEG upstream tren iPhone chua song that.

## 5) Terminal E - Start web server

```powershell
npm install
npm start
```

Mo trinh duyet:

```text
http://localhost:3000
```

### 5.0) Hardening khi khong chi chay local

Neu may server co the bi truy cap tu LAN/VPN/Internet, dat token truoc khi `npm start`:

```powershell
$env:HOST = "127.0.0.1"
$env:STREAM_AUTH_TOKEN = "tao-token-dai-ngau-nhien"
$env:ALLOWED_ORIGIN = "http://localhost:3000"
npm start
```

Mo UI bang:

```text
http://localhost:3000/?auth=tao-token-dai-ngau-nhien
```

Neu bat `pointArray`, dat cung mot secret cho server va WDA:

```powershell
$env:SOLUMATE_WDA_ENABLE_POINT_ARRAY = "1"
$env:SOLUMATE_WDA_SWIPE_SECRET = "tao-secret-dai-ngau-nhien"
```

`SOLUMATE_WDA_SWIPE_SECRET` phai duoc set o ca terminal chay `run-wda-go-ios.ps1` va terminal chay `npm start`.

### 5.1) (Tuy chon) Cau hinh mode H264/WebRTC

Mac dinh server se encode MJPEG -> H264 binary websocket bang `ffmpeg` de chay:
- `Broadway`
- `h264-live-player`
- `tinyh264`
- `WebCodecs`
- `Genymobile/scrcpy`

Tat ca mode tren dung `/ws/h264` cua Node.js server, khong dung H264/scrcpy stream tu IPA tren iOS.

Neu can WebRTC, dat env truoc khi `npm start`:

```powershell
$env:WEBRTC_WHEP_URL = "http://127.0.0.1:8889/whep"
npm start
```

Ghi chu:
- `WEBRTC_WHEP_URL` dung cho mode H.264/WebRTC.
- UI co dropdown `View mode` o tren cung de chuyen renderer.

## 6) Kiem tra nhanh

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check-wda.ps1
```

Ky vong:
- WDA status tra ve JSON
- MJPEG headers tra ve `200 OK`

Them check cho multi-view:

```powershell
curl.exe http://localhost:3000/api/view-modes
curl.exe http://localhost:3000/health
```

Ky vong:
- `modes` tra ve day du cac option view.
- Mode nao khong co source se co `enabled=false`.

## 7) Neu gap `RSD/XPC STREAM_CLOSED`

1. Stop tat ca process `ios` dang chay.
2. Rut cap USB, cam lai, mo khoa man hinh iPhone va nhan Trust neu may hoi lai.
3. Chay lai dung thu tu: `ios pair` -> `ios image auto` -> tunnel -> `ios devmode get`.
4. Chi khi `ios devmode get` khong con `STREAM_CLOSED` thi moi chay `runwda` va `forward`.
5. Neu app WDA mo truc tiep tren iPhone ma Windows van bi `STREAM_CLOSED`, kha nang cao la loi tuong thich `go-ios` + Windows + iOS 18.

## 8) Neu gap `ECONNRESET` tai 8001

1. Stop tat ca process `ios` dang chay.
2. Chay lai dung thu tu: Tunnel -> Run WDA -> Forward -> npm start.
3. Dam bao dang dung script `run-wda-go-ios.ps1` moi (co `MJPEG_SERVER_PORT`).

## 9) Test UI sau khi server len

1. Mo `http://localhost:3000`.
2. Bam `Connect WDA`.
3. Thu doi dropdown `View mode`:
   - `MJPEG WDA`: phai len anh ngay khi WDA MJPEG co du lieu.
   - `MJPEG Binary Socket`: phai len anh tu websocket relay `/ws/mjpeg`.
   - `Broadway` / `h264-live-player` / `tinyh264` / `WebCodecs` / `Genymobile/scrcpy`: dung `/ws/h264` do server transcode MJPEG bang ffmpeg.
   - `H.264/WebRTC`: can co `WEBRTC_WHEP_URL`.

### 9.1) Trackpad trong man hinh chinh

- Trong panel ben phai co muc `Trackpad`:
  - `Sample interval (ms)`
- `Control mode = realtime-socket`: socket `/ws/realtime-control` se tra `is_trollstore`; `true` thi dung touch-stream realtime, `false` thi dung `pointArray`.
- `Control mode = realtime-socket(swipe)`: thao tac keo se gui `swipe` qua `/ws/realtime-control-mesh` -> WDA TCP mesh `8003`.
- Token `st` neu can se duoc server tu tao khi da cau hinh `SOLUMATE_WDA_SWIPE_SECRET`.
- Neu realtime socket chua ket noi truoc khi lenh duoc gui, UI van fallback HTTP de giu dieu khien khong bi dut.

## 10) Neu mode socket/H264 khong chay

Kiem tra `ffmpeg`:

```powershell
ffmpeg -version
```

Luu y quan trong:
- H264 tu IPA da duoc tat mac dinh bang `H264_SERVER_PORT=-1`.
- Cac decoder H264/scrcpy trong web can `ffmpeg` trong PATH de server transcode MJPEG -> H264.
- `H.264/WebRTC` van can `WEBRTC_WHEP_URL` dang chay that.

### 10.1) Kiem tra local fallback ffmpeg

Kiem tra ffmpeg neu chua lam o tren:

```powershell
ffmpeg -version
```

Neu can custom local fallback:

```powershell
$env:LOCAL_H264_FALLBACK="true"
$env:LOCAL_H264_FPS="30"
$env:LOCAL_H264_GOP="30"
$env:LOCAL_H264_MAX_WIDTH="720"
$env:LOCAL_H264_MAX_HEIGHT="1280"
$env:FFMPEG_PATH="ffmpeg"
npm start
```
# nếu không được thì reset
```
taskkill /F /IM ios.exe
ios --udid=00008020-000A1DE21E62002E tunnel start --userspace
powershell -ExecutionPolicy Bypass -File .\scripts\run-wda-go-ios.ps1 -SkipInstall
powershell -ExecutionPolicy Bypass -File .\scripts\forward-go-ios.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\check-wda.ps1
```



### kill server
kill "$(lsof -tiTCP:3000 -sTCP:LISTEN)"
