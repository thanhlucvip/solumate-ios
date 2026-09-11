# secret-ios-solumate

Node server dung cho 2 viec:

- `/ios_check_active`: IPA/WDA tu goi 1 lan khi khoi dong de check build fingerprint.
- `/gesture/sign`: server ky gesture cho `pointArray`, tap/swipe realtime; private key nam tren server.

## Runtime auth moi

IPA khong can launch env tu `xctest_kicker.py` nua. Khi app duoc mo bang icon tren iPhone, WDA goi:

```text
GET https://active.solumate.vn/ios_check_active
X-Solumate-Build-Fingerprint: v3:<sha256>
```

Moi build se tinh fingerprint tu code sections cua ba binary chinh, ghi vao
`SOLUMATE_BUILD_FINGERPRINT` trong `Info.plist` cua app/xctest/framework, sau do
WDA doc gia tri nay va gui qua header o tren khi startup. Vi vay viec doi
bundle id, ten app, icon, ky lai hoac ky TrollStore khong doi fingerprint.

Server chi so sanh fingerprint nay voi `SOLUMATE_RUNTIME_ALLOWED_BUILD_FINGERPRINTS`.
Neu trung, server tra `active: true` va app tiep tuc chay. Neu thieu hoac sai
fingerprint, app se thoat luc startup.

Moi request check se duoc ghi ra console server, vi du:

```text
[ios_check_active] 2026-09-09T11:30:00.000Z ALLOW http=200 policy=solumate-fingerprint ip=... device=... bundle=... os=... model=... fp=v3:abc12345...89abcdef ua=SolumateIos/1.0
```

Log nay dung de biet thiet bi nao vua mo app va goi auth. Server chi log
fingerprint rut gon, khong log secret/private key.

Fingerprint format hien tai la `v3`. No chi hash cac Mach-O code sections cua:

- app runner binary
- `WebDriverAgentRunner.xctest`
- `WebDriverAgentLib.framework`

Vi vay viec ky lai IPA hoac bundle id bi doi boi tool sign/TrollStore khong lam
doi fingerprint, mien la code binary khong bi sua.

## Start server

```bash
cd secret-ios-solumate
node server.js
```

Bien quan trong trong `.env` server:

```text
HOST=0.0.0.0
PORT=9100
SOLUMATE_RUNTIME_POLICY_PATH=/ios_check_active
SOLUMATE_RUNTIME_POLICY_ALLOW_FINGERPRINT_ONLY=1
SOLUMATE_RUNTIME_ALLOWED_BUILD_FINGERPRINTS=v3:...,v3:...
SOLUMATE_GESTURE_SIGNER_PATH=/gesture/sign
SOLUMATE_GESTURE_SIGNER_SECRET=...
SOLUMATE_WDA_GESTURE_SIGNATURE_MODE=ecdsa-p256
SOLUMATE_WDA_GESTURE_PRIVATE_KEY=...
```

Khong dua private key hoac secret vao IPA, docs, log public.

## Release workflow

Tu root repo:

```bash
./build.sh
```

Script se build:

- `solumate.ipa`
- `solumate-trollstore.ipa`

Sau do `build.sh` tu chay:

```bash
node secret-ios-solumate/fingerprint-ipa.js \
  ./solumate.ipa \
  ./solumate-trollstore.ipa \
  --write-env secret-ios-solumate/.env
```

Hai script WDA cung tu dong nhung fingerprint vao IPA truoc khi dong goi; lenh
tren chi cap nhat whitelist server cho hai fingerprint vua build.

Viec can lam tren server sau moi ban build:

- copy `.env` moi len server
- restart `secret-ios-solumate`
- chi deploy lai `server.js` khi code server thay doi

Kiem tra server:

```bash
curl https://active.solumate.vn/healthz
```

Can thay `buildFingerprintLock: true` va `fingerprintOnlyPolicy: true`.

Test fingerprint:

```bash
curl -i \
  -H 'X-Solumate-Build-Fingerprint: v3:<fingerprint-trong-env>' \
  https://active.solumate.vn/ios_check_active
```

## Gesture signer

`ios_stream_v1`/proxy goi `/gesture/sign` de lay chu ky cho gesture message.
Endpoint nay van dung timestamp/nonce/HMAC rieng de bao ve private key server,
khac voi `/ios_check_active`.

WDA chi can public key bake san trong binary de verify chu ky gesture. Private
key P-256 nam trong `.env` server.

## Legacy

`/client/launch-env` van con trong `server.js` de tuong thich nguoc, nhung flow
moi khong dung endpoint nay nua. `window-run/xctest_kicker.py` khong tu doc
`.env` va khong goi `/client/launch-env`.
