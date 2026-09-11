#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


def env_int(names: tuple[str, ...], default: int) -> int:
    for name in names:
        value = os.environ.get(name)
        if value is None or value.strip() == "":
            continue
        try:
            return int(value)
        except ValueError:
            pass
    return default


DEFAULT_WDA_PORT = env_int(("WDA_PORT", "USE_PORT"), 8000)
DEFAULT_MJPEG_PORT = env_int(("MJPEG_PORT", "MJPEG_SERVER_PORT"), 8001)
DEFAULT_H264_PORT = env_int(("H264_PORT", "H264_SERVER_PORT"), -1)
DEFAULT_REALTIME_CONTROL_PORT = env_int(("REALTIME_CONTROL_PORT", "WDA_REALTIME_CONTROL_PORT"), 8003)
DEFAULT_MJPEG_SCALE = env_int(("MJPEG_SCALING_FACTOR", "MJPEG_SCALE"), 45)
DEFAULT_MJPEG_QUALITY = env_int(("MJPEG_SERVER_SCREENSHOT_QUALITY", "MJPEG_QUALITY"), 20)
DEFAULT_MJPEG_FRAMERATE = env_int(("MJPEG_SERVER_FRAMERATE", "MJPEG_FRAMERATE"), 30)
DEFAULT_TIMEOUT = 60.0
DEFAULT_XCTESTCONFIG = "WebDriverAgentRunner.xctest"
INTERNAL_PMD3_SENTINEL = "__pmd3__"

