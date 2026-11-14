"""Protocol tests; --desktop tests a temporary dedicated WinForms window."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import computer_agent as agent


class ProtocolTests(unittest.TestCase):
    def test_discovery(self):
        self.assertEqual(len(agent.describe()["tools"]), len(agent.ACTIONS))

    def test_validation(self):
        for action, params in [("invoke", {"hwnd": 1, "selector": {}}), ("click", {"hwnd": 1, "x": -1, "y": 0}), ("inspect", {"hwnd": True}), ("apps", {"limit": 501}), ("invoke", {"hwnd": 1, "selector": {"name": ""}}), ("apps", {"unexpected": 1})]:
            with self.subTest(action=action, params=params):
                self.assertFalse(agent.respond({"action": action, "params": params})["ok"])

    def test_bad_request(self):
        for value in [None, [], "oops", {"action": "unknown"}]:
            self.assertFalse(agent.respond(value)["ok"])

    def test_id_echo(self):
        self.assertEqual(agent.respond({"id": "abc", "action": "describe"})["id"], "abc")


def desktop_smoke():
    if os.name != "nt":
        raise RuntimeError("Windows required")
    with tempfile.TemporaryDirectory(prefix="computer-smoke-") as folder:
        base = Path(folder)
        marker = base / "clicked.txt"
        fixture = base / "fixture.ps1"
        title = f"ComputerAgentSmoke-{os.getpid()}"
        fixture.write_text(r'''
Add-Type -AssemblyName PresentationFramework
$f=New-Object Windows.Window
$f.Title='TITLE'; $f.Width=420; $f.Height=220
$panel=New-Object Windows.Controls.StackPanel
$panel.Margin='20'
$t=New-Object Windows.Controls.TextBox
$t.Name='AgentInput'; $t.Height=28
$b=New-Object Windows.Controls.Button
$b.Content='AgentVerify'; $b.Height=35; $b.Margin='0,20,0,0'
$b.Add_Click({ [IO.File]::WriteAllText('MARKER',$t.Text) })
$null=$panel.Children.Add($t); $null=$panel.Children.Add($b)
$f.Content=$panel
$null=$f.ShowDialog()
'''.replace("TITLE", title).replace("MARKER", str(marker).replace("'", "''")), encoding="utf-8-sig")
        shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        proc = subprocess.Popen([shell, "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(fixture)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            hwnd = None
            for _ in range(5):
                rows = agent.execute("windows", {})["windows"]
                matches = [w for w in rows if w["title"] == title]
                if matches:
                    hwnd = matches[0]["hwnd"]
                    break
                if proc.poll() is not None:
                    raise RuntimeError("Fixture exited unexpectedly")
                time.sleep(0.3)
            assert hwnd, "Fixture window not found"
            tree = agent.execute("inspect", {"hwnd": hwnd})
            assert tree["controls"], "No UIA controls"
            print(json.dumps({"observed_controls": [{"name": c["name"], "type": c["control_type"]} for c in tree["controls"]]}), flush=True)
            agent.execute("wait", {"hwnd": hwnd, "selector": {"control_type": "ControlType.Edit"}, "timeout_ms": 2000})
            before = str(agent.ROOT / "artifacts" / "smoke-before.png")
            after = str(agent.ROOT / "artifacts" / "smoke-after.png")
            agent.execute("screenshot", {"hwnd": hwnd, "path": before})
            agent.execute("set_value", {"hwnd": hwnd, "selector": {"control_type": "ControlType.Edit"}, "value": "agent smoke passed"})
            agent.execute("invoke", {"hwnd": hwnd, "selector": {"name": "AgentVerify", "control_type": "ControlType.Button"}})
            assert marker.read_text() == "agent smoke passed", "UIA input/invoke did not produce expected result"
            agent.execute("screenshot", {"hwnd": hwnd, "path": after})
            diff = agent.execute("compare", {"before": before, "after": after, "stride": 2})
            assert diff["changed_ratio"] > 0, "No screenshot change detected"
            same = agent.execute("compare", {"before": after, "after": after})
            assert same["changed_ratio"] == 0
            # Exercise coordinate fallback only on this test window's own button.
            controls = agent.execute("inspect", {"hwnd": hwnd})["controls"]
            window = controls[0]["bounds"]
            button = next(c for c in controls if c["name"] == "AgentVerify")["bounds"]
            agent.execute("click", {"hwnd": hwnd, "x": int(button["x"] - window["x"] + button["width"] / 2), "y": int(button["y"] - window["y"] + button["height"] / 2)})
            print(json.dumps({"desktop_smoke": "passed", "controls": len(controls), "screenshot_changed_ratio": diff["changed_ratio"]}))
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    if "--desktop" in sys.argv:
        desktop_smoke()
    else:
        unittest.main()
