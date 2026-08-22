import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "src" / "guardian.py"
SPEC = importlib.util.spec_from_file_location("guardian", MODULE_PATH)
guardian = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = guardian
SPEC.loader.exec_module(guardian)


VALID_CONFIG = """[Interface]
PrivateKey = NEW_SECRET
Address = 172.16.0.2
DNS = 1.1.1.1
I1 = <b 0x0102>

[Peer]
PublicKey = NEW_PEER
AllowedIPs = 1.0.0.0/8, 2.0.0.0/7
Endpoint = random.example:500
"""


def make_settings(directory: str) -> guardian.Settings:
    root = Path(directory)
    return guardian.Settings(
        interface="awg-test",
        config_path=root / "awg-test.conf",
        service="awg-quick@awg-test.service",
        check_urls=("https://one.test",),
        check_quorum=1,
        trace_url="https://trace.test",
        require_warp=True,
        bind_to_interface=True,
        curl_timeout=2,
        max_handshake_age=300,
        failures_before_repair=3,
        repair_wait=0,
        rotation_cooldown=1800,
        max_rotations_per_day=4,
        backups_keep=2,
        generator_path=Path("/fake/generator"),
        generator_timeout=5,
        generator_site_url="https://warp-gen.example",
        generator_data_urls=("https://data-one.example", "https://data-two.example"),
        generator_https_proxy="",
        exclude_lan=True,
        awg_variant=2,
        dns_preset="google",
        server_preset="def",
        ipv6=False,
        keepalive=25,
        candidate_attempts=3,
        allow_hard_restart=True,
        state_dir=root / "state",
    )


class ConfigTests(unittest.TestCase):
    def test_parse_env_does_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "owned"
            config = Path(directory) / "guardian.env"
            config.write_text(
                'CHECK_URLS="https://one.test https://two.test"\n'
                f'UNTRUSTED="$(touch {marker})"\n',
                encoding="utf-8",
            )
            values = guardian.parse_env_file(config)
            self.assertIn("$(touch", values["UNTRUSTED"])
            self.assertFalse(marker.exists())

    def test_settings_read_saved_warp_gen_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "guardian.env"
            config.write_text(
                "CHECK_URLS=https://one.test\n"
                "GENERATOR_SITE_URL=https://mirror.example/warp\n"
                'GENERATOR_DATA_URLS="https://one.example/api https://two.example/api"\n'
                "WARP_AWG_VARIANT=3\nWARP_DNS_PRESET=cf\n"
                "WARP_SERVER_PRESET=NL\nWARP_IPV6=0\nWARP_KEEPALIVE=25\n"
                "EXCLUDE_LAN=1\nCANDIDATE_ATTEMPTS=20\n",
                encoding="utf-8",
            )
            settings = guardian.Settings.from_file(config)
            self.assertEqual(settings.generator_site_url, "https://mirror.example/warp")
            self.assertEqual(len(settings.generator_data_urls), 2)
            self.assertEqual(settings.awg_variant, 3)
            self.assertEqual(settings.server_preset, "NL")
            self.assertFalse(settings.ipv6)
            self.assertEqual(settings.candidate_attempts, 20)

    def test_settings_accept_random_variant_and_infinite_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "guardian.env"
            config.write_text(
                "CHECK_URLS=https://one.test\n"
                "WARP_AWG_VARIANT=random\n"
                "CANDIDATE_ATTEMPTS=infinite\n",
                encoding="utf-8",
            )
            settings = guardian.Settings.from_file(config)
            self.assertEqual(settings.awg_variant, "random")
            self.assertEqual(settings.candidate_attempts, 0)

    def test_settings_reject_bad_source_and_attempt_count(self):
        for line, message in (
            ("GENERATOR_SITE_URL=http://unsafe.example", "GENERATOR_SITE_URL"),
            ("CANDIDATE_ATTEMPTS=21", "CANDIDATE_ATTEMPTS"),
            ("WARP_AWG_VARIANT=4", "WARP_AWG_VARIANT"),
        ):
            with tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / "guardian.env"
                config.write_text(
                    f"CHECK_URLS=https://one.test\n{line}\n", encoding="utf-8"
                )
                with self.assertRaisesRegex(ValueError, message):
                    guardian.Settings.from_file(config)

    def test_basic_validation_reports_missing_fields(self):
        missing = guardian.basic_validate_config("[Interface]\nPrivateKey = x\n")
        self.assertIn("[Peer]", missing)
        self.assertIn("Endpoint", missing)


