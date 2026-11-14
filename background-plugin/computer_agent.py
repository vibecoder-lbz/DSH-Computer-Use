"""Windows desktop automation CLI and JSON-lines bridge (Python stdlib only)."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
ACTIONS = {
    "apps": "List installed applications from Windows uninstall registry entries.",
    "windows": "List visible desktop windows and their handles.",
    "inspect": "Read a bounded UI Automation tree for one window. Re-inspect after UI changes.",
    "launch": "Start an executable at an absolute path; arguments are passed as an array.",
    "invoke": "Activate one control via UI Automation InvokePattern.",
    "set_value": "Set an editable control through ValuePattern.",
    "select": "Select a control through SelectionItemPattern.",
    "click": "Focus a window and click coordinates relative to its top-left corner.",
    "screenshot": "Save a PNG of a window, or the desktop when hwnd is omitted.",
    "compare": "Compare two same-sized PNG images; visual change does not establish task success.",
    "wait": "Wait a bounded time for a matching UI Automation control.",
}
PARAMS = {
    "apps": {"query": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 500}},
    "windows": {},
    "inspect": {"hwnd": {"type": "integer"}, "limit": {"type": "integer", "minimum": 1, "maximum": 500}, "depth": {"type": "integer", "minimum": 0, "maximum": 12}},
    "launch": {"path": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}}},
    "click": {"hwnd": {"type": "integer"}, "x": {"type": "integer", "minimum": 0}, "y": {"type": "integer", "minimum": 0}},
    "screenshot": {"hwnd": {"type": "integer"}, "path": {"type": "string"}},
    "compare": {"before": {"type": "string"}, "after": {"type": "string"}, "threshold": {"type": "integer", "minimum": 0, "maximum": 255}, "stride": {"type": "integer", "minimum": 1, "maximum": 32}},
}
SELECTOR = {"type": "object", "properties": {k: {"type": "string"} for k in ("ref", "automation_id", "name", "control_type")}, "additionalProperties": False, "minProperties": 1}
for action in ("invoke", "set_value", "select", "wait"):
    PARAMS[action] = {"hwnd": {"type": "integer"}, "selector": SELECTOR}
PARAMS["set_value"]["value"] = {"type": "string"}
PARAMS["wait"]["timeout_ms"] = {"type": "integer", "minimum": 1, "maximum": 30000}
REQUIRED = {"inspect": ["hwnd"], "launch": ["path"], "click": ["hwnd", "x", "y"], "compare": ["before", "after"], "invoke": ["hwnd", "selector"], "set_value": ["hwnd", "selector", "value"], "select": ["hwnd", "selector"], "wait": ["hwnd", "selector"]}


def describe():
    return {"protocol": "One JSON request per line; response echoes id and returns ok/result or ok/error.",
            "workflow": "apps/windows -> inspect -> invoke/set_value/select -> inspect/screenshot. Use click only when controls are unavailable. Screenshot coordinates use physical screen pixels; click coordinates are relative to the window. Desktop must be unlocked and interactive. Elevated apps may require an elevated process.",
            "tools": [{"name": name, "description": desc, "input_schema": {"type": "object", "properties": PARAMS[name], "required": REQUIRED.get(name, []), "additionalProperties": False}} for name, desc in ACTIONS.items()]}


def validate(value, schema, location="params"):
    kind = schema.get("type")
    valid = {"object": isinstance(value, dict), "array": isinstance(value, list), "string": isinstance(value, str), "integer": type(value) is int}.get(kind, True)
    if not valid:
        raise ValueError(f"{location} must be {kind}")
    if kind == "object":
        props = schema["properties"]
        unknown = set(value) - set(props)
        if unknown:
            raise ValueError(f"Unknown {location} keys: {sorted(unknown)}")
        for key in schema.get("required", []):
            if key not in value:
                raise ValueError(f"Missing {location}.{key}")
        if len(value) < schema.get("minProperties", 0):
            raise ValueError(f"{location} must contain a selector")
        for key, item in value.items():
            validate(item, props[key], f"{location}.{key}")
    elif kind == "array":
        for item in value:
            validate(item, schema["items"], location)
    elif kind == "integer":
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            raise ValueError(f"{location} is outside allowed range")
    if location.startswith("params.selector.") and not value:
        raise ValueError("Selector fields must not be empty")


def execute(action, params):
    if action == "describe":
        if params:
            raise ValueError("describe takes no parameters")
        return describe()
    if action in ('click', 'launch', 'invoke', 'set_value', 'select'):
        raise ValueError('Read-only background mode: clicking, launching, input and control changes are disabled')
    if action == 'screenshot' and not params.get('hwnd'):
        raise ValueError('Background screenshots require hwnd; desktop capture is disabled')
    if action not in ACTIONS:
        raise ValueError(f"Unknown action {action!r}; use describe")
    validate(params, {"type": "object", "properties": PARAMS[action], "required": REQUIRED.get(action, [])})
    if os.name != "nt":
        raise RuntimeError("Desktop actions require Windows")
    params = dict(params)
    if action == "launch":
        path = Path(params["path"])
        if not path.is_absolute() or not path.is_file() or path.suffix.lower() != ".exe":
            raise ValueError("launch.path must be an existing absolute .exe path")
        params["arguments"] = subprocess.list2cmdline(params.pop("args", []))
    if action == "screenshot":
        path = Path(params.get("path", str(ROOT / "artifacts" / "screenshot.png"))).resolve()
        if path.suffix.lower() != ".png":
            raise ValueError("Screenshot path must end in .png")
        path.parent.mkdir(parents=True, exist_ok=True)
        params["path"] = str(path)
    if action == "compare":
        for key in ("before", "after"):
            params[key] = str(Path(params[key]).resolve(strict=True))
    shell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    # Files, rather than pipes, also work in restricted Windows process environments.
    with tempfile.TemporaryDirectory(prefix="computer-agent-") as folder:
        request = Path(folder) / "request.json"
        response = Path(folder) / "response.json"
        log = Path(folder) / "backend.log"
        request.write_text(json.dumps({"action": action, "params": params}, ensure_ascii=False), encoding="utf-8")
        with log.open("wb") as output:
            try:
                proc = subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "windows_backend.ps1"), "-RequestPath", str(request), "-ResponsePath", str(response)], stdout=output, stderr=output, timeout=45)
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError("Backend timed out; action state is unknown. Inspect before retrying.") from exc
        if not response.exists():
            raise RuntimeError(f"Backend exited {proc.returncode}: {log.read_text(encoding='utf-8', errors='replace')[-2000:]}")
        payload = json.loads(response.read_text(encoding="utf-8-sig"))
        if not payload["ok"]:
            raise RuntimeError(payload["error"])
        return payload["result"]


def respond(request):
    ident = request.get("id") if isinstance(request, dict) else None
    try:
        if not isinstance(request, dict) or set(request) - {"id", "action", "params"}:
            raise ValueError("Request must contain action, optional id and params")
        return {"id": ident, "ok": True, "result": execute(request.get("action"), request.get("params", {}))}
    except Exception as exc:
        return {"id": ident, "ok": False, "error": str(exc)}


def main():
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["describe", "serve", *ACTIONS])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--params", default="{}", help="JSON action parameters")
    group.add_argument("--params-file", help="Read UTF-8 JSON parameters from a file (avoids shell quoting)")
    options = parser.parse_args()
    if options.action == "serve":
        for line in sys.stdin:
            try:
                response = respond(json.loads(line))
            except Exception as exc:
                response = {"id": None, "ok": False, "error": str(exc)}
            print(json.dumps(response, ensure_ascii=False), flush=True)
    else:
        try:
            raw = Path(options.params_file).read_text(encoding="utf-8-sig") if options.params_file else options.params
            response = respond({"action": options.action, "params": json.loads(raw)})
        except Exception as exc:
            response = {"ok": False, "error": str(exc)}
        print(json.dumps(response, ensure_ascii=False, indent=2))
        return 0 if response["ok"] else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
