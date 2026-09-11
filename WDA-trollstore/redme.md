## Chay WDA ban TrollStore

Bundle ID hien tai: `solumate.driver.automation`

Neu IPA da duoc cai qua TrollStore, chay WDA qua XCTest/testmanager:

```bash
GO_IOS_UDID=<UDID> \
SKIP_INSTALL=1 \
WDA_BUNDLE_ID=solumate.driver.automation \
WDA_USE_RUNWDA=1 \
bash ../ios_stream_v1/scripts/run-wda-go-ios.sh
```

Khong dung bundle ID cu trong cac lenh `runwda`. `WDA_USE_RUNWDA=0` chi dung
de test standalone/icon launch.

Kiem tra WDA:

```bash
curl http://127.0.0.1:8000/status
```
