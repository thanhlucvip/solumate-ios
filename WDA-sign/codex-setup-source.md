# Setup WDA/SolumateIos tren Mac moi

File nay la handoff cho Codex khi mang source sang mot may Mac khac. Muc tieu la build/cai/chay WDA voi bundle id co dinh `solumate.driver.automation`, sau do mo web stream/control UI.

## Nguyen tac

- Khong gia dinh duong dan `/Users/apple` ton tai tren may moi.
- Khong gia dinh thiet bi da paired/trusted voi may moi.
- Khong gia dinh certificate/provisioning profile cua may cu co tren may moi.
- Bundle id WDA co dinh: `solumate.driver.automation`.
- Neu build/run bang `xcodebuild test`, Xcode co the bao runner host `solumate.driver.automation.xctrunner`. Day la runner do Xcode sinh ra khi UI test, khong duoc doi base id ve id cu.
- Cac file `.ipa`, `build/`, `artifacts/`, `logs/`, `devimages/` la artifact/state theo may. Co the tham khao, nhung khong coi la source setup bat buoc.

## 1. Kiem tra moi truong

Chay tai root repo:

```bash
pwd
git status --short
xcodebuild -version
xcode-select -p
node -v
npm -v
which ios || true
```

Yeu cau:

- macOS co Xcode day du.
- Node phu hop `package.json`: Node 20.19+, 22.12+, hoac 24+.
- `go-ios` command ten la `ios`.

Neu thieu `go-ios`:

```bash
npm install -g go-ios
hash -r
ios --version
```

Neu Xcode khong nam o `/Applications/Xcode.app`, set:

```bash
export DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
```

## 2. Kiem tra source khong con bundle id cu

Repo phai khong con cac id WDA cu:

```bash
rg -n 'com\.lucthanh|com\.solumate\.driver|app\.star6979|com\.facebook\.WebDriverAgentRunner|com\.facebook\.WebDriverAgentLib|com\.facebook\.IntegrationTests|com\.facebook\.WebDriverAgentCoreTests|solumate\.xxx\.xctrunner' . -g '!setup.md'
```

Lenh tren nen khong in ket qua nao. Neu co ket qua, doi ve namespace `solumate.driver.automation` truoc khi build. Khong doi cac bundle id he thong nhu `com.apple.Preferences` hoac `com.apple.mobilesafari`.

Kiem tra project:

```bash
plutil -lint WebDriverAgent.xcodeproj/project.pbxproj
xcodebuild -project WebDriverAgent.xcodeproj -target WebDriverAgentRunner -showBuildSettings -configuration Debug | rg 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN'
```

`PRODUCT_BUNDLE_IDENTIFIER` cua WDA phai la `solumate.driver.automation`.

## 3. Cai Node dependencies

```bash
npm install
npm run build
```

Neu chi can web UI trong `../ios_stream_v1`, cai dependency trong thu muc web UI chung. Sau do co the chay server bang:

```bash
cd ../ios_stream_v1
npm install
npm start
```

## 4. Signing va provisioning

May moi can co signing rieng. Kiem tra identities:

```bash
security find-identity -v -p codesigning
```

Can co Apple Development certificate co private key. Neu khong co, dang nhap Apple ID trong Xcode hoac import `.p12` dung team.

Project hien co `DEVELOPMENT_TEAM` trong `WebDriverAgent.xcodeproj/project.pbxproj`. Neu team tren may moi khac, co hai cach:

1. Tam thoi override luc build:

```bash
xcodebuild \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  PRODUCT_BUNDLE_IDENTIFIER=solumate.driver.automation \
  WDA_PRODUCT_BUNDLE_IDENTIFIER=solumate.driver.automation \
  -allowProvisioningUpdates \
  build-for-testing
```

2. Hoac sua project sang team moi neu do la cau hinh chinh thuc.

Build unsigned bằng Xcode 15.4 để ký ngoài:

```bash
DEVELOPER_DIR="/Applications/Xcode-15.4.0.app/Contents/Developer" \
WDA_BUNDLE_ID=solumate.driver.automation \
./Scripts/build-ios15-solumate-unsigned-ipa.sh
```

Script build unsigned tao IPA chua ky. Muon cai len thiet bi that thi phai ky bang certificate/profile hop le cho `solumate.driver.automation`.

## 5. Pair iPad/iPhone voi Mac moi

Cam USB, mo khoa thiet bi, bam Trust tren thiet bi. Kiem tra:

```bash
ios list --details
xcrun devicectl list devices
xcrun xctrace list devices
```

Neu CoreDevice bao unpaired:

```bash
xcrun devicectl manage pair --device <UDID> --timeout 120
```

