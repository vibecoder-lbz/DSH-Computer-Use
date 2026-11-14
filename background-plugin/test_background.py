import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import computer_agent as agent

# This fixture never requests activation or places a window on the visible desktop.
with tempfile.TemporaryDirectory(prefix='background-fixture-') as folder:
    base = Path(folder)
    marker = base / 'result.txt'
    title = f'DshBackgroundFixture-{os.getpid()}'
    source = r'''
Add-Type -AssemblyName PresentationFramework
$f=New-Object Windows.Window
$f.Title='TITLE'; $f.Width=400; $f.Height=200
$f.ShowActivated=$false; $f.ShowInTaskbar=$false
$f.Left=-20000; $f.Top=-20000
$panel=New-Object Windows.Controls.StackPanel
$t=New-Object Windows.Controls.TextBox
$t.Height=35
$b=New-Object Windows.Controls.Button
$b.Content='BackgroundVerify'; $b.Height=40
$b.Add_Click({ [IO.File]::WriteAllText('MARKER',$t.Text) })
$null=$panel.Children.Add($t); $null=$panel.Children.Add($b)
$f.Content=$panel
$null=$f.ShowDialog()
'''.replace('TITLE', title).replace('MARKER', str(marker).replace("'", "''"))
    fixture = base / 'fixture.ps1'
    fixture.write_text(source, encoding='utf-8-sig')
    shell = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
    proc = subprocess.Popen([shell, '-NoProfile', '-STA', '-File', str(fixture)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        hwnd = None
        for _ in range(5):
            windows = agent.execute('windows', {})['windows']
            matches = [w for w in windows if w['title'] == title]
            if matches:
                hwnd = matches[0]['hwnd']; break
            time.sleep(0.1)
        assert hwnd, 'No background fixture window'
        tree = agent.execute('inspect', {'hwnd': hwnd})
        observations = [tree['background_observation']]
        for action, params in [
            ('apps', {'limit': 2}),
            ('wait', {'hwnd': hwnd, 'selector': {'name': 'BackgroundVerify', 'control_type': 'ControlType.Button'}}),
            ('screenshot', {'hwnd': hwnd, 'path': str(agent.ROOT / 'artifacts/background-fixture.png')}),
        ]:
            result = agent.execute(action, params)
            print(json.dumps({'action': action, 'observation': result['background_observation']}), flush=True)
            observations.append(result['background_observation'])
        assert not marker.exists(), 'Read-only operations must not trigger the button'
        for obs in observations:
            assert obs['foreground_unchanged'], obs
            assert obs['cursor_unchanged'], obs
        for action, params in [('click', {'hwnd': hwnd, 'x': 1, 'y': 1}), ('launch', {'path': shell}), ('invoke', {'hwnd': hwnd, 'selector': {'name': 'BackgroundVerify'}}), ('set_value', {'hwnd': hwnd, 'selector': {'control_type': 'ControlType.Edit'}, 'value': 'blocked'}), ('select', {'hwnd': hwnd, 'selector': {'name': 'BackgroundVerify'}}), ('screenshot', {})]:
            assert not agent.respond({'action': action, 'params': params})['ok']
        print(json.dumps({'background_fixture': 'passed', 'operations': 4, 'foreground_unchanged': True, 'cursor_unchanged': True, 'foreground_fallbacks_blocked': True}))
    finally:
        if proc.poll() is None: proc.terminate()
        proc.wait(timeout=10)
