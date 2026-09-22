<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { Refresh } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { TagProps } from 'element-plus'
import {
  listCounterUasStatusEvents,
  listCounterUasTelemetryCurrent,
  listCounterUasTelemetrySamples,
  type CounterUasStatusEvent,
  type CounterUasTelemetryCurrent,
  type CounterUasTelemetrySample,
  type EquipmentAsset,
} from '../api/equipment'

const props = defineProps<{
  modelValue: boolean
  asset: EquipmentAsset | null
}>()
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>()

const activeTab = ref('current')
const current = ref<CounterUasTelemetryCurrent | null>(null)
const events = ref<CounterUasStatusEvent[]>([])
const samples = ref<CounterUasTelemetrySample[]>([])
const loadingCurrent = ref(false)
const loadingHistory = ref(false)
let refreshTimer: number | undefined

const fieldLabels: Record<string, string> = {
  unattended: '无人值守模式',
  detectionDeviceOnline: '侦测子系统',
  countermeasureDeviceOnline: '处置子系统',
  detectionRotating: '侦测转台旋转',
  counterRotating: '处置转台旋转',
  activeFrequenciesMhz: '启用频段',
  radarOnline: '雷达在线',
  radarGpsUpdateEnabled: '雷达 GPS 更新',
}

const telemetryState = computed(() => {
  if (!current.value) return { label: '尚无遥测', type: 'info' as TagProps['type'] }
  if (current.value.telemetry_stale) return { label: '数据已过期', type: 'warning' as TagProps['type'] }
  return { label: '数据实时', type: 'success' as TagProps['type'] }
})

const sampleSummary = computed(() => {
  const values = (key: keyof CounterUasTelemetrySample) => samples.value
    .map((sample) => sample[key])
    .filter((value): value is number => typeof value === 'number')
  const summarize = (key: keyof CounterUasTelemetrySample) => {
    const list = values(key)
    if (!list.length) return null
    return { min: Math.min(...list), max: Math.max(...list), latest: list[0] }
  }
  return {
    voltage: summarize('counter_voltage_v'),
    temperature: summarize('counter_temperature_c'),
    power: summarize('counter_power_w'),
  }
})

function close() {
  emit('update:modelValue', false)
}

function formatTime(value: string | null | undefined): string {
  return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '--'
}

function formatNumber(value: number | null | undefined, unit = '', digits = 1): string {
  return value === null || value === undefined ? '--' : `${value.toFixed(digits)}${unit}`
}

function booleanState(value: boolean | null): { label: string; type: TagProps['type'] } {
  if (value === true) return { label: '是', type: 'success' }
  if (value === false) return { label: '否', type: 'danger' }
  return { label: '未知', type: 'info' }
}

function onlineState(value: boolean | null): { label: string; type: TagProps['type'] } {
  if (value === true) return { label: '在线', type: 'success' }
  if (value === false) return { label: '离线', type: 'danger' }
  return { label: '未知', type: 'info' }
}

function connectorState(value: CounterUasTelemetryCurrent['connector_state'] | undefined) {
  return {
    connected: { label: '已连接', type: 'success' },
    disconnected: { label: '已断开', type: 'danger' },
    degraded: { label: '异常', type: 'warning' },
    unknown: { label: '未知', type: 'info' },
  }[value ?? 'unknown'] as { label: string; type: TagProps['type'] }
}

function changedFieldLabel(field: string): string {
  return fieldLabels[field] ?? field
}

