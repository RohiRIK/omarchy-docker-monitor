// Docker plugin data logic: collection script + pure parsers.
// Kept separate from the UI so it can be tested with node (see README.md).

// docker-helper.py collects the snapshot with a deadline and byte limits.
// Its output is sectioned:
//   ==DOCKER==  daemon version or "unavailable"
//   ==HOST==    host total RAM in bytes
//   ==INSPECT== one JSON object per container
//   ==STATS==   one line per container: name|cpuPerc|memUsage|memPerc
//   ==ERROR==   user-facing messages when collection was cut short
// "|" is a safe separator: container names cannot contain "|".

function parseSizeToBytes(text) {
  var m = /^(\d+(?:\.\d+)?)\s*([KMGT]?i?B)$/i.exec(String(text || "").trim())
  if (!m) return 0
  var value = parseFloat(m[1])
  if (!isFinite(value)) return 0
  var unit = m[2].toUpperCase()
  var mult = 1
  if (unit === "KB") mult = 1000
  else if (unit === "KIB") mult = 1024
  else if (unit === "MB") mult = 1000 * 1000
  else if (unit === "MIB") mult = 1024 * 1024
  else if (unit === "GB") mult = 1000 * 1000 * 1000
  else if (unit === "GIB") mult = 1024 * 1024 * 1024
  else if (unit === "TB") mult = 1000 * 1000 * 1000 * 1000
  else if (unit === "TIB") mult = 1024 * 1024 * 1024 * 1024
  return Math.round(value * mult)
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n >= 1099511627776) return (Math.round(n / 1099511627776 * 10) / 10) + " TiB"
  if (n >= 1073741824) return (Math.round(n / 1073741824 * 10) / 10) + " GiB"
  if (n >= 1048576) return (Math.round(n / 1048576 * 10) / 10) + " MiB"
  if (n >= 1024) return (Math.round(n / 1024 * 10) / 10) + " KiB"
  return Math.round(n) + " B"
}

function formatMb(mb) {
  var n = Number(mb)
  if (!isFinite(n) || n < 0) n = 0
  if (n >= 1024) return (Math.round(n / 1024 * 10) / 10) + " GiB"
  return Math.round(n) + " MiB"
}

function clampMemMb(mb, maxMb) {
  var n = Math.round(Number(mb))
  var max = Math.round(Number(maxMb))
  if (!isFinite(n)) n = 6
  if (!isFinite(max) || max < 6) max = 6
  return Math.max(6, Math.min(max, n))
}

