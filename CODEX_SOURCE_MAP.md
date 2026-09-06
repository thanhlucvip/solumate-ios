# CODEX SOURCE MAP

File nay chi de nhac cau truc 2 source hien co trong repo. Khong dung no de lap lai cac buoc build/cai dat cu.

## Tong quan

- `WDA-trollstore/`: source cho IPA cai qua TrollStore.
- `WDA-sign/`: source cho IPA sign binh thuong.
- `ios_stream_v1/`: layer web/stream/control chung da gom ra root.
- `build.sh`: build ca hai IPA.
- `forward.sh`: forward port device, khong run `ios_stream_v1` nua.

## WDA-trollstore

- Muc dich: chay khi app duoc cai qua TrollStore.
- Control mode:
  - `socket-realtime-trollstore`: realtime control rieng cho TrollStore-installed IPA.
  - `realtime-control-mesh`: socket chung cho `pointArray` va `swipe`.
- Dac trung:
  - app name, package, icon dong bo voi Solumate.
  - co bootstrap / runtime policy / HID entitlements phuc vu TrollStore.
- Entry points:
  - `WDA-trollstore/Scripts/build-ios15-solumate-unsigned-ipa.sh`
  - `WDA-trollstore/redme.md`
  - `WDA-trollstore/codex-setup-source.md`

## WDA-sign

- Muc dich: chay khi app duoc sign va cai binh thuong.
- Control mode:
  - `realtime-control-mesh`: socket chung cho `pointArray` va `swipe`.
  - khong dung `socket-realtime-trollstore` cho mode TrollStore-only.
- Dac trung:
  - bundle id / metadata theo namespace Solumate.
  - phu hop luong signing/provisioning thong thuong.
- Entry points:
  - `WDA-sign/Scripts/build-ios15-solumate-unsigned-ipa.sh`
  - `WDA-sign/redme.md`
  - `WDA-sign/codex-setup-source.md`

## Shared pieces

- `ios_stream_v1/run.md`
- `ios_stream_v1/run-macos.md`
- `WebDriverAgentLib/Utilities/FBConfiguration.m` trong ca hai source
- `Bootstrap/SolumateBootstrap.m` trong ca hai source

## Nho cho session sau

- Uu tien hieu 2 mode:
  - `socket-realtime-trollstore`
  - `realtime-control-mesh`
- Neu can sua control, phai phan biet dung source nao dang build.
- Khong tao lai `ios_stream_v1` ben trong tung source.
- Doc file nay truoc, sau do moi tiep tuc task moi.
