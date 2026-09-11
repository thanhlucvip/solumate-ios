## Chay WDA ban sign

Bundle ID hien tai: `solumate.driver.automation`

```bash
ios --udid=<UDID> runwda \
  --bundleid=solumate.driver.automation \
  --testrunnerbundleid=solumate.driver.automation \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=-1 \
  --env=WDA_REALTIME_CONTROL_ENABLED=1 \
  --env=WDA_REALTIME_CONTROL_PORT=8003 \
  --env=MJPEG_SCALING_FACTOR=45 \
  --env=MJPEG_SERVER_SCREENSHOT_QUALITY=20 \
  --env=MJPEG_SERVER_FRAMERATE=30 \
  --log-output=-
```

Kiem tra WDA:

```bash
curl http://127.0.0.1:8000/status
```
