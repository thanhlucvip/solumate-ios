'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_CIGAM = 0xbebafeca;
const CPU_TYPE_ARM64 = 0x0100000c;
const LC_SEGMENT_64 = 0x19;
const HEADER_SIZE_64 = 32;
const SEGMENT_COMMAND_SIZE_64 = 72;
const SECTION_SIZE_64 = 80;
const SEG_LINKEDIT = '__LINKEDIT';
const S_ZEROFILL = 0x1;

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.ipaPaths.length === 0) {
    printUsage();
    process.exit(1);
  }
  if (args.plistPath && args.ipaPaths.length !== 1) {
    throw new Error('--write-plist requires exactly one ipa-or-app input');
  }

  const results = [];
  for (const ipaPath of args.ipaPaths) {
    const result = fingerprintInput(path.resolve(ipaPath));
    results.push(result);
    process.stdout.write(`${result.label}: ${result.fingerprint}\n`);
  }

  if (args.envPath) {
    updateEnvWhitelist(path.resolve(args.envPath), results.map((result) => result.fingerprint));
    process.stdout.write(`updated: ${path.resolve(args.envPath)}\n`);
  }
  if (args.plistPath) {
    updatePlistFingerprint(path.resolve(args.plistPath), results[0].fingerprint);
    process.stdout.write(`updated: ${path.resolve(args.plistPath)}\n`);
  }
}

function parseArgs(argv) {
  const result = {ipaPaths: [], envPath: '', plistPath: ''};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--write-env') {
      result.envPath = argv[++index] || '';
      if (!result.envPath) {
        throw new Error('--write-env requires a file path');
      }
      continue;
    }
    if (arg === '--write-plist') {
      result.plistPath = argv[++index] || '';
      if (!result.plistPath) {
        throw new Error('--write-plist requires a file path');
      }
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    }
    if (arg.startsWith('-')) {
      throw new Error(`Unknown option: ${arg}`);
    }
    result.ipaPaths.push(arg);
  }
  return result;
}

function printUsage() {
  process.stdout.write(
    'Usage: node fingerprint-ipa.js <ipa-or-app> [<ipa-or-app> ...] [--write-env path] [--write-plist path]\n',
  );
}

function fingerprintInput(inputPath) {
  if (!fs.existsSync(inputPath)) {
    throw new Error(`Input not found: ${inputPath}`);
  }

  if (inputPath.endsWith('.app')) {
    return {
      label: path.basename(inputPath),
      fingerprint: fingerprintApp(inputPath),
    };
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'solumate-fingerprint-'));
  try {
    const unzip = childProcess.spawnSync(
      '/usr/bin/unzip',
      ['-q', '-o', inputPath, '-d', tempDir],
      {encoding: 'utf8'},
    );
    if (unzip.status !== 0) {
      throw new Error(`Unable to extract ${inputPath}: ${(unzip.stderr || '').trim()}`);
    }

    const payloadDir = path.join(tempDir, 'Payload');
    const apps = fs.existsSync(payloadDir)
      ? fs.readdirSync(payloadDir)
        .filter((entry) => entry.endsWith('.app'))
        .map((entry) => path.join(payloadDir, entry))
      : [];
    if (apps.length !== 1) {
      throw new Error(`Expected one app in ${inputPath}, found ${apps.length}`);
    }
    return {
      label: path.basename(inputPath),
      fingerprint: fingerprintApp(apps[0]),
    };
  } finally {
    fs.rmSync(tempDir, {recursive: true, force: true});
  }
}

function fingerprintApp(appPath) {
  const parts = [
    'solumate-build-v3',
    `runner-code=${machoSectionsSha256(path.join(appPath, 'WebDriverAgentRunner-Runner'))}`,
    `xctest-code=${machoSectionsSha256(path.join(
      appPath,
      'PlugIns/WebDriverAgentRunner.xctest/WebDriverAgentRunner',
    ))}`,
    `wda-code=${machoSectionsSha256(path.join(
      appPath,
      'PlugIns/WebDriverAgentRunner.xctest/Frameworks/WebDriverAgentLib.framework/WebDriverAgentLib',
    ))}`,
  ];
  return `v3:${crypto.createHash('sha256').update(parts.join('\n'), 'utf8').digest('hex')}`;
}