class StateTests(unittest.TestCase):
    def test_state_round_trip_and_ignores_legacy_endpoint_index(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            original = guardian.State(consecutive_failures=2, last_action="test")
            original.save(path)
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["endpoint_index"] = 9
            path.write_text(json.dumps(payload), encoding="utf-8")
            loaded = guardian.State.load(path)
            self.assertEqual(loaded.consecutive_failures, 2)
            self.assertEqual(loaded.last_action, "test")


class GeneratorRunner:
    def __init__(self, generated_text=VALID_CONFIG, generated_stderr=""):
        self.generated_text = generated_text
        self.generated_stderr = generated_stderr
        self.generator_environment = None

    def run(self, args, **kwargs):
        if args[0] == "/fake/generator":
            self.generator_environment = kwargs.get("env")
            Path(args[1]).write_text(self.generated_text, encoding="utf-8")
            return subprocess.CompletedProcess(args, 0, "", self.generated_stderr)
        if args[:2] == ["awg-quick", "strip"]:
            return subprocess.CompletedProcess(args, 0, "stripped config", "")
        raise AssertionError(f"unexpected command: {args}")


class GeneratorTests(unittest.TestCase):
    def test_candidate_uses_all_saved_parameters_without_merging_old_config(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            settings.config_path.write_text("PrivateKey = OLD_SECRET\n", encoding="utf-8")
            runner = GeneratorRunner()
            instance = guardian.Guardian(settings, runner)
            candidate = instance.generate_candidate(guardian.State())
            self.assertEqual(candidate.read_text(encoding="utf-8"), VALID_CONFIG)
            environment = runner.generator_environment
            self.assertEqual(environment["WARP_GENERATOR_SITE_URL"], settings.generator_site_url)
            self.assertEqual(environment["WARP_AWG_VARIANT"], "2")
            self.assertEqual(environment["WARP_DNS_PRESET"], "google")
            self.assertEqual(environment["WARP_SERVER_PRESET"], "def")
            self.assertEqual(environment["WARP_IPV6"], "0")
            self.assertEqual(environment["WARP_KEEPALIVE"], "25")
            self.assertEqual(environment["WARP_EXCLUDE_LAN"], "1")
            self.assertNotIn("OLD_SECRET", candidate.read_text(encoding="utf-8"))

    def test_only_prefixed_generator_progress_is_logged(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = GeneratorRunner(
                generated_stderr=(
                    "[generator] Requesting a fresh warp-gen config bundle\n"
                    "PrivateKey = MUST_NOT_BE_LOGGED\n"
                )
            )
            instance = guardian.Guardian(make_settings(directory), runner)
            with self.assertLogs("awg-warp-guardian", level="INFO") as captured:
                instance.generate_candidate(guardian.State())
            output = "\n".join(captured.output)
            self.assertIn("fresh warp-gen config bundle", output)
            self.assertNotIn("MUST_NOT_BE_LOGGED", output)


class BackupTests(unittest.TestCase):
    def test_new_backup_is_not_pruned_when_source_has_an_old_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            settings.config_path.write_text(VALID_CONFIG, encoding="utf-8")
            os.utime(settings.config_path, (1, 1))
            instance = guardian.Guardian(settings)
            instance.backup_dir.mkdir(parents=True)
            for index in range(settings.backups_keep):
                old = instance.backup_dir / f"awg-test-20260822T00000{index}Z.conf"
                old.write_text(f"old-{index}", encoding="utf-8")

            backup = instance.backup_current()

            self.assertIsNotNone(backup)
            self.assertTrue(backup.exists())
            self.assertEqual(backup.read_text(encoding="utf-8"), VALID_CONFIG)
            self.assertEqual(
                len(list(instance.backup_dir.glob("awg-test-*.conf"))),
                settings.backups_keep,
            )


class ParallelHealthRunner:
    def __init__(self):
        self.active_curls = 0
        self.max_active_curls = 0
        self.lock = threading.Lock()

    def run(self, args, **kwargs):
        if args[0] == "curl":
            with self.lock:
                self.active_curls += 1
                self.max_active_curls = max(self.max_active_curls, self.active_curls)
            time.sleep(0.03)
            with self.lock:
                self.active_curls -= 1
            stdout = "warp=on\n" if "--output" not in args else ""
            return subprocess.CompletedProcess(args, 0, stdout, "")
        if args[:3] == ["systemctl", "is-active", "--quiet"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:3] == ["ip", "link", "show"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:3] == ["awg", "show", "awg-test"]:
            return subprocess.CompletedProcess(args, 0, f"peer {int(time.time())}\n", "")
        raise AssertionError(f"unexpected command: {args}")


class HealthTests(unittest.TestCase):
    def test_site_and_trace_probes_run_in_parallel(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = replace(
                make_settings(directory),
                check_urls=("https://one.test", "https://two.test", "https://three.test"),
                check_quorum=2,
            )
            runner = ParallelHealthRunner()
            result = guardian.Guardian(settings, runner).health()
            self.assertTrue(result.healthy)
            self.assertGreater(runner.max_active_curls, 1)


class TimedOutRestartRunner:
    def __init__(self):
        self.events = []

    def run(self, args, *, input_text=None, timeout=None, env=None):
        self.events.append((list(args), timeout))
        if args[:2] == ["systemctl", "restart"]:
            raise subprocess.TimeoutExpired(args, timeout)
        if args[:2] == ["systemctl", "stop"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        raise AssertionError(f"unexpected command: {args}")


class RestartTests(unittest.TestCase):
    def test_timed_out_restart_cancels_systemd_start_job(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = TimedOutRestartRunner()
            instance = guardian.Guardian(make_settings(directory), runner)

            self.assertFalse(instance.hard_restart())
            self.assertEqual(runner.events[0][0][:2], ["systemctl", "restart"])
            self.assertEqual(runner.events[0][1], 45)
            self.assertEqual(runner.events[1][0][:2], ["systemctl", "stop"])
            self.assertEqual(runner.events[1][1], 15)


class RotationGuardian(guardian.Guardian):
    def __init__(self, settings, health_results):
        super().__init__(settings)
        self.active = True
        self.health_results = iter(health_results)
        self.events = []
        self.generated = 0

    def command_ok(self, args, timeout=None):
        if args[:3] == ["systemctl", "is-active", "--quiet"]:
            return self.active
        if args[:2] == ["systemctl", "stop"]:
            self.events.append("stop")
            self.active = False
            return True
        raise AssertionError(f"unexpected command: {args}")

    def generate_candidate(self, state):
        if self.active:
            raise AssertionError("generator ran through the active tunnel")
        self.generated += 1
        self.events.append(f"fresh:{self.generated}")
        candidate_dir = Path(tempfile.mkdtemp(dir=self.settings.config_path.parent))
        candidate = candidate_dir / self.settings.config_path.name
        candidate.write_text(VALID_CONFIG.replace("random.example", f"random-{self.generated}.example"), encoding="utf-8")
        return candidate

    def hard_restart(self):
        self.events.append("restart")
        self.active = True
        return True

    def wait_and_health(self):
        healthy = next(self.health_results)
        return guardian.Health(
            healthy=healthy,
            service_active=True,
            interface_up=True,
            sites_ok=1 if healthy else 0,
            sites_total=1,
            warp_on=healthy,
            handshake_age=0 if healthy else None,
        )


class RotationTests(unittest.TestCase):
    def test_rotation_fetches_fresh_candidates_until_one_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = replace(make_settings(directory), candidate_attempts=3)
            settings.config_path.write_text(VALID_CONFIG, encoding="utf-8")
            instance = RotationGuardian(settings, [False, True])
            self.assertTrue(instance.rotate(guardian.State(), force=True))
            self.assertEqual(instance.generated, 2)
            self.assertEqual(instance.events[:2], ["stop", "fresh:1"])
            self.assertIn("random-2.example", settings.config_path.read_text(encoding="utf-8"))

    def test_failed_candidate_rolls_back_from_memory_not_retained_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = replace(make_settings(directory), candidate_attempts=1)
            settings.config_path.write_text(VALID_CONFIG, encoding="utf-8")
            instance = RotationGuardian(settings, [False])

            original_backup = instance.backup_current

            def disappearing_backup():
                backup = original_backup()
                assert backup is not None
                backup.unlink()
                return backup

            instance.backup_current = disappearing_backup

            self.assertFalse(instance.rotate(guardian.State(), force=True))
            self.assertEqual(
                settings.config_path.read_text(encoding="utf-8"), VALID_CONFIG
            )

    def test_infinite_mode_keeps_trying_until_a_candidate_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = replace(make_settings(directory), candidate_attempts=0)
            settings.config_path.write_text(VALID_CONFIG, encoding="utf-8")
            instance = RotationGuardian(settings, [False, False, False, True])

            self.assertTrue(instance.rotate(guardian.State(), force=True))
            self.assertEqual(instance.generated, 4)
            self.assertIn(
                "random-4.example",
                settings.config_path.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
