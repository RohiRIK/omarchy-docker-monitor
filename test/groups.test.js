const assert = require("node:assert/strict")
const M = require("../Model.js")
const snap = M.parseSnapshot(`==CONTAINERS==
a|/app-web-1|web|running|0|app|web
b|/app-web-2|web|running|0|app|web
c|/app-db-1|db|running|0|app|db
d|/other-web-1|web|running|0|other|web
e|/standalone|web|running|0|<no value>|<no value>
==STATS==
app-web-1|10%|1 MiB / 1 GiB|1%
app-web-2|20%|2 MiB / 1 GiB|2%
`)
const groups = M.groupContainers(snap.containers)
assert.equal(groups.length, 3)
const app = groups.find(g => g.name === "app")
assert.equal(app.containers.length, 3)
assert.equal(app.cpuPercent, "30%")
assert.equal(app.memUsageBytes, 3 * 1048576)
assert.equal(snap.containers[0].service, "web")
assert.equal(snap.containers[4].project, "")
assert.equal(M.visibleRows(groups, {}).length, 3)
const expanded = {"project:app": true}
assert.equal(M.visibleRows(groups, expanded).length, 6)
assert.equal(M.visibleRows(M.groupContainers(snap.containers.slice().reverse()), expanded).length, 6)
assert.equal(M.visibleRows([], expanded).length, 0)
console.log("Grouping, totals, label parsing, expansion and refresh checks passed")