function fileSha256(filePath) {
  if (!fs.existsSync(filePath)) {
    return '';
  }
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function plistValue(plistPath, key) {
  const result = childProcess.spawnSync(
    '/usr/libexec/PlistBuddy',
    ['-c', `Print :${key}`, plistPath],
    {encoding: 'utf8'},
  );
  return result.status === 0 ? result.stdout.trim() : '';
}

function machoSectionsSha256(filePath) {
  if (!fs.existsSync(filePath)) {
    return '';
  }
  const data = fs.readFileSync(filePath);
  const slice = arm64Slice(data);
  if (!slice || slice.length < HEADER_SIZE_64 || slice.readUInt32LE(0) !== MH_MAGIC_64) {
    return fileSha256(filePath);
  }

  const ncmds = slice.readUInt32LE(16);
  const sizeofcmds = slice.readUInt32LE(20);
  const commandsOffset = HEADER_SIZE_64;
  const commandsEnd = commandsOffset + sizeofcmds;
  if (commandsEnd > slice.length) {
    return fileSha256(filePath);
  }

  const hash = crypto.createHash('sha256');
  let foundSection = false;
  let cursorOffset = commandsOffset;
  for (let commandIndex = 0; commandIndex < ncmds; commandIndex += 1) {
    if (cursorOffset > commandsEnd || commandsEnd - cursorOffset < 8) {
      return fileSha256(filePath);
    }

    const command = slice.readUInt32LE(cursorOffset);
    const commandSize = slice.readUInt32LE(cursorOffset + 4);
    if (commandSize < 8 || commandSize > commandsEnd - cursorOffset) {
      return fileSha256(filePath);
    }

    if (command === LC_SEGMENT_64 && commandSize >= SEGMENT_COMMAND_SIZE_64) {
      const segmentName = slice.subarray(cursorOffset + 8, cursorOffset + 24);
      const sectionCount = slice.readUInt32LE(cursorOffset + 64);
      const sectionsOffset = cursorOffset + SEGMENT_COMMAND_SIZE_64;
      const sectionsBytes = sectionCount * SECTION_SIZE_64;
      if (sectionsBytes > commandSize - SEGMENT_COMMAND_SIZE_64) {
        return fileSha256(filePath);
      }

      const isLinkedit = segmentName
        .subarray(0, SEG_LINKEDIT.length)
        .toString('ascii') === SEG_LINKEDIT;
      if (!isLinkedit) {
        for (let sectionIndex = 0; sectionIndex < sectionCount; sectionIndex += 1) {
          const sectionOffset = sectionsOffset + sectionIndex * SECTION_SIZE_64;
          const sectionSize = slice.readBigUInt64LE(sectionOffset + 40);
          const fileOffset = slice.readUInt32LE(sectionOffset + 48);
          const flags = slice.readUInt32LE(sectionOffset + 64);
          const sectionEnd = BigInt(fileOffset) + sectionSize;
          if (
            sectionSize === 0n ||
            (flags & S_ZEROFILL) !== 0 ||
            fileOffset > slice.length ||
            sectionEnd > BigInt(slice.length)
          ) {
            continue;
          }

          hash.update(segmentName);
          hash.update(slice.subarray(sectionOffset, sectionOffset + 16));
          hash.update(slice.subarray(sectionOffset + 40, sectionOffset + 48));
          hash.update(slice.subarray(fileOffset, Number(sectionEnd)));
          foundSection = true;
        }
      }
    }
    cursorOffset += commandSize;
  }

  return foundSection ? hash.digest('hex') : fileSha256(filePath);
}

function arm64Slice(data) {
  if (data.length < 4) {
    return null;
  }

  const magic = data.readUInt32LE(0);
  if (magic === MH_MAGIC_64) {
    return data;
  }
  if (magic !== FAT_CIGAM && magic !== FAT_MAGIC) {
    return null;
  }

  const swap = magic === FAT_CIGAM;
  const readUInt32 = (offset) => (
    swap ? data.readUInt32BE(offset) : data.readUInt32LE(offset)
  );
  if (data.length < 8) {
    return null;
  }

  const architectureCount = readUInt32(4);
  for (let index = 0; index < architectureCount; index += 1) {
    const architectureOffset = 8 + index * 20;
    if (architectureOffset + 20 > data.length) {
      return null;
    }
    const cpuType = readUInt32(architectureOffset);
    const sliceOffset = readUInt32(architectureOffset + 8);
    const sliceSize = readUInt32(architectureOffset + 12);
    if (cpuType !== CPU_TYPE_ARM64) {
      continue;
    }
    if (sliceOffset > data.length || sliceSize > data.length - sliceOffset) {
      return null;
    }
    return data.subarray(sliceOffset, sliceOffset + sliceSize);
  }
  return null;
}

function updateEnvWhitelist(envPath, fingerprints) {
  if (!fs.existsSync(envPath)) {
    throw new Error(`Env file not found: ${envPath}`);
  }
  const current = fs.readFileSync(envPath, 'utf8');
  const nextLine = `SOLUMATE_RUNTIME_ALLOWED_BUILD_FINGERPRINTS=${fingerprints.join(',')}`;
  const linePattern = /^SOLUMATE_RUNTIME_ALLOWED_BUILD_FINGERPRINTS=.*$/m;
  const updated = linePattern.test(current)
    ? current.replace(linePattern, nextLine)
    : `${current.trimEnd()}\n${nextLine}\n`;
  fs.writeFileSync(envPath, updated);
}

function updatePlistFingerprint(plistPath, fingerprint) {
  if (!fs.existsSync(plistPath)) {
    throw new Error(`Plist file not found: ${plistPath}`);
  }

  const key = 'SOLUMATE_BUILD_FINGERPRINT';
  const current = childProcess.spawnSync(
    '/usr/libexec/PlistBuddy',
    ['-c', `Print :${key}`, plistPath],
    {encoding: 'utf8'},
  );
  const command = current.status === 0
    ? `Set :${key} ${fingerprint}`
    : `Add :${key} string ${fingerprint}`;
  const result = childProcess.spawnSync(
    '/usr/libexec/PlistBuddy',
    ['-c', command, plistPath],
    {encoding: 'utf8'},
  );
  if (result.status !== 0) {
    throw new Error(
      `Unable to write ${key} to ${plistPath}: ${(result.stderr || result.stdout || '').trim()}`,
    );
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error && error.message ? error.message : error}\n`);
  process.exit(1);
}
