import datetime as dt
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import harvest


TODAY = dt.datetime.now(dt.timezone.utc).date().isoformat()
CONFIG = {"account_id": "123", "token": "test-token-123456", "sync": False}


def time_entry(running=False, user=7):
    return {"id": 42, "user": {"id": user}, "spent_date": TODAY,
            "project": {"name": '<img src="https://evil.invalid/image">'},
            "task": {"name": "<b>Task</b>"}, "notes": "<script>bad()</script>",
            "hours": 1.25, "is_running": running}


class FakeAPI:
    def __init__(self, config):
        self.calls = []
        self.running = []
        self.owner = 7

    def request(self, route, method="GET", data=None, params=None):
        self.calls.append((route, method, data, params))
        if route == "users/me":
            return {"id": 7, "timezone": "UTC"}
        if route == "time_entries/42":
            return time_entry(user=self.owner)
        return {}

    def collection(self, route, key, params=None):
        self.calls.append((route, "GET", None, params))
        if route == "users/me/project_assignments":
            return [{"is_active": True, "client": {"name": "Client"},
                     "project": {"id": 9, "name": "Work"},
                     "task_assignments": [{"is_active": True, "task": {"id": 8, "name": "Task"}}]}]
        if params.get("is_running"):
            return self.running
        return [time_entry()]


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_patch = patch.object(harvest, "CONFIG", Path(self.tmp.name) / "harvest/credentials.json")
        self.config_patch.start()
        self.addCleanup(self.config_patch.stop)
        self.api = FakeAPI(CONFIG)
        harvest.save(CONFIG)

    def run_action(self, payload):
        return harvest.handle(payload, api_type=lambda _: self.api)

    def test_private_credentials_and_no_secrets_in_status(self):
        self.assertEqual(harvest.CONFIG.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("token", json.dumps(self.run_action({"action": "status"})))
        harvest.CONFIG.chmod(0o644)
        with self.assertRaisesRegex(harvest.Failure, "permissions"):
            harvest.load()

    def test_refresh_is_only_current_user_and_today(self):
        result = self.run_action({"action": "refresh", "projects": True})
        self.assertEqual(result["data"]["hours"], 1.25)
        query = self.api.calls[1][3]
        self.assertEqual(query, {"user_id": 7, "from": TODAY, "to": TODAY})
        self.assertEqual(result["data"]["projects"][0]["tasks"][0]["id"], 8)

    def test_start_has_no_hours_so_harvest_starts_timer(self):
        result = self.run_action({"action": "start", "project_id": 9, "task_id": 8, "notes": "Work"})
        self.assertTrue(result["changed"])
        call = next(c for c in self.api.calls if c[1] == "POST")
        self.assertEqual(call[2]["spent_date"], TODAY)
        self.assertNotIn("hours", call[2])

    def test_harvest_rails_timezone_names(self):
        for name in ("Pretoria", "Eastern Time (US & Canada)", "Mountain Time (US & Canada)"):
            with patch.object(self.api, "request", return_value={"id": 7, "timezone": name}):
                uid, date = harvest.context(self.api)
                self.assertEqual(uid, 7)
                self.assertEqual(len(date), 10)

    def test_start_refuses_existing_timer(self):
        self.api.running = [time_entry(True)]
        with self.assertRaisesRegex(harvest.Failure, "running"):
            self.run_action({"action": "start", "project_id": 9, "task_id": 8})
        self.assertFalse(any(c[1] == "POST" for c in self.api.calls))

    def test_cannot_change_other_users_entry(self):
        self.api.owner = 99
        with self.assertRaisesRegex(harvest.Failure, "invalid"):
            self.run_action({"action": "resume", "id": 42})
        self.assertFalse(any(c[1] == "PATCH" for c in self.api.calls))

    def test_resume_correct_endpoint(self):
        self.run_action({"action": "resume", "id": 42})
        self.assertTrue(any(c[:2] == ("time_entries/42/restart", "PATCH") for c in self.api.calls))

    def test_stop_correct_endpoint(self):
        original = self.api.request
        def request(route, *args, **kwargs):
            return time_entry(True) if route == "time_entries/42" else original(route, *args, **kwargs)
        self.api.request = request
        self.run_action({"action": "stop", "id": 42})
        self.assertTrue(any(c[:2] == ("time_entries/42/stop", "PATCH") for c in self.api.calls))

    def test_ids_reject_command_or_url_injection(self):
        for value in ("1; touch /tmp/bad", "../42", True, -1, "https://evil.invalid"):
            with self.assertRaises(harvest.Failure):
                harvest.ident(value)

    def test_pagination_does_not_follow_remote_links(self):
        api = harvest.API(CONFIG)
        with patch.object(api, "request", return_value={"time_entries": [], "next_page": "https://evil.invalid"}):
            with self.assertRaisesRegex(harvest.Failure, "response"):
                api.collection("time_entries", "time_entries")

    def test_oversized_response(self):
        api = harvest.API(CONFIG)
        with patch.object(api.opener, "open") as opened:
            opened.return_value.__enter__.return_value.read.return_value = b"x" * (harvest.LIMIT + 1)
            with self.assertRaisesRegex(harvest.Failure, "response"):
                api.request("users/me")

    def test_markup_stays_literal_and_never_reaches_shared_sinks(self):
        raw = time_entry()
        self.assertEqual(harvest.entry(raw)["project"], raw["project"]["name"])
        base = Path(__file__).parent
        self.assertIn("textFormat: Text.PlainText", (base / "PlainText.qml").read_text())
        qml = (base / "BarWidget.qml").read_text()
        # Dynamic project/task/notes have plugin-owned plain-text delegates.
        self.assertNotIn("tooltipText: modelData", qml)
        self.assertNotIn("text: modelData", "\n".join(line for line in qml.splitlines() if "Ui.Button" in line))
        self.assertEqual([line.strip() for line in qml.splitlines() if "tooltipText:" in line],
                         ['tooltipText: strings.t("open")'])
        self.assertNotIn("notify", qml.lower())

    def test_bad_json_is_structured_error(self):
        with patch("sys.stdin", io.StringIO("{bad\n")), patch("sys.stdout", new_callable=io.StringIO) as output:
            harvest.main()
            self.assertFalse(json.loads(output.getvalue())["ok"])
        harvest.signal.alarm(0)

    def test_shell_native_selectors_and_no_stale_control_lockout(self):
        qml = (Path(__file__).parent / "BarWidget.qml").read_text()
        self.assertEqual(qml.count("Ui.Dropdown {"), 2)
        self.assertNotIn("Controls.ComboBox", qml)
        condition = next(line for line in qml.splitlines() if "readonly property bool canChange:" in line)
        self.assertNotIn("fresh", condition)
        self.assertIn("!busy", condition)
        self.assertIn("root.projectIndex = Number(value)", qml)
        self.assertIn("root.taskIndex = Number(value)", qml)
        # The shared Dropdown's currentLabel and option labels use PlainText.
        dropdown = Path("/usr/share/omarchy/shell/Ui/Dropdown.qml").read_text()
        self.assertIn("textFormat: Text.PlainText", dropdown)


if __name__ == "__main__":
    unittest.main()
