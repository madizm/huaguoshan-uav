/** 服务器时间样本；后续走时只使用单调时钟，不依赖客户端日期。 */
export interface ServerClockAnchor {
  serverMs: number
  receivedAt: number
}

export const CLOCK_SYNC_INTERVAL_MS = 30_000
export const CLOCK_STALE_AFTER_MS = 60_000

export function createServerClockAnchor(
  serverTime: string,
  startedAt: number,
  receivedAt: number,
): ServerClockAnchor {
  const serverMs = Date.parse(serverTime)
  if (!Number.isFinite(serverMs) || !serverTime.endsWith('Z') || receivedAt < startedAt) {
    throw new Error('服务器时间格式无效')
  }
  // 估算单程网络延迟；该时钟用于展示，不作为精确授时服务。
  return { serverMs: serverMs + (receivedAt - startedAt) / 2, receivedAt }
}

export function readServerClock(anchor: ServerClockAnchor, now: number): Date {
  return new Date(anchor.serverMs + Math.max(0, now - anchor.receivedAt))
}

export function isServerClockStale(anchor: ServerClockAnchor, now: number): boolean {
  return now - anchor.receivedAt >= CLOCK_STALE_AFTER_MS
}
