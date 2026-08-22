#!/usr/bin/env python3
"""Health checks and transactional recovery for an AmneziaWG WARP tunnel."""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence


LOG = logging.getLogger("awg-warp-guardian")
DEFAULT_CONFIG_FILE = Path("/etc/awg-warp-guardian/guardian.env")


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse a small KEY=VALUE file without executing shell code."""
    values: dict[str, str] = {}
    if not path.exists():
        raise FileNotFoundError(f"configuration file does not exist: {path}")
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, encoded = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValueError(f"{path}:{number}: invalid key {key!r}")
        try:
            parts = shlex.split(encoded, comments=True, posix=True)
        except ValueError as exc:
            raise ValueError(f"{path}:{number}: {exc}") from exc
        values[key] = " ".join(parts)
    return values


def env_bool(values: Mapping[str, str], key: str, default: bool) -> bool:
    raw = values.get(key, "1" if default else "0").strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{key} must be true/false or 1/0")


def env_int(
    values: Mapping[str, str], key: str, default: int, minimum: int = 0
) -> int:
    try:
        parsed = int(values.get(key, str(default)))
    except ValueError as exc:
        raise ValueError(f"{key} must be an integer") from exc
    if parsed < minimum:
        raise ValueError(f"{key} must be >= {minimum}")
    return parsed


def https_base_url(value: str, key: str) -> str:
    normalized = value.rstrip("/")
    parsed = urlsplit(normalized)
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError(f"{key} contains an invalid port") from exc
    if (
        not re.fullmatch(
            r"https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?"
            r"(?:/[A-Za-z0-9._~/-]+)*",
            normalized,
        )
        or parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or (port is not None and not 1 <= port <= 65535)
    ):
        raise ValueError(
            f"{key} must be an HTTPS base URL without credentials, query, or fragment"
        )
    return normalized


@dataclass(frozen=True)
class Settings:
    interface: str
    config_path: Path
    service: str
    check_urls: tuple[str, ...]
    check_quorum: int
    trace_url: str
    require_warp: bool
    bind_to_interface: bool
    curl_timeout: int
    max_handshake_age: int
    failures_before_repair: int
    repair_wait: int
    rotation_cooldown: int
    max_rotations_per_day: int
    backups_keep: int
    generator_path: Path
    generator_timeout: int
    generator_site_url: str
    generator_data_urls: tuple[str, ...]
    generator_https_proxy: str
    exclude_lan: bool
    awg_variant: int
    dns_preset: str
    server_preset: str
    ipv6: bool
    keepalive: int
    candidate_attempts: int
    allow_hard_restart: bool
    state_dir: Path
    awg_command: str = "awg"
    awg_quick_command: str = "awg-quick"
    curl_command: str = "curl"
    systemctl_command: str = "systemctl"
    ip_command: str = "ip"

    @classmethod
    def from_file(cls, path: Path) -> "Settings":
        values = parse_env_file(path)
        interface = values.get("INTERFACE", "awg-warp")
        if not re.fullmatch(r"[A-Za-z0-9_=+.-]{1,15}", interface):
            raise ValueError("INTERFACE is not a valid Linux interface name")
        config_path = Path(
            values.get(
                "CONFIG_PATH", f"/etc/amnezia/amneziawg/{interface}.conf"
            )
        )
        urls = tuple(shlex.split(values.get("CHECK_URLS", "")))
        if not urls:
            raise ValueError("CHECK_URLS must contain at least one URL")
        for url in urls:
            if not re.match(r"^https?://", url):
                raise ValueError(f"unsupported health-check URL: {url}")
        quorum = env_int(values, "CHECK_QUORUM", min(2, len(urls)), 1)
        if quorum > len(urls):
            raise ValueError("CHECK_QUORUM cannot exceed the number of CHECK_URLS")
        data_urls = tuple(shlex.split(values.get("GENERATOR_DATA_URLS", "")))
        for data_url in data_urls:
            https_base_url(data_url, "GENERATOR_DATA_URLS")
        awg_variant = env_int(values, "WARP_AWG_VARIANT", 1, 1)
        if awg_variant > 3:
            raise ValueError("WARP_AWG_VARIANT must be 1, 2, or 3")
        dns_preset = values.get("WARP_DNS_PRESET", "cf")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", dns_preset):
            raise ValueError("WARP_DNS_PRESET is invalid")
        server_preset = values.get("WARP_SERVER_PRESET", "def")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", server_preset):
            raise ValueError("WARP_SERVER_PRESET is invalid")
        keepalive = env_int(values, "WARP_KEEPALIVE", 0, 0)
        if keepalive > 65535:
            raise ValueError("WARP_KEEPALIVE must be between 0 and 65535")
        candidate_attempts = env_int(values, "CANDIDATE_ATTEMPTS", 10, 1)
        if candidate_attempts > 20:
            raise ValueError("CANDIDATE_ATTEMPTS must be between 1 and 20")
        return cls(
            interface=interface,
            config_path=config_path,
            service=values.get(
                "SERVICE", f"awg-quick@{interface}.service"
            ),
            check_urls=urls,
            check_quorum=quorum,
            trace_url=values.get(
                "WARP_TRACE_URL",
                "https://www.cloudflare.com/cdn-cgi/trace",
            ),
            require_warp=env_bool(values, "REQUIRE_WARP", True),
            bind_to_interface=env_bool(values, "BIND_TO_INTERFACE", True),
            curl_timeout=env_int(values, "CURL_TIMEOUT", 12, 1),
            max_handshake_age=env_int(values, "MAX_HANDSHAKE_AGE", 300, 1),
            failures_before_repair=env_int(
                values, "FAILURES_BEFORE_REPAIR", 3, 1
            ),
            repair_wait=env_int(values, "REPAIR_WAIT", 12, 0),
            rotation_cooldown=env_int(values, "ROTATION_COOLDOWN", 1800, 0),
            max_rotations_per_day=env_int(
                values, "MAX_ROTATIONS_PER_DAY", 4, 1
            ),
            backups_keep=env_int(values, "BACKUPS_KEEP", 10, 1),
            generator_path=Path(
                values.get(
                    "GENERATOR_PATH",
                    "/usr/local/lib/awg-warp-guardian/generate-warp-config",
                )
            ),
            generator_timeout=env_int(values, "GENERATOR_TIMEOUT", 90, 5),
            generator_site_url=https_base_url(
                values.get(
                    "GENERATOR_SITE_URL",
                    "https://warp-gen.github.io",
                ),
                "GENERATOR_SITE_URL",
            ),
            generator_data_urls=data_urls,
            generator_https_proxy=values.get("GENERATOR_HTTPS_PROXY", ""),
            exclude_lan=env_bool(values, "EXCLUDE_LAN", True),
            awg_variant=awg_variant,
            dns_preset=dns_preset,
            server_preset=server_preset,
            ipv6=env_bool(values, "WARP_IPV6", True),
            keepalive=keepalive,
            candidate_attempts=candidate_attempts,
            allow_hard_restart=env_bool(values, "ALLOW_HARD_RESTART", True),
            state_dir=Path(
                values.get("STATE_DIR", "/var/lib/awg-warp-guardian")
            ),
            awg_command=values.get("AWG_COMMAND", "awg"),
            awg_quick_command=values.get("AWG_QUICK_COMMAND", "awg-quick"),
            curl_command=values.get("CURL_COMMAND", "curl"),
            systemctl_command=values.get("SYSTEMCTL_COMMAND", "systemctl"),
            ip_command=values.get("IP_COMMAND", "ip"),
        )


@dataclass
class Health:
    healthy: bool
    service_active: bool
    interface_up: bool
    sites_ok: int
    sites_total: int
    warp_on: bool
    handshake_age: int | None
    errors: list[str] = field(default_factory=list)


@dataclass
class State:
    consecutive_failures: int = 0
    last_success: int = 0
    last_rotation_attempt: int = 0
    rotation_attempts: list[int] = field(default_factory=list)
    last_action: str = "never"

    @classmethod
    def load(cls, path: Path) -> "State":
        if not path.exists():
            return cls()
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            return cls(
                consecutive_failures=int(raw.get("consecutive_failures", 0)),
                last_success=int(raw.get("last_success", 0)),
                last_rotation_attempt=int(raw.get("last_rotation_attempt", 0)),
                rotation_attempts=[int(v) for v in raw.get("rotation_attempts", [])],
                last_action=str(raw.get("last_action", "unknown")),
            )
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            LOG.warning("Ignoring unreadable state file %s: %s", path, exc)
            return cls()

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_write(path, json.dumps(asdict(self), indent=2) + "\n", 0o600)


class Runner:
    def run(
        self,
        args: Sequence[str],
        *,
        input_text: str | None = None,
        timeout: int | None = None,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(args),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            env=dict(env) if env is not None else None,
        )


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def basic_validate_config(text: str) -> list[str]:
    required = {
        "[Interface]": r"(?mi)^\s*\[Interface\]\s*$",
        "PrivateKey": r"(?mi)^\s*PrivateKey\s*=\s*\S+",
        "Address": r"(?mi)^\s*Address\s*=\s*\S+",
        "[Peer]": r"(?mi)^\s*\[Peer\]\s*$",
        "PublicKey": r"(?mi)^\s*PublicKey\s*=\s*\S+",
        "AllowedIPs": r"(?mi)^\s*AllowedIPs\s*=\s*\S+",
        "Endpoint": r"(?mi)^\s*Endpoint\s*=\s*\S+",
    }
    return [name for name, pattern in required.items() if not re.search(pattern, text)]


class Guardian:
    def __init__(self, settings: Settings, runner: Runner | None = None) -> None:
        self.settings = settings
        self.runner = runner or Runner()
        self.state_path = settings.state_dir / "state.json"
        self.backup_dir = settings.state_dir / "backups"

    def command_ok(self, args: Sequence[str], timeout: int | None = None) -> bool:
        try:
            return self.runner.run(args, timeout=timeout).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def curl_args(self) -> list[str]:
        args = [
            self.settings.curl_command,
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            str(self.settings.curl_timeout),
            "--max-time",
            str(self.settings.curl_timeout),
        ]
        if self.settings.bind_to_interface:
            args += ["--interface", self.settings.interface]
        return args

    @staticmethod
    def curl_error(probe: subprocess.CompletedProcess[str]) -> str:
        detail = " ".join(probe.stderr.strip().split())
        if len(detail) > 180:
            detail = detail[:177] + "..."
        suffix = f": {detail}" if detail else ""
        return f"curl exit {probe.returncode}{suffix}"

    def health(self) -> Health:
        errors: list[str] = []
        LOG.info("Checking VPN health through interface %s", self.settings.interface)
        service_active = self.command_ok(
            [
                self.settings.systemctl_command,
                "is-active",
                "--quiet",
                self.settings.service,
            ]
        )
        if not service_active:
            errors.append("systemd service is not active")
        interface_up = self.command_ok(
            [self.settings.ip_command, "link", "show", "dev", self.settings.interface]
        )
        if not interface_up:
            errors.append("tunnel interface is missing")
        LOG.info(
            "Service=%s, interface=%s",
            "active" if service_active else "inactive",
            "present" if interface_up else "missing",
        )

        sites_ok = 0
        warp_on = not self.settings.require_warp
        site_results: list[
            tuple[str, subprocess.CompletedProcess[str] | None, str | None]
        ] = []
        trace_result: subprocess.CompletedProcess[str] | None = None
        trace_failure: str | None = None
        if interface_up:
            def curl_probe(
                url: str, discard_output: bool
            ) -> tuple[subprocess.CompletedProcess[str] | None, str | None]:
                args = self.curl_args()
                if discard_output:
                    args += ["--output", "/dev/null"]
                try:
                    return (
                        self.runner.run(
                            args + [url], timeout=self.settings.curl_timeout + 2
                        ),
                        None,
                    )
                except subprocess.TimeoutExpired:
                    return None, "timed out"
                except OSError as exc:
                    return None, str(exc)

            worker_count = min(
                8,
                len(self.settings.check_urls)
                + (1 if self.settings.require_warp else 0),
            )
            with ThreadPoolExecutor(max_workers=max(1, worker_count)) as executor:
                site_futures = [
                    (url, executor.submit(curl_probe, url, True))
                    for url in self.settings.check_urls
                ]
                trace_future = (
                    executor.submit(curl_probe, self.settings.trace_url, False)
                    if self.settings.require_warp
                    else None
                )
                site_results = [
                    (url, *future.result()) for url, future in site_futures
                ]
                if trace_future is not None:
                    trace_result, trace_failure = trace_future.result()

        for url, probe, failure in site_results:
            if probe is not None and probe.returncode == 0:
                sites_ok += 1
                LOG.info("Site probe passed: %s", url)
            elif probe is not None:
                errors.append(f"site probe failed: {url}")
                LOG.warning(
                    "Site probe failed: %s (%s)", url, self.curl_error(probe)
                )
            else:
                errors.append(f"site probe timed out: {url}")
                LOG.warning("Site probe failed: %s (%s)", url, failure or "error")
        if sites_ok < self.settings.check_quorum:
            errors.append(
                f"site quorum failed ({sites_ok}/{self.settings.check_quorum})"
            )

        if interface_up and self.settings.require_warp:
            warp_on = trace_result is not None and trace_result.returncode == 0 and bool(
                re.search(r"(?m)^warp=on\s*$", trace_result.stdout)
            )
            if not warp_on:
                errors.append("Cloudflare trace does not report warp=on")
                if trace_result is not None and trace_result.returncode != 0:
                    LOG.warning(
                        "Cloudflare trace failed (%s)",
                        self.curl_error(trace_result),
                    )
                elif trace_result is not None:
                    LOG.warning("Cloudflare trace response does not contain warp=on")
                elif trace_failure:
                    LOG.warning("Cloudflare trace failed (%s)", trace_failure)
            LOG.info("Cloudflare trace: warp=%s", "on" if warp_on else "off")

        handshake_age: int | None = None
        if interface_up:
            try:
                handshakes = self.runner.run(
                    [
                        self.settings.awg_command,
                        "show",
                        self.settings.interface,
                        "latest-handshakes",
                    ],
                    timeout=5,
                )
                epochs: list[int] = []
                if handshakes.returncode == 0:
                    for line in handshakes.stdout.splitlines():
                        fields = line.split()
                        if len(fields) >= 2 and fields[-1].isdigit():
                            epochs.append(int(fields[-1]))
                newest = max(epochs, default=0)
                if newest > 0:
                    handshake_age = max(0, int(time.time()) - newest)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if handshake_age is None or handshake_age > self.settings.max_handshake_age:
            errors.append("recent AmneziaWG handshake was not observed")
        if handshake_age is None:
            LOG.warning("AmneziaWG handshake: not observed")
        else:
            LOG.info("AmneziaWG handshake age: %ss", handshake_age)

        healthy = (
            service_active
            and interface_up
            and sites_ok >= self.settings.check_quorum
            and warp_on
            and handshake_age is not None
            and handshake_age <= self.settings.max_handshake_age
        )
        return Health(
            healthy=healthy,
            service_active=service_active,
            interface_up=interface_up,
            sites_ok=sites_ok,
            sites_total=len(self.settings.check_urls),
            warp_on=warp_on,
            handshake_age=handshake_age,
            errors=errors,
        )

    def wait_and_health(self) -> Health:
        if self.settings.repair_wait:
            time.sleep(self.settings.repair_wait)
        return self.health()

    def soft_reload(self, config: Path) -> bool:
        try:
            stripped = self.runner.run(
                [self.settings.awg_quick_command, "strip", str(config)], timeout=15
            )
            if stripped.returncode != 0 or not stripped.stdout.strip():
                return False
            applied = self.runner.run(
                [
                    self.settings.awg_command,
                    "syncconf",
                    self.settings.interface,
                    "/dev/stdin",
                ],
                input_text=stripped.stdout,
                timeout=15,
            )
            return applied.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def hard_restart(self) -> bool:
        if not self.settings.allow_hard_restart:
            LOG.warning("Hard restart is disabled")
            return False
        restarted = self.command_ok(
            [
                self.settings.systemctl_command,
                "restart",
                self.settings.service,
            ],
            timeout=45,
        )
        if restarted:
            return True
        # Killing a timed-out systemctl client does not cancel the start job
        # inside systemd. In particular, awg-quick may keep retrying DNS for
        # many minutes while Guardian is waiting to generate a replacement.
        # Explicitly stop the unit so the half-created interface and queued
        # start job cannot block the recovery sequence.
        LOG.error("Service restart failed or timed out; cancelling the start job")
        self.command_ok(
            [
                self.settings.systemctl_command,
                "stop",
                self.settings.service,
            ],
            timeout=15,
        )
        return False

    def validate_candidate(self, path: Path) -> None:
        text = path.read_text(encoding="utf-8")
        missing = basic_validate_config(text)
        if missing:
            raise ValueError("generated config misses: " + ", ".join(missing))
        if path.stat().st_size > 256 * 1024:
            raise ValueError("generated config is unexpectedly large")
        try:
            stripped = self.runner.run(
                [self.settings.awg_quick_command, "strip", str(path)], timeout=15
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValueError("awg-quick could not validate generated config") from exc
        if stripped.returncode != 0 or not stripped.stdout.strip():
            raise ValueError("awg-quick rejected generated config")

    def backup_current(self) -> Path | None:
        if not self.settings.config_path.exists():
            return None
        self.backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = self.backup_dir / f"{self.settings.interface}-{stamp}.conf"
        shutil.copy2(self.settings.config_path, backup)
        os.chmod(backup, 0o600)
        backups = sorted(
            self.backup_dir.glob(f"{self.settings.interface}-*.conf"),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        for old in backups[self.settings.backups_keep :]:
            old.unlink(missing_ok=True)
        return backup

    def may_rotate(
        self,
        state: State,
        force: bool = False,
        ignore_cooldown: bool = False,
    ) -> tuple[bool, str]:
        if force:
            return True, "forced"
        now = int(time.time())
        recent = [value for value in state.rotation_attempts if value > now - 86400]
        if len(recent) >= self.settings.max_rotations_per_day:
            return False, "daily rotation limit reached"
        if (
            not ignore_cooldown
            and now - state.last_rotation_attempt < self.settings.rotation_cooldown
        ):
            return False, "rotation cooldown is active"
        return True, "allowed"

    def generate_candidate(self, state: State) -> Path:
        self.settings.config_path.parent.mkdir(parents=True, exist_ok=True)
        candidate_dir = Path(
            tempfile.mkdtemp(
                prefix=".awg-guardian-candidate.",
                dir=self.settings.config_path.parent,
            )
        )
        candidate = candidate_dir / f"{self.settings.interface}.conf"
        candidate.touch(mode=0o600)
        environment = os.environ.copy()
        environment["WARP_GENERATOR_SITE_URL"] = self.settings.generator_site_url
        if self.settings.generator_data_urls:
            environment["WARP_GENERATOR_DATA_URLS"] = " ".join(
                self.settings.generator_data_urls
            )
        environment["WARP_EXCLUDE_LAN"] = (
            "1" if self.settings.exclude_lan else "0"
        )
        environment["WARP_AWG_VARIANT"] = str(self.settings.awg_variant)
        environment["WARP_DNS_PRESET"] = self.settings.dns_preset
        environment["WARP_SERVER_PRESET"] = self.settings.server_preset
        environment["WARP_IPV6"] = "1" if self.settings.ipv6 else "0"
        environment["WARP_KEEPALIVE"] = str(self.settings.keepalive)
        if self.settings.generator_https_proxy:
            environment["HTTPS_PROXY"] = self.settings.generator_https_proxy
            environment["https_proxy"] = self.settings.generator_https_proxy
        else:
            for proxy_key in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
                environment.pop(proxy_key, None)
        try:
            LOG.info("warp-gen source: %s", self.settings.generator_site_url)
            LOG.info(
                "Generator transport: %s",
                "configured HTTP/HTTPS proxy"
                if self.settings.generator_https_proxy
                else "direct HTTPS connection",
            )
            LOG.info(
                "Saved generator parameters: variant=%s DNS=%s server=%s "
                "IPv6=%s LAN-exclusion=%s keepalive=%s",
                self.settings.awg_variant,
                self.settings.dns_preset,
                self.settings.server_preset,
                "on" if self.settings.ipv6 else "off",
                "on" if self.settings.exclude_lan else "off",
                self.settings.keepalive or "off",
            )
            generated = self.runner.run(
                [str(self.settings.generator_path), str(candidate)],
                timeout=self.settings.generator_timeout,
                env=environment,
            )
            for line in generated.stderr.splitlines():
                line = line.strip()
                if line.startswith("[generator] "):
                    LOG.info("%s", line)
            if generated.returncode != 0:
                raise RuntimeError("warp-gen config request failed")
            self.validate_candidate(candidate)
            return candidate
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
            shutil.rmtree(candidate_dir, ignore_errors=True)
            if isinstance(exc, subprocess.TimeoutExpired):
                raise RuntimeError("WARP config generator did not complete") from exc
            raise

    def rotate_once(
        self,
        state: State,
        force: bool = False,
        ignore_cooldown: bool = False,
        record_rotation: bool = True,
    ) -> bool:
        allowed, reason = self.may_rotate(state, force, ignore_cooldown)
        if not allowed:
            LOG.error("Configuration rotation skipped: %s", reason)
            state.last_action = f"rotation skipped: {reason}"
            return False

        service_was_active = self.command_ok(
            [
                self.settings.systemctl_command,
                "is-active",
                "--quiet",
                self.settings.service,
            ]
        )
        stopped_for_generation = False
        if service_was_active and self.settings.allow_hard_restart:
            LOG.warning(
                "Stopping the unhealthy tunnel before requesting a fresh "
                "warp-gen profile so the generator uses the physical connection"
            )
            if not self.command_ok(
                [
                    self.settings.systemctl_command,
                    "stop",
                    self.settings.service,
                ],
                timeout=45,
            ):
                LOG.error("Could not stop the tunnel before the warp-gen request")
                state.last_action = "rotation could not stop tunnel"
                return False
            stopped_for_generation = True

        if record_rotation:
            now = int(time.time())
            state.last_rotation_attempt = now
            state.rotation_attempts = [
                value for value in state.rotation_attempts if value > now - 86400
            ] + [now]
            state.save(self.state_path)
        LOG.warning("Requesting a fresh complete config with saved warp-gen parameters")
        try:
            candidate = self.generate_candidate(state)
        except (OSError, ValueError, RuntimeError) as exc:
            LOG.error("Could not generate a valid replacement config: %s", exc)
            if stopped_for_generation:
                LOG.warning("Restarting the previous tunnel after generation failure")
                self.hard_restart()
            state.last_action = "rotation generation failed"
            return False

        backup = self.backup_current()
        current = self.settings.config_path
        try:
            if (
                not stopped_for_generation
                and current.exists()
                and self.soft_reload(candidate)
            ):
                probe = self.wait_and_health()
                if probe.healthy:
                    os.replace(candidate, current)
                    os.chmod(current, 0o600)
                    state.consecutive_failures = 0
                    state.last_success = int(time.time())
                    state.last_action = "rotated with live sync"
                    LOG.info("New config passed health checks after live sync")
                    return True
                LOG.warning("Live-synced candidate failed checks; restoring live config")
                self.soft_reload(current)

            os.replace(candidate, current)
            os.chmod(current, 0o600)
            if self.hard_restart():
                probe = self.wait_and_health()
                if probe.healthy:
                    state.consecutive_failures = 0
                    state.last_success = int(time.time())
                    state.last_action = "rotated with service restart"
                    LOG.info("New config passed health checks after service restart")
                    return True
            LOG.error("Replacement config failed; rolling back")
            if backup is not None:
                shutil.copy2(backup, current)
                os.chmod(current, 0o600)
                self.hard_restart()
            else:
                self.command_ok(
                    [
                        self.settings.systemctl_command,
                        "stop",
                        self.settings.service,
                    ],
                    timeout=45,
                )
                current.unlink(missing_ok=True)
            state.last_action = "rotation rolled back"
            return False
        finally:
            candidate.unlink(missing_ok=True)
            try:
                candidate.parent.rmdir()
            except OSError:
                pass

    def rotate(self, state: State, force: bool = False) -> bool:
        allowed, reason = self.may_rotate(state, force)
        if not allowed:
            LOG.error("Configuration rotation skipped: %s", reason)
            state.last_action = f"rotation skipped: {reason}"
            return False
        attempts = self.settings.candidate_attempts
        for number in range(1, attempts + 1):
            LOG.warning(
                "Fresh warp-gen candidate attempt %s/%s",
                number,
                attempts,
            )
            if self.rotate_once(
                state,
                force=True,
                record_rotation=number == 1,
            ):
                return True
        LOG.error("No replacement WARP configuration passed health checks")
        return False

    def recover(self, state: State, force_rotation: bool = False) -> bool:
        if self.settings.config_path.exists() and self.soft_reload(
            self.settings.config_path
        ):
            probe = self.wait_and_health()
            if probe.healthy:
                state.consecutive_failures = 0
                state.last_success = int(time.time())
                state.last_action = "recovered with live sync"
                LOG.warning("Tunnel recovered after live config sync")
                return True
        if self.hard_restart():
            probe = self.wait_and_health()
            if probe.healthy:
                state.consecutive_failures = 0
                state.last_success = int(time.time())
                state.last_action = "recovered with service restart"
                LOG.warning("Tunnel recovered after service restart")
                return True
        return self.rotate(state, force=force_rotation)

    def scheduled_run(self) -> int:
        state = State.load(self.state_path)
        health = self.health()
        if health.healthy:
            state.consecutive_failures = 0
            state.last_success = int(time.time())
            state.last_action = "health check passed"
            state.save(self.state_path)
            LOG.info(
                "Healthy: sites=%s/%s handshake_age=%ss",
                health.sites_ok,
                health.sites_total,
                health.handshake_age,
            )
            return 0
        state.consecutive_failures += 1
        state.last_action = "health check failed"
        state.save(self.state_path)
        LOG.warning(
            "Health check failed (%s/%s): %s",
            state.consecutive_failures,
            self.settings.failures_before_repair,
            "; ".join(health.errors),
        )
        if state.consecutive_failures < self.settings.failures_before_repair:
            return 0
        recovered = self.recover(state)
        state.save(self.state_path)
        return 0 if recovered else 1


def lock_or_exit(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle = path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def health_json(health: Health) -> str:
    return json.dumps(asdict(health), indent=2, ensure_ascii=False)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", type=Path, default=DEFAULT_CONFIG_FILE, help="guardian.env path"
    )
    parser.add_argument("--verbose", action="store_true")
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("run", help="timer entrypoint: check and repair if needed")
    subparsers.add_parser("check", help="run one read-only health check")
    subparsers.add_parser("status", help="print health and recovery state as JSON")
    repair = subparsers.add_parser("repair", help="force the recovery sequence")
    repair.add_argument("--rotate", action="store_true", help="force credential rotation")
    rotate = subparsers.add_parser("rotate", help="generate and activate a new config")
    rotate.add_argument("--force", action="store_true", help="ignore rotation limits")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    try:
        settings = Settings.from_file(args.config)
    except (OSError, ValueError) as exc:
        LOG.error("Invalid configuration: %s", exc)
        return 2
    guardian = Guardian(settings)

    if args.action == "check":
        health = guardian.health()
        print(health_json(health))
        return 0 if health.healthy else 1
    if args.action == "status":
        payload = {
            "health": asdict(guardian.health()),
            "state": asdict(State.load(guardian.state_path)),
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    lock = lock_or_exit(settings.state_dir / "guardian.lock")
    if lock is None:
        LOG.info("Another guardian process is active; skipping")
        return 0
    try:
        state = State.load(guardian.state_path)
        if args.action == "run":
            return guardian.scheduled_run()
        if args.action == "repair":
            if args.rotate:
                result = guardian.rotate(state, force=True)
            else:
                result = guardian.recover(state)
            state.save(guardian.state_path)
            return 0 if result else 1
        if args.action == "rotate":
            result = guardian.rotate(state, force=args.force)
            state.save(guardian.state_path)
            return 0 if result else 1
    finally:
        lock.close()
    return 2


if __name__ == "__main__":
    sys.exit(main())
