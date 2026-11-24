"""Small, bounded Harvest API bridge. JSON in/out, secrets never on argv."""
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo
from timezones import ZONES

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy/harvest/credentials.json"
LIMIT = 2 * 1024 * 1024
MAX_ITEMS = 2000


class Failure(Exception):
    pass


def ident(value):
    if isinstance(value, bool) or not re.fullmatch(r"[1-9][0-9]{0,15}", str(value)):
        raise Failure("invalid")
    return int(value)


def text(value, limit=240):
    return "".join(c for c in str(value or "")[:limit] if c >= " " or c == "\n")


def number(value):
    n = float(value)
    if not math.isfinite(n) or n < 0 or n > 1000000:
        raise Failure("response")
    return n


def credentials(value):
    account = str(ident(value.get("account_id", "")))
    token = value.get("token", "")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9._~-]{10,1024}", token):
        raise Failure("credentials")
    return {"account_id": account, "token": token, "sync": value.get("sync") is True}


def load():
    try:
        if CONFIG.is_symlink() or CONFIG.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            raise Failure("permissions")
        if CONFIG.stat().st_size > 4096:
            raise Failure("credentials")
        return credentials(json.loads(CONFIG.read_text()))
    except FileNotFoundError:
        return None


def save(value):
    value = credentials(value)
    CONFIG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CONFIG.parent, prefix=".credentials-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle)
        os.replace(tmp, CONFIG)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise Failure("network")


class API:
    def __init__(self, config):
        self.config = config
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, method="GET", data=None, params=None):
        # Every route is constructed locally, never from a response's links.
        url = "https://api.harvestapp.com/v2/" + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, method=method, headers={
            "Authorization": "Bearer " + self.config["token"],
            "Harvest-Account-Id": self.config["account_id"],
            "User-Agent": "OmarchyHarvest/1.0 (personal desktop time tracker)",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }, data=None if data is None else json.dumps(data).encode())
        try:
            with self.opener.open(req, timeout=12) as response:
                raw = response.read(LIMIT + 1)
            if len(raw) > LIMIT:
                raise Failure("response")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise Failure("response")
            return result
        except urllib.error.HTTPError as error:
            raise Failure({401: "auth", 403: "auth", 429: "rate", 422: "rejected"}.get(error.code, "network")) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure("network") from None

    def collection(self, path, key, params=None):
        result = []
        for page in range(1, 11):
            response = self.request(path, params={**(params or {}), "page": page, "per_page": 200})
            items = response.get(key)
            if not isinstance(items, list) or len(items) > 200:
                raise Failure("response")
            result.extend(items)
            if len(result) > MAX_ITEMS:
                raise Failure("response")
            if response.get("next_page") is None:
                return result
            if response["next_page"] != page + 1:
                raise Failure("response")
        raise Failure("response")


def entry(raw):
    date = dt.date.fromisoformat(raw["spent_date"]).isoformat()
    return {
        "id": ident(raw["id"]), "date": date,
        "project": text(raw["project"]["name"]),
        "task": text(raw["task"]["name"]),
        "notes": text(raw.get("notes"), 1000),
        "hours": number(raw["hours"]), "running": raw.get("is_running") is True,
    }


def context(api):
    user = api.request("users/me")
    try:
        name = user.get("timezone") or "UTC"
        zone = ZoneInfo(ZONES.get(name, name))
    except (ValueError, KeyError):
        raise Failure("response") from None
    return ident(user["id"]), dt.datetime.now(zone).date().isoformat()


def snapshot(api, uid, today, projects=False):
    entries = api.collection("time_entries", "time_entries", {"user_id": uid, "from": today, "to": today})
    running = api.collection("time_entries", "time_entries", {"user_id": uid, "is_running": "true"})
    result = {
        "date": today,
        "hours": sum(number(e["hours"]) for e in entries),
        "entries": [entry(e) for e in entries],
        "running": [entry(e) for e in running],
        "synced_at": dt.datetime.now(dt.timezone.utc).timestamp(),
    }
    if projects:
        assignments = api.collection("users/me/project_assignments", "project_assignments")
        result["projects"] = []
        for assignment in assignments:
            if assignment.get("is_active") is not True or assignment["project"].get("is_active") is False:
                continue
            tasks = assignment.get("task_assignments", [])
            if not isinstance(tasks, list) or len(tasks) > MAX_ITEMS:
                raise Failure("response")
            result["projects"].append({
                "id": ident(assignment["project"]["id"]),
                "name": text(assignment.get("client", {}).get("name")) + " / " + text(assignment["project"]["name"]),
                "tasks": [{"id": ident(t["task"]["id"]), "name": text(t["task"]["name"])}
                          for t in tasks if t.get("is_active") is True],
            })
    return result


def handle(payload, api_type=API):
    action = payload.get("action", "status")
    config = load()
    if action == "status":
        return {"ok": True, "configured": config is not None, "sync": bool(config and config["sync"])}
    if action == "configure":
        config = credentials(payload)
        api_type(config).request("users/me")  # Validate before replacing a working token.
        save(config)
        return {"ok": True, "configured": True, "sync": config["sync"]}
    if config is None:
        raise Failure("credentials")
    if action == "sync":
        config["sync"] = payload.get("enabled") is True
        save(config)
        return {"ok": True, "configured": True, "sync": config["sync"]}
    if action not in ("refresh", "start", "stop", "resume"):
        raise Failure("invalid")
    api = api_type(config)
    uid, today = context(api)
    if action == "start":
        if api.collection("time_entries", "time_entries", {"user_id": uid, "is_running": "true"}):
            raise Failure("running")
        api.request("time_entries", "POST", {
            "project_id": ident(payload["project_id"]), "task_id": ident(payload["task_id"]),
            "spent_date": today, "notes": text(payload.get("notes"), 1000),
        })
    elif action in ("stop", "resume"):
        eid = ident(payload["id"])
        raw = api.request(f"time_entries/{eid}")
        if ident(raw["user"]["id"]) != uid:
            raise Failure("invalid")
        if action == "resume" and api.collection("time_entries", "time_entries", {"user_id": uid, "is_running": "true"}):
            raise Failure("running")
        if action == "resume" and raw["spent_date"] != today:
            raise Failure("invalid")
        if (raw.get("is_running") is True) == (action == "resume"):
            raise Failure("rejected")
        api.request(f"time_entries/{eid}/{'stop' if action == 'stop' else 'restart'}", "PATCH")
    result = {"ok": True, "configured": True, "sync": config["sync"]}
    # Mutation success must survive a failure of the subsequent read.
    if action != "refresh":
        return {**result, "changed": True}
    return {**result, "data": snapshot(api, uid, today, payload.get("projects") is True)}


def main():
    def timeout(*_):
        raise Failure("timeout")
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(45)
    try:
        raw = sys.stdin.readline(8193)
        if len(raw) > 8192:
            raise Failure("invalid")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise Failure("invalid")
        result = handle(payload)
    except Failure as error:
        result = {"ok": False, "error": str(error)}
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError, OSError):
        result = {"ok": False, "error": "response"}
    print(json.dumps(result, ensure_ascii=True), flush=True)


if __name__ == "__main__":
    main()