DEFAULT_BUNDLE_IDS = (
    "solumate.driver.automation",
)
CONFIGURED_BUNDLE_ENV_KEYS = (
    "WDA_BUNDLE_ID",
    "WDA_PRODUCT_BUNDLE_IDENTIFIER",
    "DEFAULT_TROLLSTORE_BUNDLE_ID",
    "DEFAULT_BUNDLE_ID",
)
APP_BUNDLE_KEYS = (
    "CFBundleIdentifier",
    "BundleIdentifier",
    "bundleIdentifier",
    "bundleId",
    "BundleID",
    "bundleID",
    "applicationIdentifier",
    "ApplicationIdentifier",
)
SENSITIVE_ENV_PARTS = ("PASSWORD", "TOKEN", "SECRET")
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+$")
BUNDLE_ID_FIND_RE = re.compile(r"\b[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+\b")
NON_APP_BUNDLE_SUFFIXES = (
    ".app",
    ".appex",
    ".bundle",
    ".dylib",
    ".framework",
    ".plist",
    ".xctest",
)
LOW_PRIORITY_SUFFIXES = (
    ".lib",
    ".integrationtests",
    ".coretests",
    ".tvos.coretests",
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


@dataclass
class BundleCandidate:
    bundle_id: str
    source: str
    metadata: dict[str, Any] = field(default_factory=dict)
    verified: bool = False
    prefer_standalone: bool = False
    score: int = 0


def log(message: str = "") -> None:
    print(message, flush=True)


def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def unique_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        item = value.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        result.append(item)
    return result


def split_bundle_values(value: str | None) -> list[str]:
    if not value:
        return []
    return [item for item in re.split(r"[\s,;]+", value.strip()) if item]


def is_probable_udid(value: str | None) -> bool:
    if not value:
        return False
    compact = value.replace("-", "")
    return bool(re.fullmatch(r"[A-Fa-f0-9]{24,64}", compact))


def is_valid_bundle_id(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    item = value.strip().strip("'\"")
    if not BUNDLE_ID_RE.match(item):
        return False
    lower = item.lower()
    if lower.endswith(NON_APP_BUNDLE_SUFFIXES):
        return False
    return True


def mask_env_assignment(value: str) -> str:
    key, sep, raw_value = value.partition("=")
    if sep and any(part in key.upper() for part in SENSITIVE_ENV_PARTS):
        return f"{key}=***"
    return f"{key}{sep}{raw_value}"


def display_command(argv: list[str]) -> str:
    result: list[str] = []
    mask_next_env = False
    for arg in argv:
        if mask_next_env:
            result.append(mask_env_assignment(arg))
            mask_next_env = False
            continue
        if arg == "--env":
            result.append(arg)
            mask_next_env = True
            continue
        if arg.startswith("--env="):
            result.append("--env=" + mask_env_assignment(arg[len("--env="):]))
            continue
        result.append(arg)
    return " ".join(result)


def run_command(
    argv: list[str],
    timeout: float | None = None,
    *,
    echo_output: bool = True,
) -> tuple[int, str]:
    log(f"> {display_command(argv)}")
    try:
        completed = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        output = completed.stdout or ""
        if echo_output and output.strip():
            log(output.rstrip())
        return completed.returncode, output
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        if output.strip():
            log(output.rstrip())
        log(f"TIMEOUT sau {timeout:.0f}s.")
        return 124, output
    except FileNotFoundError as exc:
        return 127, str(exc)


def popen_command(argv: list[str], output_file) -> subprocess.Popen:
    creationflags = 0
    start_new_session = False
    if os.name == "nt":
        creationflags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(
            subprocess, "CREATE_NEW_PROCESS_GROUP", 0
        )
    else:
        start_new_session = True
    env = os.environ.copy()
    env.setdefault("PYTHONUNBUFFERED", "1")
    return subprocess.Popen(
        argv,
        stdout=output_file,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        creationflags=creationflags,
        env=env,
        close_fds=True,
        start_new_session=start_new_session,
    )


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return

    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        except Exception:
            pass
    else:
        try:
            process.terminate()
        except Exception:
            pass

    try:
        process.wait(timeout=4)
    except Exception:
        try:
            process.kill()
            process.wait(timeout=4)
        except Exception:
            pass


def run_command_until(
    argv: list[str],
    success_predicate,
    timeout: float,
    post_match_grace: float = 0.0,
) -> tuple[int, str, bool]:
    log(f"> {display_command(argv)}")
    log_dir = Path(tempfile.gettempdir()) / "xctest-kicker"
    log_dir.mkdir(parents=True, exist_ok=True)
    command_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", argv[-1])[:80] or "wda"
    log_path = log_dir / f"{command_name}-{os.getpid()}-{time.time_ns()}.log"

    try:
        with log_path.open("wb") as output_file:
            process = popen_command(argv, output_file)
    except FileNotFoundError as exc:
        return 127, str(exc), False
    except OSError as exc:
        return 1, str(exc), False

    output_parts: list[str] = []
    deadline = time.monotonic() + timeout
    timed_out = False
    found = False
    grace_deadline: float | None = None

    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as output_reader:
            while True:
                chunk = output_reader.read()
                if chunk:
                    output_parts.append(chunk)
                    for line in chunk.splitlines():
                        if line:
                            log(line)

                output = "".join(output_parts)
                if not found and success_predicate(output):
                    found = True
                    grace_deadline = time.monotonic() + max(0.0, post_match_grace)

                if found and (grace_deadline is None or time.monotonic() >= grace_deadline):
                    if process.poll() is None:
                        log(
                            f"XCTest/WDA dang chay nen voi PID {process.pid}; "
                            f"giu session song, log: {log_path}"
                        )
                        return 0, output, True
                    break

                if process.poll() is not None:
                    final_chunk = output_reader.read()
                    if final_chunk:
                        output_parts.append(final_chunk)
                        for line in final_chunk.splitlines():
                            if line:
                                log(line)
                    break

                if time.monotonic() >= deadline:
                    timed_out = True
                    stop_process(process)
                    break

                time.sleep(0.05)
    except KeyboardInterrupt:
        stop_process(process)
        raise

    output = "".join(output_parts)
    if timed_out:
        log(f"TIMEOUT sau {timeout:.0f}s.")
        return 124, output, False
    if found:
        log("XCTest/WDA da start nhung process dieu khien thoat ngay sau do.")
        return process.returncode or 4, output, False
    return process.returncode or 0, output, False


def find_external_pmd3() -> list[str] | None:
    exe_name = "pymobiledevice3.exe" if os.name == "nt" else "pymobiledevice3"
    candidates = [
        app_dir() / ".venv-pmd3" / "Scripts" / exe_name,
        app_dir() / "venv-pmd3" / "Scripts" / exe_name,
        app_dir() / "pymobiledevice3" / "Scripts" / exe_name,
    ]

    for candidate in candidates:
        if candidate.exists():
            return [str(candidate)]

    path_hit = shutil.which("pymobiledevice3")
    if path_hit:
        return [path_hit]

    uv_hit = shutil.which("uv")
    if uv_hit:
        return [uv_hit, "tool", "run", "--python", "3.12", "pymobiledevice3"]

    return None


def find_go_ios() -> list[str] | None:
    exe_name = "ios.exe" if os.name == "nt" else "ios"
    local_hit = app_dir() / exe_name
    if local_hit.exists():
        return [str(local_hit)]
    path_hit = shutil.which("ios")
    if path_hit:
        return [path_hit]
    return None


def parse_first_json(output: str):
    text = output.strip()
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            parsed, _ = decoder.raw_decode(text[index:])
            return parsed
        except json.JSONDecodeError:
            continue
    return None


def compact_json_text(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    except TypeError:
        return str(value)


def extract_device_udids_from_json(value: Any) -> list[str]:
    result: list[str] = []
    if isinstance(value, str):
        if value.strip():
            result.append(value.strip())
        return result
    if isinstance(value, list):
        for item in value:
            result.extend(extract_device_udids_from_json(item))
        return result
    if isinstance(value, dict):
        for key in (
            "Identifier",
            "UniqueDeviceID",
            "UDID",
            "udid",
            "SerialNumber",
            "DeviceIdentifier",
            "DeviceID",
            "deviceId",
            "ID",
        ):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                result.append(candidate.strip())
                break
        for child in value.values():
            if isinstance(child, (dict, list)):
                result.extend(extract_device_udids_from_json(child))
    return result


def extract_device_udids(output: str) -> list[str]:
    parsed = parse_first_json(output)
    if parsed is not None:
        return unique_preserve_order(extract_device_udids_from_json(parsed))

    hits = re.findall(r"\b[A-Fa-f0-9]{40}\b|\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b", output)
    return unique_preserve_order(hits)


def device_seen(output: str, udid: str) -> bool:
    return udid in extract_device_udids(output) or udid in output


def looks_ready(output: str) -> bool:
    parsed = parse_first_json(output)
    if isinstance(parsed, dict):
        if parsed.get("ready") is True:
            return True
        message = str(parsed.get("message", "")).lower()
        return "ready to accept commands" in message

    text = output.lower()
    return '"ready": true' in text or "ready to accept commands" in text


def looks_xctest_started(output: str) -> bool:
    markers = (
        "testrunnerreadywithcapabilities",
        "didbeginexecutingtestplan",
        "testsuitewithidentifier",
        "testcasedidstart",
        "[plan] begin",
        "[case]  start",
        "[case] start",
        "notifying test runner ready",
        "received test runner ready reply",
        "running tests with active test configuration",
        "test suite 'webdriveragentrunner.xctest' started",
        "serverurlhere",
        "listening on port",
    )
    lower = output.lower()
    return any(marker in lower for marker in markers)


def run_internal_pmd3(args: list[str]) -> int:
    try:
        from pymobiledevice3.__main__ import main as pmd3_main
    except Exception as exc:
        log(f"Khong import duoc pymobiledevice3 bundled: {exc}")
        traceback.print_exc()
        return 127

    previous_argv = sys.argv[:]
    try:
        sys.argv = ["pymobiledevice3", *args]
        pmd3_main()
        return 0
    except SystemExit as exc:
        code = exc.code
        if code is None:
            return 0
        if isinstance(code, int):
            return code
        return 1
    except Exception as exc:
        log(f"pymobiledevice3 ket thuc voi loi: {type(exc).__name__}: {exc}")
        return 1
    finally:
        sys.argv = previous_argv


def internal_pmd3_command() -> list[str]:
    if getattr(sys, "frozen", False):
        return [str(Path(sys.executable).resolve()), INTERNAL_PMD3_SENTINEL]
    return [str(Path(sys.executable).resolve()), str(Path(__file__).resolve()), INTERNAL_PMD3_SENTINEL]


class Pymobiledevice3:
    def __init__(self, prefer_external: bool) -> None:
        self.prefer_external = prefer_external
        self.external = find_external_pmd3()
        has_bundled = getattr(sys, "frozen", False) or importlib.util.find_spec("pymobiledevice3") is not None
        self.internal = None if prefer_external or not has_bundled else internal_pmd3_command()

    def available(self) -> bool:
        return bool(self.internal or self.external)

    def run(
        self,
        args: list[str],
        timeout: float | None = None,
        *,
        echo_output: bool = True,
    ) -> tuple[int, str]:
        if self.internal:
            return run_command([*self.internal, *args], timeout=timeout, echo_output=echo_output)

        if not self.external:
            return 127, "Khong tim thay pymobiledevice3. Cai bang: py -m pip install -U pymobiledevice3"

        return run_command([*self.external, *args], timeout=timeout, echo_output=echo_output)

    def run_until(
        self,
        args: list[str],
        success_predicate,
        timeout: float,
        post_match_grace: float = 0.0,
    ) -> tuple[int, str, bool]:
        if self.internal:
            return run_command_until(
                [*self.internal, *args],
                success_predicate=success_predicate,
                timeout=timeout,
                post_match_grace=post_match_grace,
            )

        if not self.external:
            return 127, "Khong tim thay pymobiledevice3. Cai bang: py -m pip install -U pymobiledevice3", False

        return run_command_until(
            [*self.external, *args],
            success_predicate=success_predicate,
            timeout=timeout,
            post_match_grace=post_match_grace,
        )


def pmd3_device_args(args: argparse.Namespace, udid: str) -> list[str]:
    result = ["--udid", udid]
    if args.userspace:
        result.append("--userspace")
    return result


def wait_for_device(pmd3: Pymobiledevice3, udid: str, attempts: int) -> bool:
    for index in range(1, attempts + 1):
        code, output = pmd3.run(["usbmux", "list"], timeout=20)
        if code == 0 and device_seen(output, udid):
            log(f"Da thay device {udid}.")
            return True

        ios_devices = list_go_ios_devices()
        if udid in ios_devices:
            log(f"Da thay device {udid} qua go-ios.")
            return True

        log(f"Chua thay device {udid} ({index}/{attempts}). Hay mo khoa may va bam Trust neu co.")
        if index < attempts:
            time.sleep(2)
    return False


def wait_for_any_devices(pmd3: Pymobiledevice3, attempts: int) -> list[str]:
    for index in range(1, attempts + 1):
        code, output = pmd3.run(["usbmux", "list", "--simple"], timeout=20)
        devices = extract_device_udids(output) if code == 0 else []
        if not devices:
            devices = list_go_ios_devices()
        if devices:
            log(f"Da thay {len(devices)} device: {', '.join(devices)}")
            return devices

        log(f"Chua thay device nao ({index}/{attempts}). Hay mo khoa may va bam Trust neu co.")
        if index < attempts:
            time.sleep(2)
    return []


def list_go_ios_devices() -> list[str]:
    ios_command = find_go_ios()
    if not ios_command:
        return []

    for command in ([*ios_command, "list", "--details"], [*ios_command, "list"]):
        code, output = run_command(command, timeout=20)
        if code != 0:
            continue
        devices = extract_device_udids(output)
        if devices:
            return devices
    return []


def looks_like_trollstore_record(source: str, metadata: dict[str, Any] | None) -> bool:
    app = metadata or {}
    text = f"{source} {compact_json_text(app)}".lower()
    application_type = str(app.get("ApplicationType", "")).lower()
    install_path = str(app.get("Path", "")).lower()
    is_registered_system_app = application_type == "system" and "/containers/bundle/application/" in install_path
    return "trollstore" in text or "troll" in text or is_registered_system_app


def add_candidate(
    candidates: list[BundleCandidate],
    bundle_id: Any,
    source: str,
    *,
    metadata: dict[str, Any] | None = None,
    verified: bool = False,
    prefer_standalone: bool = False,
) -> None:
    if not is_valid_bundle_id(bundle_id):
        return
    bundle = str(bundle_id).strip().strip("'\"")
    candidates.append(
        BundleCandidate(
            bundle_id=bundle,
            source=source,
            metadata=metadata or {},
            verified=verified,
            prefer_standalone=prefer_standalone,
        )
    )


def find_bundle_id_in_dict(value: dict[str, Any]) -> str | None:
    for key in APP_BUNDLE_KEYS:
        candidate = value.get(key)
        if is_valid_bundle_id(candidate):
            return str(candidate).strip().strip("'\"")
    return None


def bundle_candidates_from_json(value: Any, source: str, *, verified: bool) -> list[BundleCandidate]:
    candidates: list[BundleCandidate] = []

    def walk(item: Any, parent_key: str | None = None) -> None:
        if isinstance(item, dict):
            bundle_from_dict = find_bundle_id_in_dict(item)
            if bundle_from_dict:
                add_candidate(
                    candidates,
                    bundle_from_dict,
                    source,
                    metadata=item,
                    verified=verified,
                    prefer_standalone=looks_like_trollstore_record(source, item),
                )
            if parent_key and is_valid_bundle_id(parent_key):
                add_candidate(
                    candidates,
                    parent_key,
                    source,
                    metadata=item,
                    verified=verified,
                    prefer_standalone=looks_like_trollstore_record(source, item),
                )
            for key, child in item.items():
                if is_valid_bundle_id(key):
                    metadata = child if isinstance(child, dict) else {}
                    add_candidate(
                        candidates,
                        key,
                        source,
                        metadata=metadata,
                        verified=verified,
                        prefer_standalone=looks_like_trollstore_record(source, metadata),
                    )
                walk(child, key)
        elif isinstance(item, list):
            for child in item:
                walk(child, parent_key)
        elif isinstance(item, str):
            for hit in BUNDLE_ID_FIND_RE.findall(item):
                add_candidate(candidates, hit, source, verified=verified)

    walk(value)
    return candidates


def ipa_search_roots() -> list[Path]:
    roots = [
        Path.cwd(),
        app_dir(),
        app_dir().parent,
    ]
    return list(dict.fromkeys(path.resolve() for path in roots if path.exists()))


def discover_ipa_paths(args: argparse.Namespace) -> list[Path]:
    paths: list[Path] = []
    for raw_path in args.ipa:
        path = Path(raw_path).expanduser()
        if path.exists() and path.is_file():
            paths.append(path.resolve())

    for root in ipa_search_roots():
        for name in ("solumate-trollstore.ipa", "solumate.ipa", "WebDriverAgentRunner-Runner.ipa"):
            path = root / name
            if path.exists() and path.is_file():
                paths.append(path.resolve())
        paths.extend(path.resolve() for path in sorted(root.glob("*.ipa")) if path.is_file())

    deduped: list[Path] = []
    seen: set[Path] = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        deduped.append(path)
    return deduped[:30]


def local_ipa_candidates(args: argparse.Namespace) -> list[BundleCandidate]:
    candidates: list[BundleCandidate] = []
    for ipa_path in discover_ipa_paths(args):
        try:
            with zipfile.ZipFile(ipa_path) as archive:
                plist_names = [
                    name
                    for name in archive.namelist()
                    if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
                ]
                for plist_name in plist_names:
                    info = plistlib.loads(archive.read(plist_name))
                    bundle_id = info.get("CFBundleIdentifier")
                    source = f"local_ipa:{ipa_path.name}"
                    add_candidate(
                        candidates,
                        bundle_id,
                        source,
                        metadata={
                            "ipa": str(ipa_path),
                            "plist": plist_name,
                            "CFBundleDisplayName": info.get("CFBundleDisplayName"),
                            "CFBundleName": info.get("CFBundleName"),
                            "CFBundleExecutable": info.get("CFBundleExecutable"),
                            "CFBundleIdentifier": bundle_id,
                        },
                        verified=False,
                        prefer_standalone="trollstore" in ipa_path.name.lower(),
                    )
        except Exception as exc:
            log(f"Bo qua IPA khong doc duoc {ipa_path}: {type(exc).__name__}: {exc}")
    return candidates


def configured_candidates(args: argparse.Namespace) -> list[BundleCandidate]:
    candidates: list[BundleCandidate] = []
    values: list[str] = []
    values.extend(split_bundle_values(args.bundle_id))
    for item in args.candidate_bundle_id:
        values.extend(split_bundle_values(item))
    for env_key in CONFIGURED_BUNDLE_ENV_KEYS:
        values.extend(split_bundle_values(os.environ.get(env_key)))
    values.extend(DEFAULT_BUNDLE_IDS)

    for bundle_id in unique_preserve_order(values):
        trollstore_bundle_id = os.environ.get("DEFAULT_TROLLSTORE_BUNDLE_ID")
        add_candidate(
            candidates,
            bundle_id,
            "configured",
            verified=False,
            prefer_standalone=bool(trollstore_bundle_id) and bundle_id == trollstore_bundle_id,
        )
    return candidates


def preferred_bundle_order(args: argparse.Namespace, ipa_candidates: list[BundleCandidate]) -> list[str]:
    values: list[str] = []
    values.extend(split_bundle_values(args.bundle_id))
    for item in args.candidate_bundle_id:
        values.extend(split_bundle_values(item))
    for env_key in CONFIGURED_BUNDLE_ENV_KEYS:
        values.extend(split_bundle_values(os.environ.get(env_key)))
    values.extend(candidate.bundle_id for candidate in ipa_candidates)
    values.extend(DEFAULT_BUNDLE_IDS)
    return unique_preserve_order([value for value in values if is_valid_bundle_id(value)])


def explicit_bundle_order(args: argparse.Namespace) -> list[str]:
    values = split_bundle_values(args.bundle_id)
    for item in args.candidate_bundle_id:
        values.extend(split_bundle_values(item))
    return unique_preserve_order([value for value in values if is_valid_bundle_id(value)])


def score_candidate(candidate: BundleCandidate, preferred: list[str], explicit: list[str]) -> int:
    bundle = candidate.bundle_id
    lower_bundle = bundle.lower()
    text = f"{candidate.source} {compact_json_text(candidate.metadata)}".lower()
    score = 0

    if bundle in explicit:
        score += 20000 - explicit.index(bundle) * 100
    if bundle in preferred:
        score += 5000 - preferred.index(bundle) * 20
    if candidate.verified:
        score += 700
        executable = str(candidate.metadata.get("CFBundleExecutable", "")).lower()
        display_name = str(candidate.metadata.get("CFBundleDisplayName", "")).lower()
        if "webdriveragentrunner" in executable or display_name == "solumateios":
            score += 10000
    if "local_ipa" in candidate.source:
        score += 300
    if "apps_query" in candidate.source or "install_proxy" in candidate.source:
        score += 250
    if "dvt_applist" in candidate.source:
        score += 200
    if candidate.prefer_standalone:
        score += 350
    if bundle == "solumate.driver.automation":
        score += 1000
    if "solumate" in lower_bundle or "solumate" in text:
        score += 700
    if "webdriveragent" in lower_bundle or "webdriveragent" in text:
        score += 700
    if "webdriveragentrunner-runner" in text:
        score += 500
    if lower_bundle.endswith(".xctrunner"):
        score += 150
    if lower_bundle.startswith("com.apple."):
        score -= 3000
    if lower_bundle.endswith(LOW_PRIORITY_SUFFIXES):
        score -= 1200

    return score


def merge_candidates(
    candidates: list[BundleCandidate],
    preferred: list[str],
    explicit: list[str],
) -> list[BundleCandidate]:
    merged: dict[str, BundleCandidate] = {}
    for candidate in candidates:
        if not is_valid_bundle_id(candidate.bundle_id):
            continue
        current = merged.get(candidate.bundle_id)
        if current is None:
            merged[candidate.bundle_id] = candidate
            continue
        current.verified = current.verified or candidate.verified
        current.prefer_standalone = current.prefer_standalone or candidate.prefer_standalone
        current.metadata.update({key: value for key, value in candidate.metadata.items() if value is not None})
        current_sources = {source.strip() for source in current.source.split(",") if source.strip()}
        for source in candidate.source.split(","):
            source = source.strip()
            if source and source not in current_sources:
                current.source += f",{source}"
                current_sources.add(source)

    for candidate in merged.values():
        candidate.score = score_candidate(candidate, preferred, explicit)

    return sorted(
        merged.values(),
        key=lambda item: (item.score, item.verified, item.bundle_id in preferred),
        reverse=True,
    )


def is_wda_candidate(candidate: BundleCandidate, explicit: list[str]) -> bool:
    if candidate.bundle_id in explicit:
        return True
    bundle = candidate.bundle_id.lower()
    metadata = candidate.metadata
    app_text = " ".join(
        str(metadata.get(key, ""))
        for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleExecutable")
    ).lower()
    return any(marker in bundle or marker in app_text for marker in ("solumate", "webdriveragent"))

def should_prefer_xctest(candidate: BundleCandidate) -> bool:
    bundle = candidate.bundle_id.lower()
    metadata = candidate.metadata
    app_text = " ".join(
        str(metadata.get(key, ""))
        for key in ("CFBundleDisplayName", "CFBundleName", "CFBundleExecutable", "Path")
    ).lower()
    return any(marker in bundle or marker in app_text for marker in ("solumate", "webdriveragent"))


def discover_device_candidates(pmd3: Pymobiledevice3, args: argparse.Namespace, udid: str) -> list[BundleCandidate]:
    ipa_candidates = local_ipa_candidates(args)
    preferred = preferred_bundle_order(args, ipa_candidates)
    explicit = explicit_bundle_order(args)
    candidates: list[BundleCandidate] = []
    candidates.extend(configured_candidates(args))
    candidates.extend(ipa_candidates)

    if args.no_discovery:
        return [
            candidate
            for candidate in merge_candidates(candidates, preferred, explicit)
            if is_wda_candidate(candidate, explicit)
        ]

    if pmd3.available():
        commands = [
            (
                "install_proxy_apps_list",
                ["apps", "list", *pmd3_device_args(args, udid), "--type", "Any", "--show-placeholders"],
            ),
            ("dvt_applist", ["developer", "dvt", "applist", *pmd3_device_args(args, udid)]),
        ]
        for source, command in commands:
            code, output = pmd3.run(command, timeout=args.discovery_timeout, echo_output=False)
            if code != 0:
                log(f"Khong doc duoc danh sach app qua {source}; tiep tuc fallback.")
                continue
            parsed = parse_first_json(output)
            if parsed is None:
                continue
            candidates.extend(bundle_candidates_from_json(parsed, source, verified=True))

        if preferred:
            code, output = pmd3.run(
                ["apps", "query", *pmd3_device_args(args, udid), *preferred],
                timeout=args.discovery_timeout,
                echo_output=False,
            )
            if code == 0:
                parsed = parse_first_json(output)
                if parsed is not None:
                    candidates.extend(bundle_candidates_from_json(parsed, "apps_query", verified=True))
            else:
                log("apps query khong thanh cong; tiep tuc fallback bundle id da biet.")

    else:
        log("Khong co pymobiledevice3; dung go-ios/local IPA/env de fallback.")

    candidates.extend(discover_go_ios_app_candidates(args, udid))

    ranked = [
        candidate
        for candidate in merge_candidates(candidates, preferred, explicit)
        if is_wda_candidate(candidate, explicit)
    ]
    if ranked:
        shown = ", ".join(f"{item.bundle_id}({item.source}, score={item.score})" for item in ranked[: args.max_candidates])
        log(f"Bundle candidates: {shown}")
    return ranked


def discover_go_ios_app_candidates(args: argparse.Namespace, udid: str) -> list[BundleCandidate]:
    ios_command = find_go_ios()
    if not ios_command:
        return []

    result: list[BundleCandidate] = []
    commands = [
        ("go_ios_apps_all", [*ios_command, f"--udid={udid}", "apps", "--all"]),
        ("go_ios_apps_list", [*ios_command, f"--udid={udid}", "apps", "--list", "--all"]),
    ]
    for source, command in commands:
        code, output = run_command(command, timeout=args.discovery_timeout, echo_output=False)
        if code != 0:
            continue
        parsed = parse_first_json(output)
        if parsed is not None:
            result.extend(bundle_candidates_from_json(parsed, source, verified=True))
        else:
            for hit in BUNDLE_ID_FIND_RE.findall(output):
                add_candidate(result, hit, source, verified=True)
    return result


def prefixed_envs(prefixes: tuple[str, ...]) -> dict[str, str]:
    result: dict[str, str] = {}
    for key in sorted(os.environ):
        if any(key.startswith(prefix) for prefix in prefixes):
            result[key] = os.environ[key]
    return result


def build_wda_env(args: argparse.Namespace, bundle_id: str) -> dict[str, str]:
    env: dict[str, str] = {
        "WDA_PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "USE_PORT": str(args.port),
        "MJPEG_SERVER_PORT": str(args.mjpeg_port),
        "H264_SERVER_PORT": str(args.h264_port),
        "WDA_REALTIME_CONTROL_ENABLED": "1",
        "WDA_REALTIME_CONTROL_PORT": str(args.realtime_control_port),
        "MJPEG_SCALING_FACTOR": str(args.mjpeg_scale),
        "MJPEG_SERVER_SCREENSHOT_QUALITY": str(args.mjpeg_quality),
        "MJPEG_SERVER_FRAMERATE": str(args.mjpeg_framerate),
        "MJPEG_FIX_ORIENTATION": str(args.mjpeg_fix_orientation).lower(),
        "MJPEG_FRAME_TIMEOUT": str(args.mjpeg_frame_timeout),
    }

    optional_from_env = {
        "WDA_STARTUP_PASSWORD": os.environ.get("WDA_STARTUP_PASSWORD"),
        "WDA_AUTH_TOKEN": os.environ.get("WDA_AUTH_TOKEN") or os.environ.get("WEBDRIVERAGENT_AUTH_TOKEN"),
        "SOLUMATE_WDA_ENABLE_POINT_ARRAY": os.environ.get("SOLUMATE_WDA_ENABLE_POINT_ARRAY"),
        "SOLUMATE_WDA_SWIPE_SECRET": os.environ.get("SOLUMATE_WDA_SWIPE_SECRET"),
        "SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY": os.environ.get("SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY"),
    }
    for key, value in optional_from_env.items():
        if value:
            env[key] = value

    env.update(prefixed_envs(("WDA_IOHID_", "WDA_REALTIME_TOUCH_")))
    return env


def append_pmd3_env_args(command: list[str], env: dict[str, str]) -> None:
    for key, value in env.items():
        command.extend(["--env", f"{key}={value}"])


def append_go_ios_env_args(command: list[str], env: dict[str, str]) -> None:
    for key, value in env.items():
        command.append(f"--env={key}={value}")


def run_xctest_candidate(
    pmd3: Pymobiledevice3,
    args: argparse.Namespace,
    udid: str,
    candidate: BundleCandidate,
) -> tuple[bool, int]:
    bundle_id = candidate.bundle_id
    log(f"Thu kich XCTest cho {bundle_id} ({candidate.source}).")
    env = build_wda_env(args, bundle_id)
    start_args = [
        "developer",
        "dvt",
        "xcuitest",
        *pmd3_device_args(args, udid),
    ]
    append_pmd3_env_args(start_args, env)
    start_args.append(bundle_id)

    kick_timeout = min(args.timeout, args.command_timeout)
    code, output, started = pmd3.run_until(
        start_args,
        success_predicate=looks_xctest_started,
        timeout=kick_timeout,
        post_match_grace=args.post_start_grace,
    )
    if started:
        log(f"XCTest/WDA da duoc kich hoat bang bundle id {bundle_id}.")
        return True, 0

    lower = output.lower()
    if "no app with bundle id" in lower or "appnotinstallederror" in lower or "not installed" in lower:
        log("Install proxy khong thay app nay; se thu nhanh standalone/manual-launch neu duoc.")
    else:
        log("Da goi lenh kich XCTest nhung chua thay log XCTest bat dau.")

    go_ok, go_code = run_go_ios_runwda(args, udid, bundle_id, env)
    if go_ok:
        return True, 0
    return False, code if code != 127 else go_code


def run_go_ios_runwda(
    args: argparse.Namespace,
    udid: str,
    bundle_id: str,
    env: dict[str, str],
) -> tuple[bool, int]:
    ios_command = find_go_ios()
    if not ios_command:
        return False, 127

    command = [
        *ios_command,
        f"--udid={udid}",
        "runwda",
        f"--bundleid={bundle_id}",
        f"--testrunnerbundleid={bundle_id}",
        f"--xctestconfig={args.xctestconfig}",
        "--log-output=-",
    ]
    append_go_ios_env_args(command, env)
    log(f"Thu go-ios runwda cho {bundle_id}.")
    code, output, started = run_command_until(
        command,
        success_predicate=looks_xctest_started,
        timeout=min(args.timeout, args.command_timeout),
        post_match_grace=args.post_start_grace,
    )
    if started:
        log(f"go-ios runwda da kich WDA bang bundle id {bundle_id}.")
        return True, 0
    return False, code or 4


def run_pmd3_standalone_launch(
    pmd3: Pymobiledevice3,
    args: argparse.Namespace,
    udid: str,
    bundle_id: str,
    env: dict[str, str],
) -> tuple[bool, int]:
    if not pmd3.available():
        return False, 127

    command = ["developer", "dvt", "launch", *pmd3_device_args(args, udid)]
    append_pmd3_env_args(command, env)
    command.append(bundle_id)
    log(f"Thu standalone launch qua pmd3 dvt launch cho {bundle_id}.")
    code, output = pmd3.run(command, timeout=args.standalone_timeout)
    if code == 0:
        log("Standalone launch thanh cong qua pmd3 dvt launch.")
        return True, 0
    if output.strip():
        log("pmd3 dvt launch chua launch duoc; tiep tuc fallback.")
    return False, code or 4


def run_go_ios_standalone_launch(
    args: argparse.Namespace,
    udid: str,
    bundle_id: str,
    env: dict[str, str],
) -> tuple[bool, int]:
    ios_command = find_go_ios()
    if not ios_command:
        return False, 127

    command = [*ios_command, f"--udid={udid}", "launch", bundle_id, "--kill-existing"]
    append_go_ios_env_args(command, env)
    log(f"Thu standalone launch qua go-ios cho {bundle_id}.")
    code, _ = run_command(command, timeout=args.standalone_timeout)
    if code == 0:
        log("Standalone launch thanh cong qua go-ios.")
        return True, 0
    return False, code or 4


def run_standalone_candidate(
    pmd3: Pymobiledevice3,
    args: argparse.Namespace,
    udid: str,
    candidate: BundleCandidate,
) -> tuple[bool, int]:
    bundle_id = candidate.bundle_id
    env = build_wda_env(args, bundle_id)
    ok, code = run_pmd3_standalone_launch(pmd3, args, udid, bundle_id, env)
    if ok:
        return True, 0
    ok, go_ios_code = run_go_ios_standalone_launch(args, udid, bundle_id, env)
    if ok:
        return True, 0
    return False, code if code != 127 else go_ios_code


def method_order(args: argparse.Namespace, candidate: BundleCandidate) -> list[str]:
    if args.launch_mode == "xctest":
        return ["xctest"]
    if args.launch_mode == "standalone":
        return ["standalone"]
    if should_prefer_xctest(candidate):
        return ["xctest", "standalone"]
    if candidate.prefer_standalone or not candidate.verified:
        return ["standalone", "xctest"]
    return ["xctest", "standalone"]


def mount_developer_image(pmd3: Pymobiledevice3, args: argparse.Namespace, udid: str) -> int:
    if args.no_mount:
        return 0

    if pmd3.available():
        code, output = pmd3.run(
            ["mounter", "auto-mount", *pmd3_device_args(args, udid)],
            timeout=args.mount_timeout,
        )
        if code == 0 or "already mounted" in output.lower():
            return 0

    ios_command = find_go_ios()
    if ios_command:
        code, _ = run_command([*ios_command, f"--udid={udid}", "image", "auto"], timeout=args.mount_timeout)
        if code == 0:
            return 0

    log("Mount DeveloperDiskImage that bai.")
    return 3


def activate_one_device(pmd3: Pymobiledevice3, args: argparse.Namespace, udid: str) -> int:
    log("")
    log(f"=== Device {udid} ===")
    if not wait_for_device(pmd3, udid, args.wait_device_attempts):
        log("Khong thay device qua usbmux. Rut/cam lai cap roi chay lai lenh.")
        return 2

    mount_code = mount_developer_image(pmd3, args, udid)
    if mount_code != 0:
        return mount_code

    candidates = discover_device_candidates(pmd3, args, udid)
    if not candidates:
        log("Khong co bundle id ung vien nao de chay WDA.")
        return 5

    last_code = 4
    tried: set[tuple[str, str]] = set()
    for candidate in candidates[: args.max_candidates]:
        for method in method_order(args, candidate):
            key = (method, candidate.bundle_id)
            if key in tried:
                continue
            tried.add(key)
            if method == "xctest":
                ok, code = run_xctest_candidate(pmd3, args, udid, candidate)
            else:
                ok, code = run_standalone_candidate(pmd3, args, udid, candidate)
            if ok:
                return 0
            last_code = code or last_code

    log("Da thu cac bundle/method ung vien nhung chua auto run duoc WDA.")
    log("Neu device vua mat ket noi, cam lai cap/mo khoa may roi chay lai exe.")
    return last_code


def resolve_target_udids(pmd3: Pymobiledevice3, args: argparse.Namespace) -> list[str]:
    if args.udid and not args.all_devices:
        return [args.udid]
    return wait_for_any_devices(pmd3, args.wait_device_attempts)


def activate_xctest(args: argparse.Namespace) -> int:
    pmd3 = Pymobiledevice3(prefer_external=args.external_pmd3)
    udids = resolve_target_udids(pmd3, args)
    if not udids:
        log("Khong thay device nao qua usbmux. Rut/cam lai cap, unlock device va bam Trust neu co.")
        return 2

    results: dict[str, int] = {}
    for udid in udids:
        results[udid] = activate_one_device(pmd3, args, udid)

    failed = {udid: code for udid, code in results.items() if code != 0}
    if failed:
        log("")
        log("Ket qua:")
        for udid, code in results.items():
            status = "OK" if code == 0 else f"FAIL({code})"
            log(f"- {udid}: {status}")
        return next(iter(failed.values())) or 4

    log("")
    log("Tat ca device da duoc auto run/kich WDA thanh cong.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Auto run/kich hoat XCTest/WDA theo UDID va bundleId, ho tro app cai thuong va TrollStore."
    )
    parser.add_argument("udid", nargs="?", help="UDID cua iPhone/iPad. Bo trong de chay tat ca device dang cam.")
    parser.add_argument("bundle_id", nargs="?", help="Bundle id cua XCUITest runner/WDA runner neu da biet.")
    parser.add_argument("--udid", dest="udid_option", help="UDID cua iPhone/iPad, uu tien hon positional.")
    parser.add_argument("--bundle-id", dest="bundle_id_option", help="Bundle id WDA, uu tien hon positional.")
    parser.add_argument(
        "--candidate-bundle-id",
        action="append",
        default=[],
        help="Them bundle id ung vien. Co the lap lai hoac cach nhau bang dau phay.",
    )
    parser.add_argument(
        "--ipa",
        action="append",
        default=[],
        help="Doc CFBundleIdentifier tu IPA local de fallback khi app TrollStore khong hien trong list app.",
    )
    parser.add_argument(
        "--launch-mode",
        choices=("auto", "xctest", "standalone"),
        default="auto",
        help="auto uu tien XCTest cho Solumate WDA; standalone chi nen dung khi test manual/icon launch.",
    )
    parser.add_argument("--all-devices", action="store_true", help="Chay tren tat ca device dang ket noi.")
    parser.add_argument("--port", type=int, default=DEFAULT_WDA_PORT, help="Port WDA tren device.")
    parser.add_argument("--mjpeg-port", type=int, default=DEFAULT_MJPEG_PORT, help="Port MJPEG tren device.")
    parser.add_argument("--h264-port", type=int, default=DEFAULT_H264_PORT, help="Port H264 tren device; -1 de tat.")
    parser.add_argument(
        "--realtime-control-port",
        type=int,
        default=DEFAULT_REALTIME_CONTROL_PORT,
        help="Port realtime-control tren device.",
    )
    parser.add_argument("--mjpeg-scale", type=int, default=DEFAULT_MJPEG_SCALE, help="MJPEG_SCALING_FACTOR.")
    parser.add_argument("--mjpeg-quality", type=int, default=DEFAULT_MJPEG_QUALITY, help="MJPEG quality.")
    parser.add_argument("--mjpeg-framerate", type=int, default=DEFAULT_MJPEG_FRAMERATE, help="MJPEG framerate.")
    parser.add_argument("--mjpeg-fix-orientation", default=os.environ.get("MJPEG_FIX_ORIENTATION", "true"))
    parser.add_argument("--mjpeg-frame-timeout", default=os.environ.get("MJPEG_FRAME_TIMEOUT", "0.45"))
    parser.add_argument("--xctestconfig", default=DEFAULT_XCTESTCONFIG, help="XCTest config name cho go-ios runwda.")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="So giay doi log XCTest/WDA bat dau.")
    parser.add_argument("--command-timeout", type=float, default=180.0, help="Timeout tong cho process pmd3.")
    parser.add_argument("--mount-timeout", type=float, default=180.0, help="Timeout mount DeveloperDiskImage.")
    parser.add_argument("--discovery-timeout", type=float, default=35.0, help="Timeout moi lenh quet app.")
    parser.add_argument("--standalone-timeout", type=float, default=45.0, help="Timeout launch standalone.")
    parser.add_argument("--post-start-grace", type=float, default=1.0, help="Doi them vai giay sau khi thay start.")
    parser.add_argument("--wait-device-attempts", type=int, default=3, help="So lan doi device trong usbmux.")
    parser.add_argument("--max-candidates", type=int, default=8, help="So bundle id ung vien toi da se thu.")
    parser.add_argument("--userspace", action="store_true", help="Ep dung userspace tunnel cua pymobiledevice3.")
    parser.add_argument("--no-mount", action="store_true", help="Bo qua mounter auto-mount.")
    parser.add_argument("--no-discovery", action="store_true", help="Khong quet app tren device; chi dung input/env/IPA.")
    parser.add_argument(
        "--external-pmd3",
        action="store_true",
        help="Khong dung pymobiledevice3 bundled trong exe; uu tien CLI ben ngoai.",
    )
    return parser


def normalize_args(args: argparse.Namespace) -> argparse.Namespace:
    if args.udid_option:
        args.udid = args.udid_option
    if args.bundle_id_option:
        args.bundle_id = args.bundle_id_option

    # Backward-friendly shortcut: allow `xctest_kicker.py solumate.driver.automation`.
    if args.bundle_id is None and args.udid and "." in args.udid and not is_probable_udid(args.udid):
        args.bundle_id = args.udid
        args.udid = None

    if args.max_candidates < 1:
        args.max_candidates = 1
    return args


def main(argv: list[str] | None = None) -> int:
    args_list = list(sys.argv[1:] if argv is None else argv)
    if args_list and args_list[0] == INTERNAL_PMD3_SENTINEL:
        return run_internal_pmd3(args_list[1:])

    parser = build_parser()
    args = normalize_args(parser.parse_args(args_list))
    return activate_xctest(args)


if __name__ == "__main__":
    raise SystemExit(main())
