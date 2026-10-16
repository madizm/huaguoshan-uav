import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  CLOCK_STALE_AFTER_MS,
  createServerClockAnchor,
  isServerClockStale,
  readServerClock,
} from '../frontend/admin/src/serverClock.ts'

const timestamp = '2026-01-01T00:00:00.000Z'

test('补偿半个往返耗时，并按单调时钟推进', () => {
  const anchor = createServerClockAnchor(timestamp, 100, 300)
  assert.equal(readServerClock(anchor, 300).toISOString(), '2026-01-01T00:00:00.100Z')
  assert.equal(readServerClock(anchor, 1300).toISOString(), '2026-01-01T00:00:01.100Z')
})

test('客户端系统时间变化不影响走时', () => {
  const anchor = createServerClockAnchor(timestamp, 0, 0)
  const originalNow = Date.now
  try {
    Date.now = () => Date.parse('2099-01-01T00:00:00Z')
    assert.equal(readServerClock(anchor, 5000).toISOString(), '2026-01-01T00:00:05.000Z')
  } finally {
    Date.now = originalNow
  }
})

test('超过有效期后标记同步过期；重新采样恢复', () => {
  const anchor = createServerClockAnchor(timestamp, 0, 0)
  assert.equal(isServerClockStale(anchor, CLOCK_STALE_AFTER_MS - 1), false)
  assert.equal(isServerClockStale(anchor, CLOCK_STALE_AFTER_MS), true)
  const refreshed = createServerClockAnchor('2026-01-01T00:01:00.000Z', 60_000, 60_100)
  assert.equal(isServerClockStale(refreshed, 60_100), false)
})

test('拒绝无效时间、非 UTC 时间和无效采样顺序', () => {
  for (const value of ['not-a-date', '2026-01-01T00:00:00+08:00', '']) {
    assert.throws(() => createServerClockAnchor(value, 0, 100))
  }
  assert.throws(() => createServerClockAnchor(timestamp, 200, 100))
})
