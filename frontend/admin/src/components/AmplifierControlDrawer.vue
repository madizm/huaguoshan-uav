<script setup lang="ts">
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  emergencyStopAmplifier,
  listAmplifierOperations,
  listAmplifierState,
  startAmplifier,
  stopAmplifier,
  type AmplifierMode,
  type AmplifierOperation,
  type AmplifierStateCurrent,
} from '../api/amplifier'
import type { CounterUasTelemetrySummary, EquipmentAsset } from '../api/equipment'

const props = defineProps<{
  modelValue: boolean
  asset: EquipmentAsset | null
  telemetry: CounterUasTelemetrySummary | null
}>()
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>()

const supportedFrequencies = [2400, 5200, 5800]
const form = reactive({
  mode: 'omnidirectional_frequency' as AmplifierMode,
  frequenciesMhz: [...supportedFrequencies],
  durationSeconds: 5,
  longitude: undefined as number | undefined,
  latitude: undefined as number | undefined,
  reason: '',
})
const state = ref<AmplifierStateCurrent | null>(null)
const operations = ref<AmplifierOperation[]>([])
const loading = ref(false)
const submitting = ref(false)
const now = ref(Date.now())
let refreshTimer: number | undefined
let clockTimer: number | undefined

const activeOperation = computed(() => operations.value.find((item) => !item.terminal_at) ?? null)
const deviceGateOpen = computed(() =>
  props.telemetry?.asset_connectivity_status === 'online'
  && props.telemetry?.countermeasure_device_online === true,
)
const canStart = computed(() => deviceGateOpen.value && !activeOperation.value && !submitting.value)
const remainingSeconds = computed(() => {
  const operation = activeOperation.value
  if (!operation) return null
  const expiry = operation.expected_expiry_at
  if (expiry) return Math.max(0, Math.ceil((new Date(expiry).getTime() - now.value) / 1000))
  const start = operation.confirmed_on_at || operation.start_dispatched_at || operation.requested_at
  return Math.max(0, Math.ceil((new Date(start).getTime() + operation.requested_duration_seconds * 1000 - now.value) / 1000))
})

function idempotencyKey(prefix: string): string {
  return `${prefix}-${crypto.randomUUID()}`
}

function stateLabel(value: AmplifierStateCurrent['actual_state'] | undefined): string {
  return { on: '已开启', off: '已关闭', unknown: '未知' }[value ?? 'unknown']
}

function modeLabel(value: AmplifierMode): string {
  return value === 'omnidirectional_frequency' ? '全向频段' : '目标坐标'
}

async function load(silent = false) {
  if (!props.asset) return
  if (!silent) loading.value = true
  try {
    const [states, rows] = await Promise.all([
      listAmplifierState(props.asset.id),
      listAmplifierOperations(props.asset.id),
    ])
    state.value = states[0] ?? null
    operations.value = rows
  } catch (error) {
    if (!silent) ElMessage.error(`功放状态加载失败：${(error as Error).message}`)
  } finally {
    if (!silent) loading.value = false
  }
}

function validateStart(): string | null {
  if (!deviceGateOpen.value) return '盒子和处置子系统必须在线'
  if (!form.frequenciesMhz.length) return '至少选择一个频段'
  if (!form.reason.trim()) return '请输入操作原因'
  if (form.durationSeconds < 1 || form.durationSeconds > 60) return '持续时间必须为 1 至 60 秒'
  if (form.mode === 'target_coordinate') {
    if (form.longitude === undefined || form.latitude === undefined) return '请输入目标经纬度'
    if (form.longitude < -180 || form.longitude > 180 || form.latitude < -90 || form.latitude > 90) return '目标经纬度超出 WGS84 范围'
  }
  return null
}