Neu can Developer Mode:

```bash
ios --udid=<UDID> devmode get
ios --udid=<UDID> devmode enable
```

Neu iOS 17+:

```bash
ios --udid=<UDID> tunnel start --userspace
```

Giu terminal tunnel dang chay.

## 6. Mount DDI / Developer Image

Kiem tra:

```bash
ios --udid=<UDID> image list
xcrun devicectl device info ddiServices --device <UDID> --timeout 30
```

Neu chua co DDI:

```bash
ios --udid=<UDID> image auto
```

Neu `ios image auto` fail voi TSS/signature, thu de Xcode/CoreDevice prepare DDI:

```bash
xcrun devicectl device info ddiServices --device <UDID> --timeout 60
```

Neu van fail, mo Xcode > Window > Devices and Simulators, pair lai, de Xcode prepare device, roi chay lai.

## 7. Cai va chay WDA bang go-ios

Neu da co IPA da ky hop le:

```bash
ios --udid=<UDID> install --path=/path/to/solumate.ipa
```

Chay WDA:

```bash
ios --udid=<UDID> runwda \
  --bundleid=solumate.driver.automation \
  --testrunnerbundleid=solumate.driver.automation \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=8002 \
  --env=MJPEG_SCALING_FACTOR=45 \
  --env=MJPEG_SERVER_SCREENSHOT_QUALITY=20 \
  --env=MJPEG_SERVER_FRAMERATE=30 \
  --log-output=-
```

Neu build co startup password:

```bash
export WDA_STARTUP_PASSWORD=SolumateIos
```

Neu dung pointArray:

```bash
export SOLUMATE_WDA_ENABLE_POINT_ARRAY=1
export SOLUMATE_WDA_SWIPE_SECRET="<secret>"
```

## 8. Forward port va kiem tra WDA

Mo terminal rieng:

```bash
ios --udid=3b1eea0514dec1c5188f9cdcf53e784acacfc155 forward 8000 8000
```

Mo terminal khac:

```bash
ios --udid=3b1eea0514dec1c5188f9cdcf53e784acacfc155 forward 8001 8001
```

Kiem tra:

```bash
curl http://127.0.0.1:8000/status
curl -I http://127.0.0.1:8001/
```

## 9. Chay web UI

Tai root repo:

```bash
npm install
npm start
```

Mo:

```text
http://localhost:3000
```

Neu may co the bi truy cap tu LAN/VPN/Internet:

```bash
export HOST=127.0.0.1
export STREAM_AUTH_TOKEN="<random-token>"
export ALLOWED_ORIGIN="http://localhost:3000"
npm start
```

Mo:

```text
http://localhost:3000/?auth=<random-token>
```

## 10. Loi thuong gap

### Xcode bao `unpaired`

Mo khoa thiet bi, bam Trust/Pair tren man hinh, roi chay:

```bash
xcrun devicectl manage pair --device <UDID> --timeout 120
```

### Thieu profile/cert

Neu thay:

```text
No profiles for 'solumate.driver.automation...'
No signing certificate "iOS Development"
```

May moi chua co signing dung. Can Apple Development cert co private key va provisioning profile cho `solumate.driver.automation`, hoac dung `-allowProvisioningUpdates` voi Apple ID/team phu hop.

### `ios runwda` timeout hoac `broken pipe`

Thu theo thu tu:

```bash
ios --udid=<UDID> tunnel stop || true
ios --udid=<UDID> tunnel start --userspace
ios --udid=<UDID> image list
ios --udid=<UDID> image auto
```

Sau do chay lai `runwda`. Neu van loi, mo Xcode Devices and Simulators de prepare device/DDI.

### `ios` khong tim thay

Set explicit binary:

```bash
export GO_IOS_BIN="$(command -v ios)"
export IOS_BIN="$GO_IOS_BIN"
```

Neu khong co ket qua, cai lai:

```bash
npm install -g go-ios
hash -r
```

## 11. Checklist ban giao cho Codex tren Mac moi

1. Doc file nay truoc.
2. Khong dung duong dan `/Users/apple` lam gia dinh.
3. Kiem tra `rg` khong con bundle id cu.
4. Xac nhan `PRODUCT_BUNDLE_IDENTIFIER = solumate.driver.automation`.
5. Cai Node deps va build TypeScript.
6. Setup signing/provisioning cho `solumate.driver.automation`.
7. Pair thiet bi va mount DDI.
8. Cai IPA da ky hoac build/sign IPA moi.
9. Chay WDA voi `--bundleid=solumate.driver.automation --testrunnerbundleid=solumate.driver.automation`.
10. Forward 8000/8001/8002, `curl /status`, roi chay web UI.