function parseSnapshot(text) {
  var result = {
    dockerAvailable: false,
    dockerVersion: "",
    hostMemBytes: 0,
    containers: []
  }

  var sections = {}
  var current = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var header = /^==(.+)==$/.exec(line.trim())
    if (header) {
      current = header[1]
      sections[current] = []
    } else if (current !== "") {
      sections[current].push(line)
    }
  }

  var dockerLines = sections["DOCKER"] || []
  var version = String(dockerLines[0] || "").trim()
  result.dockerAvailable = version !== "" && version !== "unavailable"
  result.dockerVersion = result.dockerAvailable ? version : ""

  var hostLines = sections["HOST"] || []
  var hostBytes = parseInt(String(hostLines[0] || "").trim(), 10)
  result.hostMemBytes = isFinite(hostBytes) ? hostBytes : 0

  // Stats index by container name.
  var statsByName = {}
  var statsLines = sections["STATS"] || []
  for (var s = 0; s < statsLines.length; s++) {
    var sp = statsLines[s].split("|")
    if (sp.length < 4 || sp[0].trim() === "") continue
    var usageParts = sp[2].split("/")
    statsByName[sp[0].trim()] = {
      cpuPercent: String(sp[1] || "").trim(),
      memUsageBytes: parseSizeToBytes(usageParts[0] || ""),
      memPercent: String(sp[3] || "").trim()
    }
  }

  var containerLines = sections["CONTAINERS"] || []
  for (var c = 0; c < containerLines.length; c++) {
    var cp = containerLines[c].split("|")
    if (cp.length < 5 || cp[0].trim() === "") continue
    var name = String(cp[1] || "").trim().replace(/^\//, "")
    var limit = parseInt(String(cp[4] || "").trim(), 10)
    var stats = statsByName[name] || null
    result.containers.push({
      id: String(cp[0] || "").trim().substring(0, 12),
      name: name,
      project: cleanLabel(cp[5]),
      service: cleanLabel(cp[6]),
      image: String(cp[2] || "").trim(),
      status: String(cp[3] || "").trim(),
      memLimitBytes: isFinite(limit) ? limit : 0,
      cpuPercent: stats ? stats.cpuPercent : "",
      memUsageBytes: stats ? stats.memUsageBytes : 0,
      memPercent: stats ? stats.memPercent : ""
    })
  }

  var errors = (sections["ERROR"] || []).map(function(line) { return line.trim() }).filter(Boolean)
  if (errors.length) result.error = errors.join("\n")

  ;(sections["INSPECT"] || []).forEach(function(line) {
    if (!line.trim()) return
    try {
      var c = JSON.parse(line)
      c.name = c.name.replace(/^\//, "")
      c.id = c.id.substring(0, 12)
      var labels = c.labels || {}
      c.project = labels["com.docker.compose.project"] || ""
      c.service = labels["com.docker.compose.service"] || ""
      c.urls = serviceUrls(labels, c.ports || {})
      c.internalAddresses = []
      Object.keys(c.networks || {}).sort().forEach(function(name) {
        var network = c.networks[name] || {}
        ;[network.IPAddress, network.GlobalIPv6Address].forEach(function(address) {
          if (address) c.internalAddresses.push({ network: name, address: address })
        })
      })
      delete c.networks
      delete c.labels
      delete c.ports
      var stats = statsByName[c.name]
      c.cpuPercent = stats ? stats.cpuPercent : ""
      c.memUsageBytes = stats ? stats.memUsageBytes : 0
      c.memPercent = stats ? stats.memPercent : ""
      result.containers.push(c)
    } catch (error) { result.error = "Some Docker metadata could not be read. Refresh to retry." }
  })
  return result
}

function cleanLabel(value) {
  var label = String(value || "").trim()
  return label === "<no value>" ? "" : label
}

function safeUrl(url) {
  var value = String(url || "").trim()
  return /^https?:\/\/[^\s/]+(?:[^\s]*)$/i.test(value) ? value : ""
}

function serviceUrls(labels, ports) {
  var urls = []
  function add(url) { if (safeUrl(url) && urls.indexOf(url) < 0) urls.push(url) }
  add(labels["omarchy.docker.url"])
  Object.keys(labels).sort().forEach(function(key) {
    if (!/^traefik\.http\.routers\..+\.rule$/.test(key) || labels["traefik.enable"] === "false") return
    var base = key.slice(0, -5)
    var tls = labels[base + ".tls"] === "true" || !!labels[base + ".tls.certresolver"] ||
              /websecure/.test(labels[base + ".entrypoints"] || "")
    var hosts = /Host\(([^)]+)\)/g, match
    while ((match = hosts.exec(labels[key]))) {
      var names = match[1].match(/[`"][a-zA-Z0-9.-]+[`"]/g) || []
      names.forEach(function(n) { add((tls ? "https://" : "http://") + n.slice(1, -1)) })
    }
  })
  // Prefer HTTPS when the same hostname has an HTTP redirect router.
  urls = urls.filter(function(u) { return u.indexOf("http://") !== 0 || urls.indexOf(u.replace("http://", "https://")) < 0 })
  if (!urls.length && labels["traefik.enable"] !== "false") {
    Object.keys(ports).sort().forEach(function(port) {
      if (!/^(80|443|3000|8000|8080|8443|9000)\/tcp$/.test(port)) return
      ;(ports[port] || []).forEach(function(binding) {
        var host = binding.HostIp
        if (!host || host === "0.0.0.0" || host === "::") host = "localhost"
        if (host.indexOf(":") >= 0) host = "[" + host + "]"
        add((/^(443|8443)\//.test(port) ? "https://" : "http://") + host + ":" + binding.HostPort)
      })
    })
  }
  return urls
}

function healthText(c) {
  if (c.status !== "running") return c.status || "unknown"
  return c.health || "running · no health check"
}

function needsAttention(c) {
  return c.health === "unhealthy" || c.status === "restarting" || c.status === "dead"
}

function groupContainers(containers, preferences) {
  preferences = preferences || {}
  var assignments = preferences.assignments || {}
  var aliases = preferences.aliases || {}
  var groups = [], byKey = Object.create(null)
  containers.forEach(function(c) {
    var custom = Object.prototype.hasOwnProperty.call(assignments, c.name) ? assignments[c.name] : ""
    var key = custom ? "custom:" + custom : (c.project ? "project:" + c.project : "container:" + c.id)
    var group = byKey[key]
    if (!group) {
      group = { isGroup: true, key: key, name: aliases[key] || custom || c.project || c.name,
                containers: [], memUsageBytes: 0, cpuTotal: 0, statsCount: 0,
                runningCount: 0, warningCount: 0, healthyCount: 0, startingCount: 0, urls: [] }
      byKey[key] = group
      groups.push(group)
    }
    group.containers.push(c)
    if (c.status === "running") group.runningCount++
    if (needsAttention(c)) group.warningCount++
    if (c.health === "healthy" && c.status === "running") group.healthyCount++
    if (c.health === "starting" && c.status === "running") group.startingCount++
    group.memUsageBytes += c.memUsageBytes || 0
    var cpu = parseFloat(c.cpuPercent)
    if (isFinite(cpu)) { group.cpuTotal += cpu; group.statsCount++ }
    containerUrls(c, preferences).forEach(function(u) { if (group.urls.indexOf(u) < 0) group.urls.push(u) })
  })
  groups.forEach(function(g) {
    g.containers.sort(function(a, b) { return a.name.localeCompare(b.name) })
    g.count = g.containers.length
    g.cpuPercent = g.statsCount ? (Math.round(g.cpuTotal * 100) / 100) + "%" : ""
    g.status = g.runningCount === g.count ? "running" : "stopped"
    g.health = g.warningCount ? "unhealthy" : (g.healthyCount === g.count ? "healthy" : "")
    g.summary = g.runningCount + "/" + g.count + " running"
    if (g.warningCount) g.summary += " · " + g.warningCount + " need attention"
    else if (g.healthyCount) g.summary += " · " + g.healthyCount + " healthy"
    if (g.startingCount) g.summary += " · " + g.startingCount + " starting"
  })
  return groups.sort(function(a, b) { return a.name.localeCompare(b.name) })
}

function containerUrls(c, preferences) {
  var override = ((preferences || {}).urls || {})[c.name]
  return safeUrl(override) ? [safeUrl(override)] : (c.urls || [])
}

function visibleRows(groups, expanded) {
  var rows = []
  groups.forEach(function(g) {
    rows.push(g)
    if (expanded[g.key]) g.containers.forEach(function(c) { rows.push(c) })
  })
  return rows
}

// Returns the Docker argv for a lifecycle action; the panel runs it through
// docker-helper.py, which re-validates the verb and ids.
function actionCommand(action, row) {
  if (["start", "stop", "restart"].indexOf(action) < 0 || !row) return []
  var members = row.isGroup ? row.containers : [row]
  var ids = members.filter(function(c) {
    return action === "start" ? ["exited", "created"].indexOf(c.status) >= 0 :
           ["running", "restarting"].indexOf(c.status) >= 0
  }).map(function(c) { return c.id }).filter(function(id) { return /^[a-f0-9]{12,64}$/.test(id) })
  return ids.length ? ["docker", action].concat(ids) : []
}

function addHistory(previous, containers, preferences, now) {
  var next = {}
  containers.concat(groupContainers(containers, preferences)).forEach(function(c) {
    var key = c.isGroup ? c.key : c.id
    var cpu = parseFloat(c.cpuPercent)
    var old = previous[key] || []
    if (old.length && now - old[old.length - 1].time > 15000) old = []
    next[key] = old.concat([{ time: now, cpu: isFinite(cpu) ? cpu : null,
                             mem: isFinite(cpu) ? c.memUsageBytes : null }]).slice(-60)
  })
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    safeUrl: safeUrl,
    serviceUrls: serviceUrls,
    containerUrls: containerUrls,
    healthText: healthText,
    needsAttention: needsAttention,
    actionCommand: actionCommand,
    addHistory: addHistory,
    groupContainers: groupContainers,
    visibleRows: visibleRows,
    parseSizeToBytes: parseSizeToBytes,
    formatBytes: formatBytes,
    formatMb: formatMb,
    clampMemMb: clampMemMb,
    parseSnapshot: parseSnapshot
  }
}
