#!/usr/bin/env python3
"""Render the actual plugin QML with synthetic data in an offscreen window."""
import atexit, json, os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
work = Path(tempfile.mkdtemp(prefix="docker-monitor-preview-"))
atexit.register(shutil.rmtree, work, ignore_errors=True)
for name in ["Ui", "Commons", "services"]:
    shutil.copytree(SHELL / name, work / name)
shutil.copytree(ROOT, work / "Plugin", ignore=shutil.ignore_patterns(".git"))
# Replace only the platform window adapter; the plugin's UI stays intact.
(work / "Ui" / "KeyboardPanel.qml").write_text("""
import QtQuick
import Quickshell
import qs.Commons
FloatingWindow {
 id: root
 property var anchorItem
 property var owner
 property var bar
 property bool open: false
 property var focusTarget
 property int contentWidth: 480
 property int contentHeight: 560
 default property alias contents: body.data
 function fittedContentWidth(w) { return w }
 function fittedContentHeight(h, cap) { return Math.min(h + 40, cap) }
 implicitWidth: contentWidth + 40
 implicitHeight: contentHeight
 visible: open
 color: Color.background
 Rectangle {
   id: frame
   width: root.contentWidth + 40
   height: root.contentHeight
   color: Color.background
   border.color: Color.foreground
   border.width: 1
   Item { id: body; anchors.fill: parent; anchors.margins: 20 }
 }
 Timer {
   interval: 1200; running: root.open; repeat: false
   onTriggered: { frame.grabToImage(function(result) {
     if (!result.saveToFile(Qt.resolvedUrl("OUTPUT").toString().replace("file://", ""))) Qt.exit(1)
     else Qt.quit()
   }, Qt.size(frame.width * 2, frame.height * 2)); }
 }
}
""")
# Static demo: disable timers, Docker commands and preference loading in this copy.
p = work / "Plugin" / "Panel.qml"
s = p.read_text().replace('running: root.opened', 'running: false')
s = s.replace('Component.onCompleted: refresh()', 'Component.onCompleted: {}')
s = s.replace('if (!refreshProc.running) refreshProc.running = true', 'return')
s = s.replace('path: Quickshell.env("HOME") + "/.config/omarchy/rohirik-docker-monitor.json"', 'path: "/dev/null"')
s = s.replace('ipcTarget: "rohirik.docker-monitor"', 'ipcTarget: ""')
p.write_text(s)

containers = []
for project, service, image, cpu, mem, ip in [
 ("beszel", "hub", "henrygd/beszel:latest", "0.4%", 48, "172.18.0.2"),
 ("infisical", "app", "infisical/infisical:latest", "1.8%", 420, "172.19.0.2"),
 ("infisical", "postgres", "postgres:16", "0.3%", 128, "172.19.0.3"),
 ("infisical", "redis", "redis:7", "0.1%", 32, "172.19.0.4"),
 ("n8n", "app", "n8nio/n8n:latest", "2.1%", 512, "172.20.0.2"),
 ("traefik", "proxy", "traefik:v3", "0.2%", 64, "172.21.0.2"),
]:
    containers.append(dict(id="demo" + str(len(containers)), name=f"{project}-{service}-1",
        project=project, service=service, image=image, status="running", health="healthy",
        restarts=0, memLimitBytes=1073741824, cpuPercent=cpu, memUsageBytes=mem*1048576,
        urls=[f"https://{project}.example.com"] if service in ["hub", "app", "proxy"] else [],
        internalAddresses=[dict(network=f"{project}_default", address=ip)]))
demo = json.dumps(containers)
adapter = (work / "Ui" / "KeyboardPanel.qml").read_text()
for view in ["groups", "group", "container", "settings"]:
    out = ROOT / "docs" / (view + ".png")
    out.unlink(missing_ok=True)
    (work / "Ui" / "KeyboardPanel.qml").write_text(adapter.replace("OUTPUT", str(out)))
    selection = ''
    if view != "groups":
        selection += 'plugin.openGroup("project:infisical");'
    if view in ["container", "settings"]:
        selection += 'plugin.activateRow(plugin.containers[1]);'
    if view == "settings":
        selection += 'plugin.containerTab = "settings"; plugin.openEditor(plugin.selectedContainer);'
    (work / "shell.qml").write_text("""
import QtQuick
import Quickshell
import qs.Commons
import "Plugin" as Plugin
ShellRoot {
 QtObject {
  id: fakeBar
  property color foreground: Color.foreground
  property color barForeground: Color.foreground
  property color background: Color.background
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool vertical: false
  property int barSize: 32
  property string position: "top"
  property bool foregroundAnimationEnabled: false
  function hideTooltip() {}
  function showTooltip() {}
  function registerClickTarget() {}
  function unregisterClickTarget() {}
 }
 Plugin.Panel { id: plugin; bar: fakeBar }
 Timer {
  interval: 200; running: true; repeat: false
  onTriggered: {
    plugin.open();
    plugin.containers = DATA;
    plugin.dockerAvailable = true;
    plugin.hostMemBytes = 34359738368;
    plugin.hostStats = {cpu: 12.4, used: 9663676416, total: 34359738368};
    var history = {};
    plugin.containers.concat(plugin.groups).forEach(function(c) {
      var samples = [];
      for (var i = 0; i < 40; i++)
        samples.push({time: i * 3000, cpu: parseFloat(c.cpuPercent) * (0.6 + 0.4 * Math.sin(i * 0.7)),
                      mem: c.memUsageBytes * (0.88 + i * 0.003)});
      history[c.key || c.id] = samples;
    });
    plugin.history = history;
    SELECTION
    plugin.notice = "";
  }
 }
}
""".replace("DATA", demo).replace("SELECTION", selection))
    runtime = work / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="basic",
               QT_QUICK_BACKEND="software", QT_SCALE_FACTOR="1", XDG_RUNTIME_DIR=str(runtime))
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    result = subprocess.run(["quickshell", "-p", str(work), "--no-color"], env=env,
                            capture_output=True, text=True, timeout=20)
    if result.returncode or not out.exists():
        raise SystemExit(result.stdout + result.stderr)
    print(out)
shutil.copy2(ROOT / "docs" / "groups.png", ROOT / "preview.png")
shutil.rmtree(work)