async function submitStart() {
  if (!props.asset) return
  const validation = validateStart()
  if (validation) {
    ElMessage.warning(validation)
    return
  }
  const modeNotice = form.mode === 'target_coordinate'
    ? '目标模式下发后不能提前关闭，将由设备按 duration 到时结束。'
    : '全向模式到时由平台发送 amp action=0，并可提前手动关闭。'
  await ElMessageBox.confirm(
    `确认开启「${props.asset.name}」${form.durationSeconds} 秒？${modeNotice}`,
    '确认开启功放',
    { type: 'warning', confirmButtonText: '确认开启' },
  )
  submitting.value = true
  try {
    await startAmplifier({
      assetId: props.asset.id,
      mode: form.mode,
      frequenciesMhz: [...form.frequenciesMhz],
      durationSeconds: form.durationSeconds,
      reason: form.reason.trim(),
      idempotencyKey: idempotencyKey('start'),
      target: form.mode === 'target_coordinate' ? {
        longitude: form.longitude!, latitude: form.latitude!, coordinateSystem: 'WGS84',
      } : undefined,
    })
    ElMessage.success('开启指令已进入发送队列')
    await load(true)
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    submitting.value = false
  }
}

async function submitStop() {
  if (!props.asset || !activeOperation.value) return
  if (activeOperation.value.mode !== 'omnidirectional_frequency') {
    ElMessage.warning('目标坐标模式不能提前关闭')
    return
  }
  const reason = await ElMessageBox.prompt('请输入关闭原因', '手动关闭全向功放', {
    inputValidator: (value) => Boolean(value.trim()) || '关闭原因不能为空',
    confirmButtonText: '确认关闭',
    type: 'warning',
  })
  submitting.value = true
  try {
    await stopAmplifier(props.asset.id, activeOperation.value.id, reason.value.trim(), idempotencyKey('stop'))
    ElMessage.success('关闭指令已进入发送队列')
    await load(true)
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    submitting.value = false
  }
}

async function submitEmergencyStop() {
  if (!props.asset) return
  const reason = await ElMessageBox.prompt('请输入紧急关闭原因', '紧急关闭全向功放', {
    inputValidator: (value) => Boolean(value.trim()) || '关闭原因不能为空',
    confirmButtonText: '发送紧急关闭',
    type: 'error',
  })
  submitting.value = true
  try {
    await emergencyStopAmplifier(props.asset.id, reason.value.trim(), idempotencyKey('emergency-stop'))
    ElMessage.success('紧急关闭指令已进入发送队列；该指令不能中止 strike')
    await load(true)
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    submitting.value = false
  }
}

function startPolling() {
  stopPolling()
  refreshTimer = window.setInterval(() => load(true), 2000)
  clockTimer = window.setInterval(() => { now.value = Date.now() }, 1000)
}

function stopPolling() {
  if (refreshTimer !== undefined) window.clearInterval(refreshTimer)
  if (clockTimer !== undefined) window.clearInterval(clockTimer)
  refreshTimer = undefined
  clockTimer = undefined
}

watch(() => [props.modelValue, props.asset?.id] as const, ([visible]) => {
  if (!visible || !props.asset) {
    stopPolling()
    return
  }
  state.value = null
  operations.value = []
  load()
  startPolling()
}, { immediate: true })

onBeforeUnmount(stopPolling)
</script>

