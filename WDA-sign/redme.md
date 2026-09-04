ios --udid=00008120-001278CA3693C01E runwda \
  --bundleid=app.jackfruit7234.pearl2737 \
  --testrunnerbundleid=app.jackfruit7234.pearl2737 \
  --xctestconfig=WebDriverAgentRunner.xctest \
  --env=USE_PORT=8000 \
  --env=MJPEG_SERVER_PORT=8001 \
  --env=H264_SERVER_PORT=8002 \
  --env=H264_MAX_WIDTH=960 \
  --env=H264_MAX_HEIGHT=960 \
  --env=H264_BITRATE=1800000 \
  --env=H264_FPS=15 \
  --env=H264_GOP=3 \
  --env=H264_QUALITY=30 \
  --env=MJPEG_SCALING_FACTOR=45 \
  --env=MJPEG_SERVER_SCREENSHOT_QUALITY=20 \
  --log-output=-


ios --udid=00008120-001278CA3693C01E tunnel start --userspace
