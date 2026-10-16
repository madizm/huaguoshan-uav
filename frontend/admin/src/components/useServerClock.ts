import { computed, onMounted, onUnmounted, ref, shallowRef } from 'vue'
import { getSystemTime } from '../api/systemConfig'
import {
  CLOCK_SYNC_INTERVAL_MS,
  createServerClockAnchor,
  isServerClockStale,
  readServerClock,
  type ServerClockAnchor,
} from '../serverClock'

/** 设置页只读服务器时钟：定期校准，隐藏页面暂停同步，恢复时立即校准。 */
export function useServerClock() {
  const anchor = shallowRef<ServerClockAnchor | null>(null)
  const monotonicNow = ref(performance.now())
  const syncing = ref(false)
  const syncError = ref(false)
  let disposed = false
  let controller: AbortController | undefined
  let tickTimer: ReturnType<typeof setInterval> | undefined
  let syncTimer: ReturnType<typeof setInterval> | undefined

  const currentTime = computed(() => anchor.value ? readServerClock(anchor.value, monotonicNow.value) : null)
  const stale = computed(() => anchor.value !== null && isServerClockStale(anchor.value, monotonicNow.value))
  const status = computed(() => {
    if (!anchor.value) return syncError.value ? '未同步' : '正在同步'
    if (syncError.value || stale.value) return '同步已过期'
    return '已同步'
  })

  async function sync() {
    if (disposed || syncing.value) return
    syncing.value = true
    const requestController = new AbortController()
    controller = requestController
    const timeout = setTimeout(() => requestController.abort(), 10_000)
    const startedAt = performance.now()
    try {
      const result = await getSystemTime(requestController.signal)
      if (disposed) return
      if (result.source !== 'database') throw new Error('服务器时间来源无效')
      const receivedAt = performance.now()
      anchor.value = createServerClockAnchor(result.server_time, startedAt, receivedAt)
      monotonicNow.value = receivedAt
      syncError.value = false
    } catch {
      if (!disposed) syncError.value = true
    } finally {
      clearTimeout(timeout)
      if (!disposed) syncing.value = false
      if (controller === requestController) controller = undefined
    }
  }

  function onVisibilityChange() {
    monotonicNow.value = performance.now()
    if (document.visibilityState === 'visible') void sync()
  }

  onMounted(() => {
    void sync()
    tickTimer = setInterval(() => { monotonicNow.value = performance.now() }, 1000)
    syncTimer = setInterval(() => {
      if (document.visibilityState === 'visible') void sync()
    }, CLOCK_SYNC_INTERVAL_MS)
    document.addEventListener('visibilitychange', onVisibilityChange)
  })

  onUnmounted(() => {
    disposed = true
    controller?.abort()
    if (tickTimer !== undefined) clearInterval(tickTimer)
    if (syncTimer !== undefined) clearInterval(syncTimer)
    document.removeEventListener('visibilitychange', onVisibilityChange)
  })

  return { currentTime, status, syncing, syncError, sync }
}
