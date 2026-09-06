ios --udid=00008120-001278CA3693C01E runwda \
  --bundleid=app.jackfruit7234.pearl2737 \
  --testrunnerbundleid=app.jackfruit7234.pearl2737 \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=-1 \
  --env=WDA_REALTIME_CONTROL_ENABLED=1 \
  --env=WDA_REALTIME_CONTROL_PORT=8003 \
  --env=MJPEG_SCALING_FACTOR=45 \
  --env=MJPEG_SERVER_SCREENSHOT_QUALITY=20 \
  --log-output=-


ios --udid=00008120-001278CA3693C01E tunnel start --userspace
