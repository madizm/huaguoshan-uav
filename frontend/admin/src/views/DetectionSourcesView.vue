<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Edit, Refresh, Search } from '@element-plus/icons-vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import type { FormInstance, FormRules, TagProps } from 'element-plus'
import DetectionMethodManager from '../components/DetectionMethodManager.vue'
import { listAssets, type EquipmentAsset } from '../api/equipment'
import {
  listDetectionSources,
  updateDetectionSource,
  type ConnectorState,
  type DetectionObservationSource,
} from '../api/detection'

const sources = ref<DetectionObservationSource[]>([])
const assets = ref<EquipmentAsset[]>([])
const loading = ref(false)
const filters = reactive({ keyword: '', state: '', enabled: '' })

const drawerVisible = ref(false)
const editingSource = ref<DetectionObservationSource | null>(null)
const formRef = ref<FormInstance>()
const saving = ref(false)
const form = reactive({
  name: '',
  assetId: null as number | null,
  sourceTimezone: 'Asia/Shanghai',
  lostTimeoutSeconds: 30,
  enabled: true,
})

const rules: FormRules = {
  name: [{ required: true, message: '请输入来源名称', trigger: 'blur' }],
  assetId: [{ required: true, message: '请选择映射设备资产', trigger: 'change' }],
  sourceTimezone: [{ required: true, message: '请选择来源时区', trigger: 'change' }],
  lostTimeoutSeconds: [{ required: true, message: '请输入目标丢失宽限', trigger: 'blur' }],
}

const filteredSources = computed(() => {
  const keyword = filters.keyword.trim().toLocaleLowerCase()
  return sources.value.filter((source) => {
    const matchesKeyword = !keyword || [
      source.name,
      source.source_system,
      source.station_id,
      source.box_code,
      source.asset_code,
      source.asset_name,
    ].some((value) => String(value ?? '').toLocaleLowerCase().includes(keyword))
    const matchesState = !filters.state || normalizedState(source) === filters.state
    const matchesEnabled = filters.enabled === '' || source.enabled === (filters.enabled === 'true')
    return matchesKeyword && matchesState && matchesEnabled
  })
})

const summary = computed(() => ({
  total: sources.value.length,
  connected: sources.value.filter((source) => source.enabled && source.connector_state === 'connected').length,
  unhealthy: sources.value.filter((source) => source.enabled && ['disconnected', 'degraded'].includes(source.connector_state ?? '')).length,
  disabled: sources.value.filter((source) => !source.enabled).length,
}))

function normalizedState(source: DetectionObservationSource): string {
  if (!source.enabled) return 'disabled'
  return source.connector_state ?? 'unknown'
}

function stateLabel(source: DetectionObservationSource): string {
  return {
    connected: '已连接',
    disconnected: '已断开',
    degraded: '异常',
    unknown: '未知',
    disabled: '已停用',
  }[normalizedState(source)] ?? '未知'
}

function stateTagType(source: DetectionObservationSource): TagProps['type'] {
  return {
    connected: 'success',
    disconnected: 'danger',
    degraded: 'warning',
    unknown: 'info',
    disabled: 'info',
  }[normalizedState(source)] as TagProps['type']
}

function formatTime(value: string | null): string {
  return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '--'
}

