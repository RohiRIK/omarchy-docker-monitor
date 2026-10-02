import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "rohirik.docker-monitor"
  ipcTarget: "rohirik.docker-monitor"

  property bool dockerAvailable: false
  property string dockerVersion: ""
  property double hostMemBytes: 0
  property var containers: []

  property var preferences: ({ assignments: {}, aliases: {}, urls: {} })
  property var history: ({})
  property string notice: ""
  property bool noticeError: false
  property var editRow: null
  property string logsName: ""
  property string logsId: ""
  property string logsText: ""
  // Merged logs for every container in the open group, one color per container.
  property bool groupLogsOpen: false
  property bool groupLogsLive: false
  property var groupLogLines: []
  property var groupLogHidden: ({})
  property string groupLogNote: ""
  property var logPalette: Model.logPalette("")
  // Compose projects that can be started: found under projectDirs, plus the
  // ones Docker has containers for. Only inactive ones are listed.
  property var projects: []
  property string startingProject: ""
  readonly property var projectDirs: {
    var dirs = setting("projectDirs", ["~"])
    return (Array.isArray(dirs) ? dirs : [dirs]).map(function(d) {
      return String(d).replace(/^~(?=\/|$)/, Quickshell.env("HOME"))
    })
  }
  readonly property var availableProjects: Model.availableProjects(projects, containers)
  property bool savingPreferences: false

  // Match service identity as well as the display name, so aliases keep their icon.
  function serviceIcon(row) {
    var members = row.containers || [row]
    var identity = [row.key || "", row.name || ""].concat(members.map(function(c) {
      return [c.project || "", c.service || "", c.image || ""].join(" ")
    })).join(" ").toLowerCase()
    var icons = [
      { pattern: /beszel|prometheus|grafana|netdata|uptime-kuma/, glyph: "\uf201" },
      { pattern: /infisical|vault|authentik|keycloak|authelia/, glyph: "\uf023" },
      { pattern: /traefik|nginx|caddy|haproxy/, glyph: "\uf0e8" },
      { pattern: /n8n|node-red|activepieces/, glyph: "\uf0e7" },
      { pattern: /postgres|mysql|mariadb|mongo|redis|valkey/, glyph: "\uf1c0" }
    ]
    for (var i = 0; i < icons.length; i++) {
      if (icons[i].pattern.test(identity)) return icons[i].glyph
    }
    return "\uf308"
  }

  property var hostStats: ({})

  // All Docker access goes through this helper: it enforces an overall deadline
  // and per-stream byte limits, so Docker output reaching the shell stays small.
  // The outer timeout is a backstop in case the helper itself stalls.
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("docker-helper.py").toString().replace("file://", ""))
  function helperCommand(seconds, args) {
    return ["timeout", "-k", "2", String(seconds), "python3", helperPath].concat(args)
  }
  function helperResult(text) {
    try {
      var result = JSON.parse(text)
      if (result && typeof result.code === "number" && typeof result.text === "string") return result
    } catch (e) {}
    return { code: 1, text: "" }
  }

  Process {
    id: hostStatsProc
    command: ["python3", Qt.resolvedUrl("host-stats.py").toString().replace("file://", "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.hostStats = JSON.parse(text) }
        catch (e) { root.hostStats = {} }
      }
    }
  }

  Timer {
    interval: root.refreshMs
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!hostStatsProc.running) hostStatsProc.running = true
  }

  // What answers on each published port: target -> {kind, status, type, at}.
  // Probed in the background; results older than a minute are re-checked so
  // a service that was still booting gets its link once it is up.
  property var probes: ({})
  readonly property int probeMaxAgeMs: 60000

  function scheduleProbes() {
    if (probeProc.running) return
    var now = Date.now(), targets = []
    containers.forEach(function(c) {
      if (c.status !== "running") return
      ;(c.publishedPorts || []).forEach(function(p) {
        var known = probes[p.target]
        if ((!known || now - known.at > probeMaxAgeMs) && targets.indexOf(p.target) < 0) targets.push(p.target)
      })
    })
    if (!targets.length) return
    probeProc.command = root.helperCommand(8, ["probe"].concat(targets.slice(0, 64)))
    probeProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(code, status) {
      var data = null
      try { data = JSON.parse(probeOut.text) } catch (e) {}
      if (!data || !Array.isArray(data.probes)) return
      var next = {}, now = Date.now()
      for (var key in root.probes) next[key] = root.probes[key]
      data.probes.forEach(function(p) {
        if (p && typeof p.target === "string")
          next[p.target] = { kind: String(p.kind || ""), status: Number(p.status) || 0, type: String(p.type || ""), at: now }
      })
      root.probes = next
      root.containers = Model.applyProbes(root.containers, next)
    }
  }

  // Button text for a service link: the service name on a group page,
  // host:port when a container has several links.
  function linkLabel(row, url) {
    if (row.isGroup) {
      var owner = (row.containers || []).find(function(c) { return Model.containerUrls(c, preferences).indexOf(url) >= 0 })
      var port = /:(\d+)\/?$/.exec(url)
      return "Open " + (owner ? (owner.service || owner.name) : url.replace(/^https?:\/\//, "")) +
          (owner && port && row.urls.length > 1 ? " :" + port[1] : "") + " ↗"
    }
    return urlsFor(row).length === 1 ? "Open service ↗" : "Open " + url.replace(/^https?:\/\//, "") + " ↗"
  }

  function urlsFor(row) {
    return row.isGroup ? row.urls : Model.containerUrls(row, preferences)
  }

  function openEditor(row) {
    editRow = row
    groupField.text = row.isGroup ? row.name : ((preferences.assignments || {})[row.name] || "")
    urlField.text = row.isGroup ? "" : ((preferences.urls || {})[row.name] || "")
    keyCatcher.forceActiveFocus()
    scrollArea.contentItem.contentY = 0
  }

  function saveEditor() {
    var url = urlField.text.trim()
    if (!editRow.isGroup && url && !Model.safeUrl(url)) {
      notice = "Enter a full http:// or https:// address."
      noticeError = true
      return
    }
    var next = JSON.parse(JSON.stringify(preferences))
    next.assignments = next.assignments || {}
    next.aliases = next.aliases || {}
    next.urls = next.urls || {}
    var name = groupField.text.trim()
    if (editRow.isGroup) {
      if (name) next.aliases[editRow.key] = name
      else delete next.aliases[editRow.key]
    } else {
      if (name) next.assignments[editRow.name] = name
      else delete next.assignments[editRow.name]
      if (url) next.urls[editRow.name] = url
      else delete next.urls[editRow.name]
    }
    preferences = next
    var serialized = JSON.stringify(next, null, 2) + "\n"
    if (preferencesFile.text() === serialized) {
      notice = "Custom settings saved."
      noticeError = false
    } else {
      savingPreferences = true
      preferencesFile.setText(serialized)
    }
    editRow = null
    keyCatcher.forceActiveFocus()
  }

  function runAction(action, row) {
    if (actionProc.running) return
    var command = Model.actionCommand(action, row)
    if (!command.length) return
    actionProc.label = action + " · " + row.name
    actionProc.command = root.helperCommand(55, ["action"].concat(command.slice(1)))
    noticeError = false
    notice = "Working: " + actionProc.label
    actionProc.running = true
  }

  // Opens the user's default agent (omarchy agent prompt) in its own terminal.
  // Stock omarchy-agent-prompt has no read-only / plan-mode flag (only --inline
  // and the prompt); it always launches the default agent with that agent's
  // unattended auto-approve spelling. Do not invent per-agent permission argv
  // here — when Omarchy gains a read-only launch API, switch this call site.
  function askAgent(row) {
    var prompt = Model.agentPrompt(row)
    if (!prompt) return
    Quickshell.execDetached(["omarchy-agent-prompt", prompt])
    root.close()
  }

  function showLogs(c) {
    if (logsProc.running) return
    logsName = c.name
    logsId = c.id
    logsText = "Loading…"
    logsProc.command = root.helperCommand(15, ["logs", c.id])
    logsProc.running = true
  }

  function groupLogMembers() {
    return selectedGroup ? selectedGroup.containers : []
  }

  function groupLogColor(name) {
    var names = groupLogMembers().map(function(c) { return c.name })
    return Model.logColor(logPalette, Math.max(0, names.indexOf(name)))
  }

  function groupLogLabel(name) {
    var c = groupLogMembers().find(function(item) { return item.name === name })
    return (c && c.service) || name
  }

  function openGroupLogs() {
    groupLogsOpen = true
    groupLogLines = []
    groupLogNote = ""
    scrollArea.contentItem.contentY = 0
    showGroupLogs()
  }

  function closeGroupLogs() {
    groupLogsOpen = false
    groupLogsLive = false
    keyCatcher.forceActiveFocus()
  }

  // Hidden containers are left out of the fetch, so the line budget goes to
  // the ones being watched instead of being filled by a chatty neighbour.
  function showGroupLogs() {
    if (groupLogsProc.running || !groupLogsOpen) return
    var shown = groupLogMembers().filter(function(c) {
      return !groupLogHidden[c.name] && /^[a-f0-9]{12,64}$/.test(c.id)
    })
    if (shown.length === 0) {
      groupLogLines = []
      groupLogNote = "All containers are hidden. Select one above to show its logs."
      return
    }
    groupLogsProc.members = shown.map(function(c) { return c.name })
    groupLogsProc.command = root.helperCommand(15, ["grouplogs"].concat(shown.map(function(c) { return c.id })))
    groupLogsProc.running = true
  }

  function toggleGroupLogContainer(name) {
    var next = {}
    for (var key in groupLogHidden) next[key] = groupLogHidden[key]
    if (next[name]) delete next[name]
    else next[name] = true
    groupLogHidden = next
    showGroupLogs()
  }

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.logPalette = Model.logPalette(text())
    onFileChanged: reload()
  }

  Process {
    id: groupLogsProc
    property var members: []
    stdout: StdioCollector { id: groupLogsOut; waitForEnd: true }
    onExited: function(code, status) {
      var data = null
      try { data = JSON.parse(groupLogsOut.text) } catch (e) {}
      var raw = data && Array.isArray(data.lines) ? data.lines : []
      var names = members
      var lines = []
      raw.forEach(function(entry) {
        if (!Array.isArray(entry) || typeof entry[0] !== "number" || names[entry[0]] === undefined) return
        lines.push({ name: names[entry[0]], time: String(entry[1] || ""), text: String(entry[2] || "") })
      })
      var follow = groupLogList.count === 0 || groupLogList.atYEnd
      root.groupLogLines = lines
      root.groupLogNote = data && typeof data.text === "string" ? data.text :
          (code ? "Docker logs failed or timed out." : "")
      if (lines.length === 0 && !root.groupLogNote) root.groupLogNote = "No logs available."
      if (follow) Qt.callLater(function() { groupLogList.positionViewAtEnd() })
    }
  }

  Timer {
    interval: Math.max(2000, root.refreshMs)
    running: root.opened && root.groupLogsOpen && root.groupLogsLive
    repeat: true
    onTriggered: root.showGroupLogs()
  }

  FileView {
    id: preferencesFile
    path: Quickshell.env("HOME") + "/.config/omarchy/rohirik-docker-monitor.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("Invalid preferences")
        root.preferences = data
      } catch (e) {
        root.notice = "Could not read saved custom groups: " + e
        root.noticeError = true
      }
    }
    onFileChanged: reload()
    onSaved: {
      if (!root.savingPreferences) return
      root.savingPreferences = false
      root.notice = "Custom settings saved."
      root.noticeError = false
    }
    onSaveFailed: {
      root.savingPreferences = false
      root.notice = "Could not save custom settings."
      root.noticeError = true
    }
  }

  Process {
    id: actionProc
    property string label: ""
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function(code, status) {
      var result = root.helperResult(actionOut.text)
      var failed = code !== 0 || result.code !== 0
      root.noticeError = failed
      root.notice = failed ? "Failed: " + label + "\n" + (result.text || "Command timed out or failed.") :
          "Completed: " + label
      root.refresh()
      root.refreshProjects()
    }
  }

  Process {
    id: logsProc
    // The helper caps bytes read per stream, merges stdout/stderr by timestamp
    // and returns at most the newest 60,000 characters.
    stdout: StdioCollector { id: logsOut; waitForEnd: true }
    onExited: function(code, status) {
      var result = root.helperResult(logsOut.text)
      root.logsText = (result.text || (code ? "Docker logs failed or timed out." : "No logs available.")).slice(-60000)
    }
  }

  property string containerTab: "overview"
  readonly property var selectedContainer: containers.find(function(c) { return c.id === expandedContainerId }) || null
  readonly property bool containerPage: expandedContainerId !== ""
  readonly property var currentSubject: containerPage ? selectedContainer : selectedGroup
  property bool manageGroup: false
  property string expandedContainerId: ""

  function scrollToTop() { scrollArea.contentItem.contentY = 0; keyCatcher.forceActiveFocus() }

  function activateRow(row) {
    if (!row) return
    if (!detailPage) openGroup(row.key)
    else if (!row.isGroup && !containerPage) {
      expandedContainerId = row.id
      containerTab = "overview"
      selectedIndex = 0
      cursorActive = false
      scrollArea.contentItem.contentY = 0
      editRow = null
      logsName = ""
      groupLogsOpen = false
      groupLogsLive = false
    }
  }

  property string selectedGroupKey: ""
  readonly property var groups: Model.groupContainers(containers, preferences)
  readonly property var activeGroups: groups.filter(function(g) {
    return g.containers.some(function(c) {
      return ["running", "restarting", "paused"].indexOf(c.status) >= 0
    })
  })
  readonly property var selectedGroup: groups.find(function(g) { return g.key === selectedGroupKey }) || null
  readonly property bool detailPage: selectedGroupKey !== ""
  readonly property var rows: containerPage ? (selectedContainer ? [selectedContainer] : []) : (detailPage ? (selectedGroup ? (groupLogsOpen ? [selectedGroup] : [selectedGroup].concat(selectedGroup.containers)) : []) : activeGroups)

  function openGroup(key) {
    selectedGroupKey = key
    resetPage()
  }

  function resetPage() {
    containerTab = "overview"
    manageGroup = false
    expandedContainerId = ""
    editRow = null
    logsName = ""
    groupLogsOpen = false
    groupLogsLive = false
    selectedIndex = 0
    cursorActive = false
    notice = ""
    scrollArea.contentItem.contentY = 0
    keyCatcher.forceActiveFocus()
  }

  function goBack() {
    if (editRow) { editRow = null; keyCatcher.forceActiveFocus() }
    else if (logsName) { logsName = ""; keyCatcher.forceActiveFocus() }
    else if (groupLogsOpen) closeGroupLogs()
    else if (manageGroup) manageGroup = false
    else if (expandedContainerId) { expandedContainerId = ""; containerTab = "overview"; scrollArea.contentItem.contentY = 0 }
    else if (detailPage) { selectedGroupKey = ""; resetPage() }
    else close()
  }

  // Keyboard cursor over the container list.
  property int selectedIndex: 0
  property bool cursorActive: false

  // true while the user is dragging a slider — pauses the periodic refresh
  // so the model does not change underneath the pointer.
  property bool userInteracting: false

  // Local per-container limit preview (name -> MB) while the
  // `docker update` is still in flight; keeps the knob from snapping back.
  property var memOverrides: ({})

  // Queue of pending `docker update` jobs: [{name, mb}]. One Process at a time.
  property var pendingSets: []
  property string pendingKeyboardName: ""

  // Floor guards against a misconfigured refreshMs (0/negative would hammer
  // the daemon in a tight timer loop).
  readonly property int refreshMs: Math.max(500, setting("refreshMs", 3000))
  readonly property int hostMemMb: Math.max(16384, Math.round(hostMemBytes / 1048576))
  readonly property int memMin: 6
  readonly property int memStep: 128

  function containerLimitMb(c) {
    return c && c.memLimitBytes > 0 ? Math.round(c.memLimitBytes / 1048576) : 0
  }

  // Effective limit shown: local override > real limit > host RAM
  // (container with no configured limit).
  function effectiveMb(c) {
    if (!c) return memMin
    var override = memOverrides[c.name]
    if (override !== undefined) return override
    var limit = containerLimitMb(c)
    return limit > 0 ? limit : hostMemMb
  }

  function setOverride(name, mb) {
    var next = {}
    for (var key in memOverrides) next[key] = memOverrides[key]
    next[name] = mb
    memOverrides = next
  }

  function clearOverride(name) {
    if (memOverrides[name] === undefined) return
    var next = {}
    for (var key in memOverrides) if (key !== name) next[key] = memOverrides[key]
    memOverrides = next
  }

  // Drops pending overrides for containers that are no longer listed, so a
  // removed container cannot keep a stale limit preview behind in the slider.
  function pruneOverrides(names) {
    var next = {}
    for (var key in memOverrides) {
      if (names.indexOf(key) >= 0) next[key] = memOverrides[key]
    }
    if (Object.keys(next).length !== Object.keys(memOverrides).length) memOverrides = next
  }

  function refresh() {
    if (!refreshProc.running) refreshProc.running = true
  }

  // Applies `docker update --memory <mb>m`. --memory-swap -1 follows along so the
  // daemon rejects limits larger than the currently configured swap.
  function setMemory(name, mb) {
    if (!name) return
    var clamped = Model.clampMemMb(mb, hostMemMb)
    setOverride(name, clamped)

    var queue = pendingSets.slice()
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].name === name) {
        queue[i].mb = clamped
        pendingSets = queue
        startNextSet()
        return
      }
    }
    queue.push({ name: name, mb: clamped })
    pendingSets = queue
    startNextSet()
  }

  function startNextSet() {
    if (setProc.running || pendingSets.length === 0) return
    var job = pendingSets[0]
    pendingSets = pendingSets.slice(1)
    setProc.jobName = job.name
    setProc.command = root.helperCommand(55, ["memory", job.name, String(job.mb)])
    setProc.running = true
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > rows.length - 1) next = rows.length - 1
    selectedIndex = next
  }

  function clampCursor() {
    if (rows.length === 0) {
      selectedIndex = 0
      return
    }
    if (selectedIndex > rows.length - 1) selectedIndex = rows.length - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function adjustSelectedMem(deltaSteps) {
    if (selectedIndex < 0 || selectedIndex >= rows.length) return
    var c = rows[selectedIndex]
    if (containerTab !== "settings" || !c || c.isGroup || c.id !== expandedContainerId || c.status !== "running") return
    var next = Model.clampMemMb(effectiveMb(c) + deltaSteps * memStep, hostMemMb)
    setOverride(c.name, next)
    pendingKeyboardName = c.name
    memDebounce.restart()
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  function refreshProjects() {
    if (projectsProc.running) return
    projectsProc.command = root.helperCommand(12, ["projects"].concat(projectDirs))
    projectsProc.running = true
  }

  function startProject(project) {
    if (startProc.running || !project || !project.available) return
    startingProject = project.name
    noticeError = false
    notice = "Starting " + project.name + "…"
    startProc.command = root.helperCommand(615, ["up"].concat(project.files))
    startProc.running = true
  }

  Process {
    id: projectsProc
    stdout: StdioCollector { id: projectsOut; waitForEnd: true }
    onExited: function(code, status) {
      var data = null
      try { data = JSON.parse(projectsOut.text) } catch (e) {}
      if (data && Array.isArray(data.projects)) root.projects = data.projects
    }
  }

  Process {
    id: startProc
    stdout: StdioCollector { id: startOut; waitForEnd: true }
    onExited: function(code, status) {
      var result = root.helperResult(startOut.text)
      var failed = code !== 0 || result.code !== 0
      root.noticeError = failed
      root.notice = failed ? "Could not start " + root.startingProject + "\n" + (result.text || "docker compose up failed or timed out.") :
          "Started " + root.startingProject
      root.startingProject = ""
      root.refresh()
      root.refreshProjects()
    }
  }

  onOpenedChanged: {
    if (opened) {
      selectedGroupKey = ""
      resetPage()
      refresh()
      refreshProjects()
      selectedIndex = 0
      cursorActive = false
    }
  }

  onRowsChanged: clampCursor()

  Timer {
    interval: root.refreshMs
    running: root.opened
    repeat: true
    onTriggered: if (!root.userInteracting && !root.editRow) root.refresh()
  }

  Process {
    id: refreshProc
    command: root.helperCommand(20, ["snapshot"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var snap = Model.parseSnapshot(String(text || ""))
        root.dockerAvailable = snap.dockerAvailable
        root.dockerVersion = snap.dockerVersion
        root.hostMemBytes = snap.hostMemBytes
        root.history = Model.addHistory(root.history, snap.containers, root.preferences, Date.now())
        root.containers = Model.applyProbes(snap.containers, root.probes)
        root.scheduleProbes()
        if (snap.error) { root.notice = snap.error; root.noticeError = true }
        root.pruneOverrides(snap.containers.map(function(c) { return c.name }))
      }
    }
  }

  Process {
    id: setProc
    property string jobName: ""
    property string finishedName: ""
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) {
        finishedName = jobName
        return
      }
      root.clearOverride(finishedName)
      root.startNextSet()
      root.refresh()
    }
  }

  // Debounce for keyboard (h/l) adjustments.
  Timer {
    id: memDebounce
    interval: 300
    repeat: false
    onTriggered: {
      var c = root.containers.find(function(item) { return item.name === root.pendingKeyboardName })
      if (!c) return
      root.setMemory(c.name, root.effectiveMb(c))
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf308"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.groupLogsOpen ? 800 : (root.detailPage ? 480 : 380)))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight + fixedHeader.height, Style.space(root.groupLogsOpen ? 760 : 560))

    PanelKeyCatcher {
      id: keyCatcher
      blocked: groupField.activeFocus || urlField.activeFocus || logArea.activeFocus
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustSelectedMem(dx)
      }
      onActivateRequested: {
        var row = root.rows[root.selectedIndex]
        if (root.cursorActive) root.activateRow(row)
      }
      onCloseRequested: root.goBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refresh() }

      Column {
        id: fixedHeader
        visible: root.detailPage
        width: parent.width
        height: visible ? implicitHeight + Style.space(14) : 0
        spacing: Style.space(10)
        Item {
          width: parent.width
          implicitHeight: headerTitle.implicitHeight + headerStatus.implicitHeight + Style.space(8)
          MonitorButton {
            id: backButton
            text: "‹"
            tooltipText: root.containerPage ? "Back to group" : "Back to groups"
            anchors.left: parent.left
            onClicked: {
              root.editRow = null
              root.logsName = ""
              root.closeGroupLogs()
              if (root.containerPage) {
                root.expandedContainerId = ""
                root.containerTab = "overview"
                root.selectedIndex = 0
                root.scrollToTop()
              } else { root.selectedGroupKey = ""; root.resetPage() }
            }
          }
          Text {
            id: headerTitle
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(10)
            anchors.right: moreButton.left
            anchors.rightMargin: Style.space(10)
            text: root.currentSubject ? root.serviceIcon(root.currentSubject) + "  " + root.currentSubject.name : "Unavailable"
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: headerStatus
            anchors.left: headerTitle.left
            anchors.right: headerTitle.right
            anchors.top: headerTitle.bottom
            anchors.topMargin: Style.space(5)
            text: root.currentSubject ? (root.containerPage ? Model.healthText(root.currentSubject) : root.currentSubject.summary) : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.currentSubject && Model.needsAttention(root.currentSubject) ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          MonitorButton {
            id: moreButton
            anchors.right: parent.right
            text: "⋯"
            tooltipText: root.containerPage ? "Container actions" : "Group actions"
            enabled: root.currentSubject !== null
            onClicked: actionsMenu.popup()
            Menu {
              id: actionsMenu
              palette.window: Color.background
              palette.windowText: root.bar.foreground
              MenuItem {
                text: "Start"
                enabled: !actionProc.running && Model.actionCommand("start", root.currentSubject).length > 0
                onTriggered: root.runAction("start", root.currentSubject)
              }
              MenuItem {
                text: "Restart"
                enabled: !actionProc.running && Model.actionCommand("restart", root.currentSubject).length > 0
                onTriggered: root.runAction("restart", root.currentSubject)
              }
              MenuItem {
                text: "Stop"
                enabled: !actionProc.running && Model.actionCommand("stop", root.currentSubject).length > 0
                onTriggered: root.runAction("stop", root.currentSubject)
              }
              MenuItem {
                visible: !root.containerPage
                height: visible ? implicitHeight : 0
                text: "Rename group"
                onTriggered: root.openEditor(root.currentSubject)
              }
            }
          }
        }
        Row {
          visible: root.containerPage
          spacing: Style.space(8)
          MonitorButton {
            text: "Overview"
            enabled: root.containerTab !== "overview"
            onClicked: { root.containerTab = "overview"; root.editRow = null; root.scrollToTop() }
          }
          MonitorButton {
            text: "Settings"
            enabled: root.containerTab !== "settings"
            onClicked: {
              root.containerTab = "settings"
              root.logsName = ""
              root.openEditor(root.selectedContainer)
            }
          }
        }
        PanelSeparator { foreground: root.bar.foreground }
      }

      ScrollView {
        id: scrollArea
        anchors.top: fixedHeader.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(root.detailPage ? 14 : 4)

          Item {
            visible: !root.detailPage
            width: parent.width
            implicitHeight: hostSummary.implicitHeight + Style.space(16)

            Text {
              id: hostSummary
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "Host   CPU " + (root.hostStats.cpu === undefined || root.hostStats.cpu === null ? "—" : root.hostStats.cpu + "%") +
                    " · RAM " + (root.hostStats.total > 0 ?
                      (root.hostStats.used / 1073741824).toFixed(1) + " / " +
                      (root.hostStats.total / 1073741824).toFixed(1) + " GiB" : "—")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            MouseArea {
              id: hostHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }
            PanelToolTip {
              visible: hostHover.containsMouse
              text: "Whole machine · CPU across all cores · RAM excludes available cache"
              fontFamily: root.bar.fontFamily
            }
          }

          PanelSeparator {
            visible: !root.detailPage
            foreground: root.bar.foreground
          }

          Text {
            textFormat: Text.PlainText
            visible: root.dockerAvailable && root.rows.length === 0
            width: parent.width
            text: root.detailPage ? "This group is no longer available." :
                (root.availableProjects.length ? "Nothing running" : "No active Docker groups. Set projectDirs to find Compose projects to start.")
            wrapMode: Text.WordWrap
            leftPadding: root.detailPage ? 0 : Style.space(10)
            rightPadding: leftPadding
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---------- Docker unavailable ----------
          PanelSeparator {
            visible: !root.dockerAvailable
            foreground: root.bar.foreground
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.dockerAvailable
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Could not reach the Docker daemon. Make sure it is running and that your user is in the docker group."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: root.notice !== "" && (root.detailPage || root.noticeError)
            width: parent.width
            text: root.notice
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.noticeError ? root.bar.urgent : root.bar.foreground
            font.pixelSize: Style.font.caption
          }

          Column {
            visible: root.editRow !== null
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: root.editRow ? "Customize · " + root.editRow.name : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.bar.foreground
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.editRow && root.editRow.isGroup ? "Group display name (blank restores the original)" :
                    "Custom group (use the same name to combine containers; blank uses Compose)"
              wrapMode: Text.Wrap
              color: root.bar.foreground
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: groupField
              width: parent.width
              color: root.bar.foreground
              placeholderText: "Group name"
              maximumLength: 100
              background: Rectangle { color: Qt.alpha(root.bar.foreground, 0.08); border.color: Qt.alpha(root.bar.foreground, 0.3); radius: 4 }
              Keys.onEscapePressed: { root.editRow = null; keyCatcher.forceActiveFocus() }
              onAccepted: root.saveEditor()
            }
            Text {
              textFormat: Text.PlainText
              visible: root.editRow !== null && !root.editRow.isGroup
              text: "Service URL override (blank uses detected links)"
              color: root.bar.foreground
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: urlField
              visible: root.editRow !== null && !root.editRow.isGroup
              width: parent.width
              color: root.bar.foreground
              placeholderText: "https://service.example.com"
              maximumLength: 2048
              background: Rectangle { color: Qt.alpha(root.bar.foreground, 0.08); border.color: Qt.alpha(root.bar.foreground, 0.3); radius: 4 }
              Keys.onEscapePressed: { root.editRow = null; keyCatcher.forceActiveFocus() }
              onAccepted: root.saveEditor()
            }
            Row {
              spacing: Style.space(8)
              MonitorButton { text: "Save"; onClicked: root.saveEditor() }
              MonitorButton { text: "Cancel"; onClicked: { root.editRow = null; keyCatcher.forceActiveFocus() } }
            }
          }

          MonitorButton {
            visible: root.containerPage && root.containerTab === "settings" && !root.editRow && root.selectedContainer !== null
            text: "Edit group & URL"
            onClicked: root.openEditor(root.selectedContainer)
          }

          // ---------- Containers ----------
          Repeater {
            model: root.rows

            delegate: CursorSurface {
              id: containerRow
              required property var modelData
              required property int index

              readonly property var container: modelData
              readonly property bool expanded: !container.isGroup && root.expandedContainerId === container.id

              width: panelColumn.width
              implicitHeight: rowColumn.implicitHeight + (root.detailPage ? Style.spacing.xl : Style.space(20))
              hasCursor: root.cursorActive && root.selectedIndex === index
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(containerRow)
              foreground: root.bar.foreground
              fill: Style.hoverFillFor(root.bar.foreground, Color.accent)

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(containerRow.container.isGroup ? 10 : 22)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  visible: root.detailPage && !root.containerPage && containerRow.index === 1
                  text: "Containers"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  bottomPadding: Style.space(6)
                }

                // Row 1: status dot · name · cpu/mem
                Item {
                  id: rowHeader
                  visible: !root.containerPage || root.containerTab === "overview"
                  width: parent.width
                  implicitHeight: nameText.implicitHeight + (root.detailPage ? 0 : usageRow.implicitHeight + Style.space(5))

                  Text {
                    id: statusDot
                    textFormat: Text.PlainText
                    visible: root.detailPage
                    text: "●"
                    color: Model.needsAttention(containerRow.container) ? root.bar.urgent : (containerRow.container.status === "running" ? Color.accent : Qt.darker(root.bar.foreground, 1.6))
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: serviceGlyph
                    textFormat: Text.PlainText
                    visible: !root.detailPage
                    text: root.serviceIcon(containerRow.container)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    width: Style.space(20)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.left: parent.left
                    anchors.top: parent.top
                  }

                  Text {
                    id: nameText
                    textFormat: Text.PlainText
                    text: root.detailPage && (containerRow.container.isGroup || root.containerPage) ? "Usage" : containerRow.container.name
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    anchors.left: root.detailPage ? statusDot.right : serviceGlyph.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: root.detailPage ? statsText.left : rowIndicators.left
                    anchors.rightMargin: Style.space(8)
                    anchors.top: parent.top
                  }

                  Text {
                    id: statsText
                    textFormat: Text.PlainText
                    visible: root.detailPage
                    text: {
                      if (!root.detailPage) return "CPU " + (containerRow.container.cpuPercent || "—") + " · RAM " + Model.formatBytes(containerRow.container.memUsageBytes)
                      var c = containerRow.container
                      var parts = []
                      if (c.cpuPercent !== "") parts.push("CPU " + c.cpuPercent)
                      if (c.memUsageBytes > 0) parts.push(Model.formatBytes(c.memUsageBytes))
                      return parts.join(" · ")
                    }
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.right: root.detailPage ? parent.right : undefined
                    anchors.left: root.detailPage ? undefined : parent.left
                    anchors.bottom: parent.bottom
                  }
                  Row {
                    id: rowIndicators
                    visible: !root.detailPage
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Style.space(8)
                    Text {
                      textFormat: Text.PlainText
                      visible: Model.needsAttention(containerRow.container)
                      text: "!"
                      color: "#e5b567"
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "›"
                      opacity: groupMouse.containsMouse || containerRow.hasCursor ? 1 : 0
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }

                  Row {
                    id: usageRow
                    visible: !root.detailPage
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: Style.space(18)
                    Repeater {
                      model: ["CPU", "RAM"]
                      delegate: Item {
                        required property string modelData
                        width: (usageRow.width - usageRow.spacing) / 2
                        implicitHeight: usageLabel.implicitHeight
                        Text {
                          id: usageLabel
                          textFormat: Text.PlainText
                          text: modelData
                          anchors.left: parent.left
                          color: Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          textFormat: Text.PlainText
                          text: modelData === "CPU" ? (containerRow.container.cpuPercent || "—") :
                                (containerRow.container.statsCount > 0 ? Model.formatBytes(containerRow.container.memUsageBytes) : "—")
                          anchors.right: parent.right
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.containerPage && (!root.detailPage || !containerRow.container.isGroup)
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                      root.selectedIndex = containerRow.index
                      root.activateRow(containerRow.container)
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: root.detailPage && !root.containerPage && !containerRow.container.isGroup
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: containerRow.container.isGroup ? containerRow.container.summary :
                        Model.healthText(containerRow.container) + " · " + (containerRow.container.restarts || 0) + " restarts"
                  color: Model.needsAttention(containerRow.container) ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.25)
                  font.pixelSize: Style.font.caption
                }

                Row {
                  width: parent.width
                  spacing: Style.space(12)
                  visible: root.detailPage && (containerRow.container.isGroup || (root.containerPage && root.containerTab === "overview"))
                  HistoryGraph {
                    width: (parent.width - parent.spacing) / 2
                    metric: "cpu"
                    foreground: root.bar.foreground
                    samples: root.history[containerRow.container.isGroup ? containerRow.container.key : containerRow.container.id] || []
                  }
                  HistoryGraph {
                    width: (parent.width - parent.spacing) / 2
                    metric: "mem"
                    foreground: root.bar.foreground
                    samples: root.history[containerRow.container.isGroup ? containerRow.container.key : containerRow.container.id] || []
                  }
                }

                Flow {
                  visible: root.detailPage && (containerRow.container.isGroup || (root.containerPage && root.containerTab === "overview"))
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: root.urlsFor(containerRow.container)
                    delegate: MonitorButton {
                      required property string modelData
                      text: root.linkLabel(containerRow.container, modelData)
                      tooltipText: modelData
                      onClicked: Qt.openUrlExternally(modelData)
                    }
                  }
                  MonitorButton {
                    visible: root.detailPage && !root.containerPage && containerRow.container.isGroup
                    text: root.groupLogsOpen ? "Hide group logs" : "Group logs"
                    tooltipText: "All containers in this group, merged by time"
                    onClicked: root.groupLogsOpen ? root.closeGroupLogs() : root.openGroupLogs()
                  }
                  MonitorButton {
                    visible: root.containerPage
                    text: "View logs"
                    enabled: !logsProc.running
                    onClicked: root.showLogs(containerRow.container)
                  }
                  MonitorButton {
                    visible: root.detailPage && (containerRow.container.isGroup || root.containerPage)
                    text: "Ask agent"
                    tooltipText: containerRow.container.isGroup ? "Ask your default agent what this group is for"
                                                                : "Ask your default agent what this container is for"
                    onClicked: root.askAgent(containerRow.container)
                  }
                }

                Column {
                  visible: root.containerPage && root.containerTab === "overview"
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "Internal IP"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Repeater {
                    model: containerRow.container.internalAddresses || []
                    delegate: Text {
                      required property var modelData
                      width: parent.width
                      text: modelData.address + " · " + modelData.network
                      textFormat: Text.PlainText
                      wrapMode: Text.WrapAnywhere
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: (containerRow.container.internalAddresses || []).length === 0
                    text: "No container IP assigned"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  visible: root.containerPage && root.containerTab === "overview"
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "Published ports"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Repeater {
                    model: containerRow.container.publishedPorts || []
                    delegate: Item {
                      required property var modelData
                      width: parent.width
                      implicitHeight: portText.implicitHeight
                      Text {
                        id: portText
                        width: parent.width
                        text: modelData.target + " → " + modelData.port + " · " + (modelData.description || "checking…") +
                              (modelData.url ? "  ↗" : "")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: modelData.web ? Color.accent : (modelData.url ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4))
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.underline: portMouse.containsMouse && !!modelData.url
                      }
                      MouseArea {
                        id: portMouse
                        anchors.fill: parent
                        enabled: !!modelData.url
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Qt.openUrlExternally(modelData.url)
                      }
                      PanelToolTip {
                        visible: portMouse.containsMouse && !!modelData.url
                        text: "Open " + modelData.url
                        fontFamily: root.bar.fontFamily
                      }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: (containerRow.container.publishedPorts || []).length === 0
                    text: "No ports published to the host"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Row 2: image
                Text {
                  textFormat: Text.PlainText
                  visible: root.containerPage && root.containerTab === "settings"
                  text: (containerRow.container.service ? containerRow.container.service + " · " : "") + (containerRow.container.image || "") + " · " + (containerRow.container.id || "")
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }

                // Power row: same helper path as the ⋯ menu, laid out like RAM LIMIT
                Item {
                  visible: root.containerPage && root.containerTab === "settings"
                  width: parent.width
                  implicitHeight: Math.max(runningHeader.implicitHeight, restartButton.implicitHeight)

                  Text {
                    id: runningHeader
                    textFormat: Text.PlainText
                    text: "RUNNING"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)

                    MonitorButton {
                      id: restartButton
                      anchors.verticalCenter: parent.verticalCenter
                      bordered: false
                      text: "↻ Restart"
                      tooltipText: "Restart this container"
                      enabled: !actionProc.running && Model.actionCommand("restart", containerRow.container).length > 0
                      onClicked: root.runAction("restart", containerRow.container)
                    }

                    ToggleSwitch {
                      readonly property bool up: ["running", "restarting"].indexOf(containerRow.container.status) >= 0
                      anchors.verticalCenter: parent.verticalCenter
                      trackHeight: Math.round(runningHeader.font.pixelSize * 1.2)
                      cursorPad: Style.space(3)
                      checked: up
                      busy: actionProc.running
                      enabled: Model.actionCommand(up ? "stop" : "start", containerRow.container).length > 0
                      foreground: root.bar.foreground
                      onToggled: root.runAction(up ? "stop" : "start", containerRow.container)
                    }
                  }
                }

                // Row 3: RAM limit header
                Item {
                  visible: root.containerPage && root.containerTab === "settings"
                  width: parent.width
                  implicitHeight: ramValue.implicitHeight

                  Text {
                    id: ramHeader
                    textFormat: Text.PlainText
                    text: "RAM LIMIT"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: ramValue
                    textFormat: Text.PlainText
                    text: {
                      var c = containerRow.container
                      var shown = ramSlider.dragging ? ramSlider.liveValue : root.effectiveMb(c)
                      var label = Model.formatMb(shown)
                      if (root.containerLimitMb(c) === 0 && root.memOverrides[c.name] === undefined)
                        label += " (unlimited)"
                      return label
                    }
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                // Row 4: RAM slider
                PanelSlider {
                  id: ramSlider
                  enabled: containerRow.container.status === "running"
                  visible: root.containerPage && root.containerTab === "settings"
                  bar: root.bar
                  width: parent.width
                  minimum: root.memMin
                  maximum: root.hostMemMb
                  step: root.memStep
                  integer: true
                  value: root.effectiveMb(containerRow.container)
                  onMoved: function(v) {
                    root.userInteracting = true
                    root.setOverride(containerRow.container.name, v)
                  }
                  onReleased: function(v) {
                    root.userInteracting = false
                    root.setMemory(containerRow.container.name, v)
                  }
                }
              }

              PanelToolTip {
                visible: !root.detailPage && groupMouse.containsMouse
                text: containerRow.container.name + (Model.needsAttention(containerRow.container) ? " · " + containerRow.container.summary : "") + " · Open details"
                fontFamily: root.bar.fontFamily
              }

              MouseArea {
                id: groupMouse
                hoverEnabled: true
                anchors.fill: parent
                enabled: !root.detailPage
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openGroup(containerRow.container.key)
              }

              // Do not steal slider clicks: HoverHandler only tracks the mouse and
              // updates the keyboard cursor without consuming the click.
              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.selectedIndex = containerRow.index
                }
              }
            }
          }

          // ---------- Available Compose projects ----------
          Column {
            visible: !root.detailPage && root.availableProjects.length > 0
            width: parent.width
            spacing: Style.space(4)
            topPadding: Style.space(root.activeGroups.length ? 8 : 0)
            Text {
              leftPadding: Style.space(10)
              text: "Available"
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.availableProjects
              delegate: Item {
                id: projectRow
                required property var modelData
                width: parent.width
                implicitHeight: projectInfo.implicitHeight + Style.space(12)
                Column {
                  id: projectInfo
                  anchors.left: parent.left
                  anchors.right: startButton.left
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  Text {
                    width: parent.width
                    text: root.serviceIcon({ key: "project:" + modelData.name, name: modelData.name,
                                             containers: modelData.services.map(function(s) { return { service: s } }) }) +
                          "  " + modelData.name
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Qt.darker(root.bar.foreground, 1.15)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    text: Model.projectSummary(modelData, Quickshell.env("HOME"))
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MonitorButton {
                  id: startButton
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.startingProject === modelData.name ? "Starting…" : "Start"
                  tooltipText: modelData.available ? "docker compose up -d · " + modelData.files.join(", ") :
                      "Compose file is missing: " + modelData.files.join(", ")
                  enabled: modelData.available && !startProc.running
                  onClicked: root.startProject(modelData)
                }
              }
            }
          }

          Column {
            visible: root.groupLogsOpen && root.detailPage && !root.containerPage
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: "Group logs · merged by time · newest 400 lines · click a name to hide or show it"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.groupLogsOpen ? root.groupLogMembers() : []
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool hidden: !!root.groupLogHidden[modelData.name]
                  readonly property color tone: root.groupLogColor(modelData.name)
                  width: chipRow.implicitWidth + Style.space(12)
                  height: chipRow.implicitHeight + Style.space(6)
                  radius: height / 2
                  color: hidden ? "transparent" : Qt.alpha(tone, 0.14)
                  border.width: 1
                  border.color: Qt.alpha(tone, hidden ? 0.3 : 0.7)
                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: Style.space(5)
                    Rectangle {
                      width: Style.space(7); height: width; radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: hidden ? "transparent" : tone
                      border.width: 1
                      border.color: tone
                    }
                    Text {
                      text: root.groupLogLabel(modelData.name)
                      textFormat: Text.PlainText
                      color: hidden ? Qt.darker(root.bar.foreground, 1.8) : tone
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.strikeout: hidden
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleGroupLogContainer(modelData.name)
                  }
                }
              }
            }
            Rectangle {
              width: parent.width
              height: Style.space(420)
              color: Qt.alpha(root.bar.foreground, 0.06)
              ListView {
                id: groupLogList
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                model: root.groupLogLines
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                readonly property real nameWidth: Style.space(110)
                readonly property real timeWidth: groupLogTimeMetrics.width + Style.space(8)
                TextMetrics {
                  id: groupLogTimeMetrics
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  text: "00:00:00.000"
                }
                delegate: Item {
                  required property var modelData
                  readonly property color tone: root.groupLogColor(modelData.name)
                  width: groupLogList.width - Style.space(10)
                  height: Math.max(lineText.implicitHeight, nameLabel.implicitHeight)
                  Rectangle {
                    id: lineMarker
                    width: Style.space(3)
                    height: parent.height
                    color: tone
                  }
                  Text {
                    id: nameLabel
                    x: lineMarker.width + Style.space(5)
                    width: groupLogList.nameWidth
                    text: root.groupLogLabel(modelData.name)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: tone
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    id: timeLabel
                    x: nameLabel.x + nameLabel.width + Style.space(6)
                    width: groupLogList.timeWidth
                    text: modelData.time
                    textFormat: Text.PlainText
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    id: lineText
                    x: timeLabel.x + timeLabel.width
                    width: parent.width - x
                    text: modelData.text
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
            Text {
              visible: root.groupLogNote !== ""
              width: parent.width
              text: root.groupLogNote
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              spacing: Style.space(8)
              MonitorButton {
                text: groupLogsProc.running && !root.groupLogsLive ? "Loading…" : "Refresh"
                enabled: !groupLogsProc.running
                onClicked: root.showGroupLogs()
              }
              MonitorButton {
                text: root.groupLogsLive ? "● Live" : "○ Live"
                tooltipText: root.groupLogsLive ? "Stop following new lines" : "Refresh automatically and follow new lines"
                onClicked: {
                  root.groupLogsLive = !root.groupLogsLive
                  if (root.groupLogsLive) groupLogList.positionViewAtEnd()
                }
              }
              MonitorButton { text: "Close logs"; onClicked: root.closeGroupLogs() }
            }
          }

          Column {
            visible: root.logsName !== ""
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: "Logs · " + root.logsName + " · latest 200 lines"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.bar.foreground
              font.pixelSize: Style.font.caption
            }
            ScrollView {
              width: parent.width
              height: Style.space(220)
              clip: true
              TextArea {
                id: logArea
                text: root.logsText
                textFormat: TextEdit.PlainText
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                background: Rectangle { color: Qt.alpha(root.bar.foreground, 0.06) }
                Keys.onEscapePressed: { root.logsName = ""; keyCatcher.forceActiveFocus() }
              }
            }
            Row {
              spacing: Style.space(8)
              MonitorButton {
                text: logsProc.running ? "Loading…" : "Refresh logs"
                enabled: !logsProc.running
                onClicked: root.showLogs({name: root.logsName, id: root.logsId})
              }
              MonitorButton { text: "Close logs"; onClicked: { root.logsName = ""; keyCatcher.forceActiveFocus() } }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
