# Run nhanh tren macOS (go-ios + WDA)

## 0) Kiem tra go-ios

```bash
which ios
ios --version
ios -h | grep -E "tunnel start|tunnel ls"
```

```
ios pair
ios devmode enable
ios image auto
ios image list
```

Neu `ios -h` khong thay `tunnel start`, ban dang dung go-ios qua cu. Cap nhat:

```bash
npm uninstall -g go-ios
npm install -g go-ios@latest
hash -r
ios --version
ios -h | grep -E "tunnel start|tunnel ls"
```

## 1) Start tunnel (giu cua so mo)

```bash
ios --udid=00008027-000404D13439002E tunnel start --userspace
ios --udid=00008120-001278CA3693C01E tunnel start --userspace
```

Ghi chu:

- Voi go-ios moi, khong can `--userspace` (mac dinh da la userspace).
- Neu muon thu kernel tun mode: them `--enabletun`.

## 2) Run WDA (giu cua so mo)

```bash
ios runwda \
  --bundleid=solumate.driver.automation \
  --testrunnerbundleid=solumate.driver.automation \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=-1 \
  --env=WDA_REALTIME_CONTROL_ENABLED=1 \
  --env=WDA_REALTIME_CONTROL_PORT=8003 \
  --log-output=-
```

```bash
ios runwda \
  --bundleid=solumate.driver.automation \
  --testrunnerbundleid=solumate.driver.automation \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=-1 \
  --env=WDA_REALTIME_CONTROL_ENABLED=1 \
  --env=WDA_REALTIME_CONTROL_PORT=8003 \
  --env=WDA_STARTUP_PASSWORD=SolumateIos \
  --log-output=-

```

## 3) Forward port (2 cua so rieng)

```bash
ios --udid=3b1eea0514dec1c5188f9cdcf53e784acacfc155 forward 8000 8000
```

```bash
ios --udid=3b1eea0514dec1c5188f9cdcf53e784acacfc155 forward 8001 8001
ios --udid=3b1eea0514dec1c5188f9cdcf53e784acacfc155 forward 8003 8003
```

## 4) Start web server

```bash
npm install
npm start
```

### 4.1) Hardening

Neu may co the bi truy cap tu LAN/VPN/Internet:

```bash
export HOST=127.0.0.1
export STREAM_AUTH_TOKEN="tao-token-dai-ngau-nhien"
export ALLOWED_ORIGIN="http://localhost:3000"
npm start
```

Mo UI bang:

```text
http://localhost:3000/?auth=tao-token-dai-ngau-nhien
```

Neu bat route `pointArray`, dat secret o ca terminal chay WDA va terminal chay server:

```bash
export SOLUMATE_WDA_ENABLE_POINT_ARRAY=1
export SOLUMATE_WDA_SWIPE_SECRET="tao-secret-dai-ngau-nhien"
```