function prettyJson(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

async function loadCurrent(silent = false) {
  if (!props.asset) return
  if (!silent) loadingCurrent.value = true
  try {
    const rows = await listCounterUasTelemetryCurrent([props.asset.id])
    current.value = rows[0] ?? null
  } catch (error) {
    if (!silent) ElMessage.error(`实时状态加载失败：${(error as Error).message}`)
  } finally {
    if (!silent) loadingCurrent.value = false
  }
}

async function loadHistory() {
  if (!props.asset) return
  loadingHistory.value = true
  const startAt = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
  try {
    const [statusEvents, telemetrySamples] = await Promise.all([
      listCounterUasStatusEvents(props.asset.id),
      listCounterUasTelemetrySamples(props.asset.id, startAt),
    ])
    events.value = statusEvents
    samples.value = telemetrySamples
  } catch (error) {
    ElMessage.error(`运行历史加载失败：${(error as Error).message}`)
  } finally {
    loadingHistory.value = false
  }
}

async function refreshAll() {
  await Promise.all([loadCurrent(), loadHistory()])
  ElMessage.success('设备运行数据已刷新')
}

function startRefresh() {
  stopRefresh()
  refreshTimer = window.setInterval(() => loadCurrent(true), 5000)
}

function stopRefresh() {
  if (refreshTimer !== undefined) window.clearInterval(refreshTimer)
  refreshTimer = undefined
}

watch(
  () => [props.modelValue, props.asset?.id] as const,
  ([visible]) => {
    if (!visible || !props.asset) {
      stopRefresh()
      return
    }
    activeTab.value = 'current'
    current.value = null
    events.value = []
    samples.value = []
    loadCurrent()
    loadHistory()
    startRefresh()
  },
  { immediate: true },
)

onBeforeUnmount(stopRefresh)
</script>

<template>
  <el-drawer
    :model-value="modelValue"
    :title="asset ? `${asset.name} · 运行监控` : '设备运行监控'"
    size="760px"
    destroy-on-close
    @update:model-value="close"
  >
    <template #header>
      <div class="drawer-header">
        <div>
          <strong>{{ asset?.name }} · 运行监控</strong>
          <span>{{ asset?.asset_code }}</span>
        </div>
        <el-button :icon="Refresh" :loading="loadingCurrent || loadingHistory" @click="refreshAll">刷新</el-button>
      </div>
    </template>

    <el-tabs v-model="activeTab" class="telemetry-tabs">
      <el-tab-pane label="实时状态" name="current">
        <div v-loading="loadingCurrent">
          <el-alert
            v-if="!current && !loadingCurrent"
            title="尚未收到该设备的 config_status 遥测"
            type="info"
            :closable="false"
            show-icon
          />
          <template v-if="current">
            <div class="status-strip">
              <div>
                <span>遥测新鲜度</span>
                <el-tag :type="telemetryState.type">{{ telemetryState.label }}</el-tag>
              </div>
              <div>
                <span>接入链路</span>
                <el-tag :type="connectorState(current.connector_state).type">
                  {{ connectorState(current.connector_state).label }}
                </el-tag>
              </div>
              <div>
                <span>盒子状态</span>
                <el-tag :type="current.asset_connectivity_status === 'online' ? 'success' : current.asset_connectivity_status === 'offline' ? 'danger' : 'info'">
                  {{ current.asset_connectivity_status === 'online' ? '在线' : current.asset_connectivity_status === 'offline' ? '离线' : '未知' }}
                </el-tag>
              </div>
              <div>
                <span>最近接收</span>
                <strong>{{ formatTime(current.received_at) }}</strong>
              </div>
            </div>

            <h3>子系统状态</h3>
            <el-descriptions :column="3" border>
              <el-descriptions-item label="无人值守">
                <el-tag :type="booleanState(current.unattended).type">{{ booleanState(current.unattended).label }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="侦测子系统">
                <el-tag :type="onlineState(current.detection_device_online).type">{{ onlineState(current.detection_device_online).label }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="处置子系统">
                <el-tag :type="onlineState(current.countermeasure_device_online).type">{{ onlineState(current.countermeasure_device_online).label }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="侦测转台">
                <el-tag :type="booleanState(current.detection_rotating).type">{{ current.detection_rotating ? '旋转中' : current.detection_rotating === false ? '已停止' : '未知' }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="处置转台">
                <el-tag :type="booleanState(current.counter_rotating).type">{{ current.counter_rotating ? '旋转中' : current.counter_rotating === false ? '已停止' : '未知' }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="启用频段">
                {{ current.active_frequencies_mhz.length ? current.active_frequencies_mhz.map((v) => `${v} MHz`).join('、') : '--' }}
              </el-descriptions-item>
            </el-descriptions>

            <h3>电气与转台参数</h3>
            <el-descriptions :column="4" border>
              <el-descriptions-item label="电压">{{ formatNumber(current.counter_voltage_v, ' V') }}</el-descriptions-item>
              <el-descriptions-item label="电流">{{ formatNumber(current.counter_current_a, ' A') }}</el-descriptions-item>
              <el-descriptions-item label="功率">{{ formatNumber(current.counter_power_w, ' W') }}</el-descriptions-item>
              <el-descriptions-item label="温度">{{ formatNumber(current.counter_temperature_c, ' ℃') }}</el-descriptions-item>
              <el-descriptions-item label="侦测方位角">{{ formatNumber(current.detection_azimuth_deg, '°') }}</el-descriptions-item>
              <el-descriptions-item label="处置方位角">{{ formatNumber(current.counter_azimuth_deg, '°') }}</el-descriptions-item>
            </el-descriptions>

            <h3>雷达状态</h3>
            <el-descriptions :column="3" border>
              <el-descriptions-item label="雷达在线">
                <el-tag :type="onlineState(current.radar_online).type">{{ onlineState(current.radar_online).label }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="设备序列号">{{ current.radar_device_sn || '--' }}</el-descriptions-item>
              <el-descriptions-item label="GPS 更新">
                <el-tag :type="booleanState(current.radar_gps_update_enabled).type">{{ booleanState(current.radar_gps_update_enabled).label }}</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="航向角">{{ formatNumber(current.radar_heading_deg, '°') }}</el-descriptions-item>
              <el-descriptions-item label="基准航向">{{ formatNumber(current.radar_base_heading_deg, '°') }}</el-descriptions-item>
              <el-descriptions-item label="海拔">{{ formatNumber(current.radar_altitude_amsl_m, ' m') }}</el-descriptions-item>
              <el-descriptions-item label="雷达位置" :span="3">
                {{ current.radar_position ? `${current.radar_position.coordinates[0]}, ${current.radar_position.coordinates[1]}` : '--' }}
              </el-descriptions-item>
            </el-descriptions>

            <el-collapse class="diagnostics">
              <el-collapse-item title="诊断信息与原始报文" name="diagnostics">
                <p>质量标记：{{ current.quality_flags.join('、') || '无' }}</p>
                <p>来源：站点 {{ current.station_id || '--' }} / 盒子 {{ current.box_code || '--' }}</p>
                <pre>{{ prettyJson(current.raw_payload) }}</pre>
              </el-collapse-item>
            </el-collapse>
          </template>
        </div>
      </el-tab-pane>

      <el-tab-pane label="状态事件" name="events">
        <el-table v-loading="loadingHistory" :data="events" stripe max-height="620">
          <el-table-column label="发生时间" width="180">
            <template #default="{ row }">{{ formatTime(row.observed_at) }}</template>
          </el-table-column>
          <el-table-column label="事件" width="100">
            <template #default="{ row }">{{ row.event_type === 'initialized' ? '状态初始化' : '状态变化' }}</template>
          </el-table-column>
          <el-table-column label="变化字段" min-width="260">
            <template #default="{ row }">
              <el-tag v-for="field in row.changed_fields" :key="field" class="field-tag" effect="plain">
                {{ changedFieldLabel(field) }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column type="expand">
            <template #default="{ row }"><pre>{{ prettyJson({ previous: row.previous_state, current: row.current_state }) }}</pre></template>
          </el-table-column>
          <template #empty><el-empty description="暂无状态变化事件" /></template>
        </el-table>
      </el-tab-pane>

      <el-tab-pane label="24 小时采样" name="samples">
        <div class="sample-summary">
          <article v-for="(summary, key) in sampleSummary" :key="key">
            <span>{{ { voltage: '电压（V）', temperature: '温度（℃）', power: '功率（W）' }[key] }}</span>
            <strong>{{ summary ? summary.latest.toFixed(1) : '--' }}</strong>
            <small>{{ summary ? `最低 ${summary.min.toFixed(1)} / 最高 ${summary.max.toFixed(1)}` : '暂无数据' }}</small>
          </article>
        </div>
        <el-table v-loading="loadingHistory" :data="samples" stripe max-height="520">
          <el-table-column label="时间" width="180"><template #default="{ row }">{{ formatTime(row.observed_at) }}</template></el-table-column>
          <el-table-column prop="counter_voltage_v" label="电压/V" width="90" />
          <el-table-column prop="counter_current_a" label="电流/A" width="90" />
          <el-table-column prop="counter_power_w" label="功率/W" width="90" />
          <el-table-column prop="counter_temperature_c" label="温度/℃" width="90" />
          <el-table-column prop="detection_azimuth_deg" label="侦测角/°" width="100" />
          <el-table-column prop="counter_azimuth_deg" label="处置角/°" width="100" />
          <template #empty><el-empty description="最近 24 小时暂无采样" /></template>
        </el-table>
      </el-tab-pane>
    </el-tabs>
  </el-drawer>
</template>

<style scoped>
.drawer-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  padding-right: 12px;
}
.drawer-header strong,
.drawer-header span {
  display: block;
}
.drawer-header span {
  margin-top: 3px;
  color: var(--el-text-color-secondary);
  font-size: 12px;
}
.status-strip,
.sample-summary {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 12px;
  margin-bottom: 22px;
}
.status-strip > div,
.sample-summary article {
  min-height: 66px;
  padding: 12px;
  border: 1px solid var(--el-border-color-light);
  border-radius: 6px;
  background: var(--el-fill-color-lighter);
}
.status-strip span,
.status-strip strong,
.sample-summary span,
.sample-summary strong,
.sample-summary small {
  display: block;
}
.status-strip span,
.sample-summary span,
.sample-summary small {
  color: var(--el-text-color-secondary);
  font-size: 12px;
}
.status-strip .el-tag,
.status-strip strong,
.sample-summary strong {
  margin-top: 8px;
}
.sample-summary {
  grid-template-columns: repeat(3, minmax(0, 1fr));
}
.sample-summary strong {
  font-size: 22px;
}
.sample-summary small {
  margin-top: 4px;
}
h3 {
  margin: 22px 0 10px;
  font-size: 15px;
}
.diagnostics {
  margin-top: 20px;
}
.field-tag {
  margin: 2px 4px 2px 0;
}
pre {
  overflow: auto;
  max-height: 360px;
  margin: 0;
  padding: 12px;
  border-radius: 4px;
  background: #17201b;
  color: #d7e5dc;
  font-size: 12px;
  line-height: 1.5;
}
@media (max-width: 800px) {
  .status-strip,
  .sample-summary {
    grid-template-columns: 1fr 1fr;
  }
}
</style>
