const assert = require("node:assert/strict")
const M = require("../Model.js")
const c = (id, name, status = "running", health = "healthy") => ({
  id: id.repeat(12), name, project: "app", status, health, memUsageBytes: 100,
  cpuPercent: "2%", urls: [], restarts: 0
})
const web = c("a", "web"), db = c("b", "db"), stopped = c("c", "stopped", "exited", "")
const unhealthy = c("d", "bad", "running", "unhealthy")
assert.equal(M.groupContainers([web, db, stopped, unhealthy])[0].warningCount, 1)
assert.equal(M.groupContainers([web, db, stopped, unhealthy])[0].runningCount, 3)
assert.equal(M.healthText(stopped), "exited")
assert.equal(M.needsAttention({...web, status: "restarting"}), true)
assert.equal(M.healthText({...web, health: ""}), "running · no health check")
assert.deepEqual(M.actionCommand("start", M.groupContainers([web, stopped])[0]), ["docker", "start", stopped.id])
assert.deepEqual(M.actionCommand("stop", M.groupContainers([web, stopped])[0]), ["docker", "stop", web.id])
assert.deepEqual(M.actionCommand("restart", db), ["docker", "restart", db.id])
assert.deepEqual(M.actionCommand("rm", web), [])
assert.deepEqual(M.actionCommand("stop", {...web, id: "--help"}), [])
const prefs = {assignments: {web: "Frontend", db: "Frontend"}, aliases: {"custom:Frontend": "My services"}, urls: {web: "https://example.test"}}
const groups = M.groupContainers([web, db, stopped], prefs)
assert.equal(groups.length, 2)
assert.equal(groups.find(g => g.key === "custom:Frontend").name, "My services")
assert.deepEqual(groups.find(g => g.key === "custom:Frontend").urls, ["https://example.test"])
assert.equal(M.safeUrl("file:///etc/passwd"), "")
assert.equal(M.safeUrl("javascript:alert(1)"), "")
assert.deepEqual(M.serviceUrls({
  "traefik.http.routers.app.rule": 'Host(`example.test`)',
  "traefik.http.routers.app.tls.certresolver": "resolver",
  "traefik.http.routers.app-http.rule": 'Host(`example.test`)'
}, {}), ["https://example.test"])
assert.deepEqual(M.serviceUrls({}, {"5432/tcp": [{HostIp:"0.0.0.0", HostPort:"5432"}]}), [])
assert.deepEqual(M.serviceUrls({}, {"8080/tcp": [{HostIp:"0.0.0.0", HostPort:"8888"}]}), ["http://localhost:8888"])
let history = {}
for (let i=0; i<70; i++) history = M.addHistory(history, [web, db], {}, i * 3000)
assert.equal(history[web.id].length, 60)
assert.equal(history["project:app"][0].cpu, 4)
assert.equal(M.addHistory(history, [web], {}, 300000)[web.id].length, 1)
assert.equal(M.addHistory(history, [], {}, 300000)[web.id], undefined)
const raw = { ...web, name: "/web", labels: {"com.docker.compose.project":"app"}, ports: {} }
const snap = M.parseSnapshot("==INSPECT==\n"+JSON.stringify(raw)+"\n==STATS==\nweb|3%|1 MiB / 1 GiB|1%")
assert.equal(snap.containers[0].health, "healthy")
assert.equal(snap.containers[0].cpuPercent, "3%")
assert.equal(snap.containers[0].labels, undefined)
assert.ok(M.parseSnapshot("==INSPECT==\ninvalid").error)
console.log("Health, custom groups, URLs, action targets, history and metadata tests passed")