<template>
  <el-drawer
    :model-value="modelValue"
    :title="asset ? `${asset.name} · 功放控制` : '功放控制'"
    size="620px"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div v-loading="loading" class="amplifier-control">
      <el-alert
        title="真实设备控制"
        description="全向模式依赖平台在 60 秒内发送关闭。设备硬保护为 120 秒，不能替代 60 秒业务上限。"
        type="warning"
        :closable="false"
        show-icon
      />

      <div class="state-grid">
        <article><span>盒子</span><strong>{{ telemetry?.asset_connectivity_status === 'online' ? '在线' : '离线或未知' }}</strong></article>
        <article><span>处置子系统</span><strong>{{ telemetry?.countermeasure_device_online === true ? '在线' : '离线或未知' }}</strong></article>
        <article><span>设备实际状态</span><strong>{{ stateLabel(state?.actual_state) }}</strong></article>
        <article><span>操作状态</span><strong>{{ activeOperation?.state || '--' }}</strong></article>
        <article><span>当前频段</span><strong>{{ state?.active_frequencies_mhz?.length ? state.active_frequencies_mhz.join(' / ') + ' MHz' : '--' }}</strong></article>
        <article><span>剩余时间</span><strong>{{ remainingSeconds === null ? '--' : `${remainingSeconds}s` }}</strong></article>
      </div>

      <el-alert
        v-if="!deviceGateOpen"
        title="盒子和处置子系统必须同时在线，才能开启功放"
        type="error"
        :closable="false"
        show-icon
      />

      <el-form label-width="110px" class="control-form">
        <el-form-item label="控制模式">
          <el-radio-group v-model="form.mode" :disabled="Boolean(activeOperation)">
            <el-radio-button value="omnidirectional_frequency">全向频段</el-radio-button>
            <el-radio-button value="target_coordinate">目标坐标</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="频段">
          <el-checkbox-group v-model="form.frequenciesMhz" :disabled="Boolean(activeOperation)">
            <el-checkbox v-for="frequency in supportedFrequencies" :key="frequency" :value="frequency">
              {{ (frequency / 1000).toFixed(1) }}G
            </el-checkbox>
          </el-checkbox-group>
        </el-form-item>
        <el-form-item label="持续时间">
          <el-input-number v-model="form.durationSeconds" :min="1" :max="60" :disabled="Boolean(activeOperation)" />
          <span class="field-unit">秒</span>
        </el-form-item>
        <template v-if="form.mode === 'target_coordinate'">
          <el-form-item label="目标经度"><el-input-number v-model="form.longitude" :min="-180" :max="180" :precision="6" /></el-form-item>
          <el-form-item label="目标纬度"><el-input-number v-model="form.latitude" :min="-90" :max="90" :precision="6" /></el-form-item>
          <el-alert title="坐标系固定为 WGS84；strike 下发后不能提前关闭" type="info" :closable="false" />
        </template>
        <el-form-item label="操作原因">
          <el-input v-model="form.reason" type="textarea" :rows="2" maxlength="200" show-word-limit :disabled="Boolean(activeOperation)" />
        </el-form-item>
      </el-form>

      <div class="actions">
        <el-button type="primary" :disabled="!canStart" :loading="submitting" @click="submitStart">开启功放</el-button>
        <el-button
          type="danger"
          :disabled="!activeOperation || activeOperation.mode !== 'omnidirectional_frequency'"
          :loading="submitting"
          @click="submitStop"
        >手动关闭全向功放</el-button>
        <el-button type="danger" plain :loading="submitting" @click="submitEmergencyStop">紧急关闭</el-button>
      </div>

      <h3>最近操作</h3>
      <el-table :data="operations" size="small" max-height="260">
        <el-table-column label="时间" width="165"><template #default="{ row }">{{ new Date(row.requested_at).toLocaleString('zh-CN') }}</template></el-table-column>
        <el-table-column label="模式" width="100"><template #default="{ row }">{{ modeLabel(row.mode) }}</template></el-table-column>
        <el-table-column prop="requested_duration_seconds" label="时长/s" width="75" />
        <el-table-column prop="state" label="状态" min-width="150" />
      </el-table>
    </div>
  </el-drawer>
</template>

<style scoped>
.amplifier-control { display: grid; gap: 18px; }
.state-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.state-grid article { padding: 12px; border: 1px solid var(--el-border-color); border-radius: 6px; }
.state-grid span, .state-grid strong { display: block; }
.state-grid span { color: var(--el-text-color-secondary); font-size: 12px; margin-bottom: 4px; }
.control-form { border-top: 1px solid var(--el-border-color); padding-top: 18px; }
.field-unit { margin-left: 8px; color: var(--el-text-color-secondary); }
.actions { display: flex; flex-wrap: wrap; gap: 8px; }
h3 { margin: 0; }
</style>
