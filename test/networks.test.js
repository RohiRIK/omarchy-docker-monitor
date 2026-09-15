const assert = require('node:assert/strict')
const Model = require('../Model.js')
const raw = { id: 'abc', name: '/demo', networks: {
  alpha: {IPAddress: '172.18.0.2', GlobalIPv6Address: 'fd00::2'},
  beta: {IPAddress: '172.19.0.2'},
  disconnected: {IPAddress: '', GlobalIPv6Address: ''}
}}
function parse(value) {
  return Model.parseSnapshot('==INSPECT==\n' + JSON.stringify(value)).containers[0]
}
assert.deepEqual(parse(raw).internalAddresses, [
  {network: 'alpha', address: '172.18.0.2'},
  {network: 'alpha', address: 'fd00::2'},
  {network: 'beta', address: '172.19.0.2'}
])
assert.deepEqual(parse({id: 'abc', name: '/demo'}).internalAddresses, [])
assert.equal('networks' in parse(raw), false)
console.log('IPv4/IPv6, multiple networks and missing-address checks passed')
