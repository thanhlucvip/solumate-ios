'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const privateKeyPath = path.resolve(args.privateKey || 'keys/gesture-private-p256.pem');
  const publicKeyPath = path.resolve(args.publicKey || 'keys/gesture-public-p256.txt');

  if (fs.existsSync(privateKeyPath) || fs.existsSync(publicKeyPath)) {
    throw new Error(
      'Refusing to overwrite an existing gesture key. Choose new paths or remove the old files deliberately.',
    );
  }

  const {privateKey, publicKey} = crypto.generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    privateKeyEncoding: {type: 'pkcs8', format: 'pem'},
    publicKeyEncoding: {type: 'spki', format: 'der'},
  });

  const rawPublicKey = extractRawP256PublicKey(publicKey);
  ensureParent(privateKeyPath);
  ensureParent(publicKeyPath);
  fs.writeFileSync(privateKeyPath, privateKey, {mode: 0o600});
  fs.writeFileSync(publicKeyPath, `${rawPublicKey.toString('base64url')}\n`, {
    mode: 0o644,
  });

  process.stdout.write(`private key: ${privateKeyPath}\n`);
  process.stdout.write(`public key:  ${publicKeyPath}\n`);
  process.stdout.write(
    'Keep the private key on the server and copy only the public key value to WDA.\n',
  );
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--private-key') {
      result.privateKey = argv[++index];
    } else if (arg === '--public-key') {
      result.publicKey = argv[++index];
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write(
        'Usage: node generate-gesture-key.js [--private-key path] [--public-key path]\n',
      );
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return result;
}

function extractRawP256PublicKey(spkiDer) {
  const der = Buffer.from(spkiDer);
  const marker = Buffer.from([0x03, 0x42, 0x00, 0x04]);
  const markerOffset = der.indexOf(marker);
  if (markerOffset < 0 || der.length < markerOffset + marker.length + 64) {
    throw new Error('Unable to extract the raw P-256 public key from SPKI');
  }
  return der.subarray(markerOffset + 3, markerOffset + 3 + 65);
}

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), {recursive: true});
}

main();
