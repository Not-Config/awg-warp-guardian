import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "src" / "guardian.py"
SPEC = importlib.util.spec_from_file_location("guardian", MODULE_PATH)
guardian = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = guardian
SPEC.loader.exec_module(guardian)


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
            self.assertEqual(
                values["CHECK_URLS"], "https://one.test https://two.test"
            )
            self.assertIn("$(touch", values["UNTRUSTED"])
            self.assertFalse(marker.exists())

    def test_settings_reject_impossible_quorum(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "guardian.env"
            config.write_text(
                "CHECK_URLS=https://one.test\nCHECK_QUORUM=2\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "CHECK_QUORUM"):
                guardian.Settings.from_file(config)

    def test_generator_api_requires_trusted_https_base_url(self):
        self.assertEqual(
            guardian.https_base_url(
                "https://mirror.example/warp/", "GENERATOR_API_URL"
            ),
            "https://mirror.example/warp",
        )
        for invalid in (
            "http://mirror.example/warp",
            "https://user:secret@mirror.example/warp",
            "https://mirror.example/warp?target=other",
            "https://mirror.example:99999/warp",
        ):
            with self.assertRaisesRegex(ValueError, "GENERATOR_API_URL"):
                guardian.https_base_url(invalid, "GENERATOR_API_URL")


class MergeTests(unittest.TestCase):
    def test_preserves_routing_hooks_but_not_old_credentials(self):
        current = """[Interface]
PrivateKey = OLD_SECRET
Table = 123
PostUp = ip rule add from 192.168.1.251 table main
S3 = 7
I1 = <b 0x1234>

[Peer]
PublicKey = OLD_PEER
Endpoint = old.example:500
"""
        candidate = """[Interface]
PrivateKey = NEW_SECRET
Address = 172.16.0.2/32
Table = auto
S3 = 0
I1 = 0xabcd

[Peer]
PublicKey = NEW_PEER
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:500
"""
        merged = guardian.merge_interface_directives(
            current, candidate, ("Table", "PostUp", "S3", "I1")
        )
        self.assertIn("PrivateKey = NEW_SECRET", merged)
        self.assertNotIn("OLD_SECRET", merged)
        self.assertIn("Table = 123", merged)
        self.assertNotIn("Table = auto", merged)
        self.assertIn("PostUp = ip rule add", merged)
        self.assertIn("S3 = 7", merged)
        self.assertIn("I1 = <b 0x1234>", merged)
        self.assertNotIn("I1 = 0xabcd", merged)

    def test_basic_validation_reports_missing_fields(self):
        missing = guardian.basic_validate_config("[Interface]\nPrivateKey = x\n")
        self.assertIn("[Peer]", missing)
        self.assertIn("Endpoint", missing)
        self.assertNotIn("PrivateKey", missing)


class StateTests(unittest.TestCase):
    def test_state_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            original = guardian.State(
                consecutive_failures=2,
                rotation_attempts=[int(time.time())],
                last_action="test",
            )
            original.save(path)
            loaded = guardian.State.load(path)
            self.assertEqual(loaded.consecutive_failures, 2)
            self.assertEqual(loaded.last_action, "test")
            json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


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
        generator_api_url="https://mirror.example/v0i1909051800",
        generator_https_proxy="",
        endpoints=("162.159.192.1:500",),
        preserve_directives=("PostUp", "S3", "I1"),
        allow_hard_restart=True,
        state_dir=root / "state",
    )


VALID_CONFIG = """[Interface]
PrivateKey = NEW_SECRET
Address = 172.16.0.2/32

[Peer]
PublicKey = NEW_PEER
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:500
"""


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
    def test_candidate_basename_is_valid_for_awg_quick(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            runner = GeneratorRunner()
            instance = guardian.Guardian(settings, runner)
            candidate = instance.generate_candidate(guardian.State())
            self.assertEqual(candidate.name, "awg-test.conf")
            self.assertEqual(candidate.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                runner.generator_environment["WARP_API_BASE_URL"],
                "https://mirror.example/v0i1909051800",
            )
            candidate.unlink()
            candidate.parent.rmdir()

    def test_invalid_candidate_directory_is_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            instance = guardian.Guardian(settings, GeneratorRunner("invalid"))
            with self.assertRaisesRegex(ValueError, "misses"):
                instance.generate_candidate(guardian.State())
            leftovers = list(Path(directory).glob(".awg-guardian-candidate.*"))
            self.assertEqual(leftovers, [])

    def test_safe_generator_progress_is_forwarded_to_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            runner = GeneratorRunner(
                generated_stderr=(
                    "[generator] Registration API: https://mirror.example/api\n"
                    "PrivateKey = MUST_NOT_BE_LOGGED\n"
                )
            )
            instance = guardian.Guardian(settings, runner)
            with self.assertLogs("awg-warp-guardian", level="INFO") as captured:
                candidate = instance.generate_candidate(guardian.State())
            output = "\n".join(captured.output)
            self.assertIn("[generator] Registration API", output)
            self.assertNotIn("MUST_NOT_BE_LOGGED", output)
            candidate.unlink()
            candidate.parent.rmdir()

    def test_rotation_limits_repeated_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = make_settings(directory)
            instance = guardian.Guardian(settings, GeneratorRunner())
            now = int(time.time())
            state = guardian.State(
                last_rotation_attempt=now,
                rotation_attempts=[now],
            )
            allowed, reason = instance.may_rotate(state)
            self.assertFalse(allowed)
            self.assertIn("cooldown", reason)
            self.assertTrue(instance.may_rotate(state, force=True)[0])


if __name__ == "__main__":
    unittest.main()
