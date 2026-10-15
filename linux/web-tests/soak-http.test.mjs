import test from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import http from 'node:http'
import { createHttp } from '../web-dev/soak/bridge-http.mjs'

const session = { cookie: 'cb_session=x', csrf: 'token' }

// A server that answers the first request of a connection and then closes `drops` connections while a request is on them, the way a server drops an idle
// keep-alive connection just as the next request arrives. Every other connection is served normally.
function staleServer(drops = 1) {
  const connections = []
  let dropped = 0
  const server = net.createServer((socket) => {
    connections.push(socket)
    let served = 0
    socket.on('data', () => {
      served++
      if (served === 1 && connections.length === 1) socket.write('HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: keep-alive\r\n\r\n{"ok":true}')
      else if (dropped < drops) { dropped++; socket.destroy() }
      else socket.write('HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: keep-alive\r\n\r\n{"ok":true}')
    })
    socket.on('error', () => {})
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, connections })))
}

test('a GET on a kept-alive connection that the server closed is sent again once, and counted', async () => {
  const { server, port } = await staleServer()
  const client = createHttp({ base: `http://127.0.0.1:${port}`, session })
  try {
    const first = await client.request('GET', '/a')
    assert.equal(first.status, 200); assert.ok(!first.retried)
    const second = await client.request('GET', '/b')
    assert.equal(second.status, 200); assert.equal(second.retried, true); assert.equal(second.netError, undefined)
  } finally { client.close(); server.close() }
})

test('only the first reset is forgiven: a new connection that is reset too is an error', async () => {
  const { server, port } = await staleServer(2)
  const client = createHttp({ base: `http://127.0.0.1:${port}`, session })
  try {
    await client.request('GET', '/a')
    const second = await client.request('GET', '/b')
    assert.equal(second.status, 0); assert.ok(second.netError); assert.equal(second.retried, true)
  } finally { client.close(); server.close() }
})

test('a POST is never sent again, and a connection cut in the middle of an answer is an error', async () => {
  const { server, port } = await staleServer()
  const client = createHttp({ base: `http://127.0.0.1:${port}`, session })
  try {
    await client.request('GET', '/a')
    const post = await client.request('POST', '/b', { body: { a: 1 } })
    assert.equal(post.status, 0); assert.ok(post.netError); assert.ok(!post.retried)
  } finally { client.close(); server.close() }
  const cut = http.createServer((req, res) => { res.writeHead(200, { 'content-length': '1000', 'content-type': 'video/mp4' }); res.write(Buffer.alloc(100)); setTimeout(() => res.destroy(), 20) })
  await new Promise((resolve) => cut.listen(0, '127.0.0.1', resolve))
  const other = createHttp({ base: `http://127.0.0.1:${cut.address().port}`, session })
  try {
    const r = await other.request('GET', '/x', { collect: 'media' })
    assert.ok(['closed', 'ECONNRESET'].includes(r.netError), r.netError); assert.ok(!r.retried); assert.equal(r.bytes, 100)
  } finally { other.close(); cut.close() }
})

test('a server that never answers is a timeout error, not a hang', async () => {
  const silent = net.createServer(() => {})
  await new Promise((resolve) => silent.listen(0, '127.0.0.1', resolve))
  const client = createHttp({ base: `http://127.0.0.1:${silent.address().port}`, session, timeoutMs: 300 })
  try {
    const r = await client.request('GET', '/x')
    assert.equal(r.netError, 'ETIMEDOUT')
  } finally { client.close(); silent.close(); silent.unref() }
})

test('statuses come back with their JSON error body; media keeps only the head', async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/gone') { res.writeHead(410, { 'content-type': 'application/json' }); return res.end('{"error":"gone","message":"x"}') }
    res.writeHead(200, { 'content-type': 'video/mp4', 'content-length': 1_000_000 }); res.end(Buffer.alloc(1_000_000, 7))
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const client = createHttp({ base: `http://127.0.0.1:${server.address().port}`, session })
  try {
    const gone = await client.request('GET', '/gone')
    assert.equal(gone.status, 410); assert.equal(gone.json.error, 'gone')
    const media = await client.request('GET', '/m', { collect: 'media', headLimit: 4096 })
    assert.equal(media.bytes, 1_000_000); assert.equal(media.head.length, 4096)
  } finally { client.close(); server.close() }
})