function formatRelativeTime(value: string | null): string {
  if (!value) return '尚无消息'
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  if (seconds < 60) return `${seconds} 秒前`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`
  return `${Math.floor(seconds / 86400)} 天前`
}

function messageIsStale(source: DetectionObservationSource): boolean {
  if (!source.last_message_at || !source.enabled) return false
  const ageSeconds = (Date.now() - new Date(source.last_message_at).getTime()) / 1000
  return ageSeconds > Math.max(60, source.lost_timeout_seconds * 2)
}

async function loadSources(showSuccess = false) {
  loading.value = true
  try {
    sources.value = await listDetectionSources()
    if (showSuccess) ElMessage.success('侦测来源状态已刷新')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function loadAssetOptions() {
  try {
    const result = await listAssets({ limit: 1000, offset: 0 })
    assets.value = result.rows
  } catch (error) {
    ElMessage.error(`设备资产加载失败：${(error as Error).message}`)
  }
}

function openEdit(source: DetectionObservationSource) {
  editingSource.value = source
  Object.assign(form, {
    name: source.name,
    assetId: source.asset_id,
    sourceTimezone: source.source_timezone,
    lostTimeoutSeconds: source.lost_timeout_seconds,
    enabled: source.enabled,
  })
  drawerVisible.value = true
}

async function save() {
  await formRef.value?.validate()
  if (!editingSource.value || form.assetId === null) return
  if (editingSource.value.enabled && !form.enabled) {
    await ElMessageBox.confirm(
      '停用后，接入函数将拒绝该来源的新观测。正在运行的连接器会持续重试，确认停用？',
      '停用侦测来源',
      { type: 'warning', confirmButtonText: '确认停用' },
    )
  }
  saving.value = true
  try {
    await updateDetectionSource(editingSource.value.id, {
      name: form.name,
      assetId: form.assetId,
      sourceTimezone: form.sourceTimezone,
      lostTimeoutSeconds: form.lostTimeoutSeconds,
      enabled: form.enabled,
    })
    ElMessage.success('侦测来源配置已保存')
    drawerVisible.value = false
    await loadSources()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}

onMounted(() => {
  loadSources()
  loadAssetOptions()
})
</script>

<template>
  <section class="source-page">
    <div class="summary-grid" aria-label="侦测来源状态汇总">
      <article>
        <span>来源总数</span>
        <strong>{{ summary.total }}</strong>
      </article>
      <article data-tone="success">
        <span>链路已连接</span>
        <strong>{{ summary.connected }}</strong>
      </article>
      <article data-tone="warning">
        <span>断开或异常</span>
        <strong>{{ summary.unhealthy }}</strong>
      </article>
      <article data-tone="muted">
        <span>已停用</span>
        <strong>{{ summary.disabled }}</strong>
      </article>
    </div>

    <div class="page-toolbar">
      <el-input
        v-model="filters.keyword"
        clearable
        placeholder="名称 / 站点 / 盒子 / 资产"
        :prefix-icon="Search"
        class="keyword-input"
      />
      <el-select v-model="filters.state" clearable placeholder="全部链路状态" class="state-select">
        <el-option label="已连接" value="connected" />
        <el-option label="已断开" value="disconnected" />
        <el-option label="异常" value="degraded" />
        <el-option label="未知" value="unknown" />
        <el-option label="已停用" value="disabled" />
      </el-select>
      <el-select v-model="filters.enabled" clearable placeholder="全部启停状态" class="enabled-select">
        <el-option label="已启用" value="true" />
        <el-option label="已停用" value="false" />
      </el-select>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Refresh" :loading="loading" @click="loadSources(true)">刷新状态</el-button>
    </div>

    <div class="table-shell">
      <el-table v-loading="loading" :data="filteredSources" stripe>
        <el-table-column label="来源" min-width="190">
          <template #default="{ row }">
            <div class="primary-cell">
              <strong>{{ row.name }}</strong>
              <span>{{ row.source_system }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="站点 / 盒子" min-width="190">
          <template #default="{ row }">
            <div class="primary-cell">
              <strong>站点 {{ row.station_id }}</strong>
              <span>{{ row.box_code || '未登记盒子编码' }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="映射设备资产" min-width="210">
          <template #default="{ row }">
            <div class="primary-cell">
              <strong>{{ row.asset_name }}</strong>
              <span>{{ row.asset_code }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="接入链路" width="130">
          <template #default="{ row }">
            <el-tag :type="stateTagType(row)" effect="light">{{ stateLabel(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="最近合法消息" min-width="180">
          <template #default="{ row }">
            <div class="primary-cell" :class="{ stale: messageIsStale(row) }">
              <strong>{{ formatRelativeTime(row.last_message_at) }}</strong>
              <span>{{ formatTime(row.last_message_at) }}</span>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="最近快照对账" width="180">
          <template #default="{ row }">{{ formatTime(row.last_snapshot_at) }}</template>
        </el-table-column>
        <el-table-column label="最近错误" min-width="170">
          <template #default="{ row }">
            <div v-if="row.last_error_code" class="error-cell">
              <strong>{{ row.last_error_code }}</strong>
              <span>{{ formatTime(row.last_error_at) }}</span>
            </div>
            <span v-else class="empty-value">--</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="92">
          <template #default="{ row }">
            <el-button text type="primary" :icon="Edit" @click="openEdit(row)">配置</el-button>
          </template>
        </el-table-column>
        <template #empty>
          <el-empty description="没有符合条件的侦测来源" />
        </template>
      </el-table>
    </div>

    <el-drawer v-model="drawerVisible" title="配置侦测来源" size="480px" destroy-on-close>
      <template v-if="editingSource">
        <el-descriptions :column="1" border size="small" class="source-identity">
          <el-descriptions-item label="来源系统">{{ editingSource.source_system }}</el-descriptions-item>
          <el-descriptions-item label="站点 ID">{{ editingSource.station_id }}</el-descriptions-item>
          <el-descriptions-item label="盒子编码">{{ editingSource.box_code || '--' }}</el-descriptions-item>
          <el-descriptions-item label="坐标系统">{{ editingSource.coordinate_system }}</el-descriptions-item>
        </el-descriptions>

        <el-form ref="formRef" :model="form" :rules="rules" label-width="110px">
          <el-form-item label="来源名称" prop="name">
            <el-input v-model="form.name" />
          </el-form-item>
          <el-form-item label="设备资产" prop="assetId">
            <el-select v-model="form.assetId" filterable style="width: 100%">
              <el-option
                v-for="asset in assets"
                :key="asset.id"
                :label="`${asset.name}（${asset.asset_code}）`"
                :value="asset.id"
                :disabled="asset.lifecycle_status !== 'active' && asset.id !== form.assetId"
              />
            </el-select>
          </el-form-item>
          <el-form-item label="来源时区" prop="sourceTimezone">
            <el-select v-model="form.sourceTimezone" style="width: 100%">
              <el-option label="中国标准时间（Asia/Shanghai）" value="Asia/Shanghai" />
              <el-option label="协调世界时（UTC）" value="UTC" />
            </el-select>
          </el-form-item>
          <el-form-item label="丢失宽限" prop="lostTimeoutSeconds">
            <el-input-number
              v-model="form.lostTimeoutSeconds"
              :min="5"
              :max="3600"
              :step="5"
              controls-position="right"
              style="width: 180px"
            />
            <span class="unit-label">秒</span>
          </el-form-item>
          <el-form-item label="接入状态">
            <el-switch v-model="form.enabled" inline-prompt active-text="启用" inactive-text="停用" />
          </el-form-item>
        </el-form>
      </template>
      <template #footer>
        <el-button @click="drawerVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存配置</el-button>
      </template>
    </el-drawer>
    <DetectionMethodManager />
  </section>
</template>

<style scoped>
.summary-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(150px, 1fr));
  gap: 12px;
  margin-bottom: 18px;
}
.summary-grid article {
  min-height: 86px;
  padding: 15px 18px;
  border: 1px solid #dfe4e1;
  border-left: 4px solid #68736d;
  border-radius: 6px;
  background: #fff;
}
.summary-grid article[data-tone='success'] {
  border-left-color: #28a36a;
}
.summary-grid article[data-tone='warning'] {
  border-left-color: #d99024;
}
.summary-grid article[data-tone='muted'] {
  border-left-color: #9aa39e;
}
.summary-grid span,
.primary-cell span,
.error-cell span {
  display: block;
  color: #78827d;
  font-size: 12px;
}
.summary-grid strong {
  display: block;
  margin-top: 6px;
  font-size: 26px;
  line-height: 1;
}
.keyword-input {
  width: 280px;
}
.state-select {
  width: 160px;
}
.enabled-select {
  width: 150px;
}
.primary-cell strong,
.error-cell strong {
  display: block;
  margin-bottom: 3px;
  font-size: 14px;
  font-weight: 600;
}
.primary-cell.stale strong,
.error-cell strong {
  color: #c45656;
}
.empty-value {
  color: #a3aaa6;
}
.source-identity {
  margin-bottom: 24px;
}
.unit-label {
  margin-left: 8px;
  color: #78827d;
}
@media (max-width: 980px) {
  .summary-grid {
    grid-template-columns: repeat(2, minmax(140px, 1fr));
  }
}
@media (max-width: 600px) {
  .summary-grid {
    grid-template-columns: 1fr;
  }
  .keyword-input,
  .state-select,
  .enabled-select {
    width: 100%;
  }
}
</style>
