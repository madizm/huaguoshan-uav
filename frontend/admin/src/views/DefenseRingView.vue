<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Aim, Plus, Refresh } from '@element-plus/icons-vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import DefenseRingMap from '../components/DefenseRingMap.vue'
import {
  DEFENSE_RING_CODES,
  getDefenseRingConfig,
  saveDefenseRingConfig,
  saveDefenseRiskScores,
  type DefenseRingConfig,
  type ProtectedObject,
} from '../api/defenseRings'

const RING_NAMES = ['感知圈', '跟踪圈', '反制圈', '硬打击圈', '核心圈']
const RING_COLORS = ['#14b8a6', '#3b82f6', '#eab308', '#f97316', '#dc2626']
const DEFAULT_RADII = [5000, 4000, 3000, 2000, 1000]
const DEFAULT_PRIORITIES = [100, 200, 300, 400, 500]
const SCORE_ROWS = [
  ['zone_sensing', '感知圈基础分'],
  ['zone_tracking', '跟踪圈基础分'],
  ['zone_countermeasure', '反制圈基础分'],
  ['zone_hard_strike', '硬打击圈基础分'],
  ['zone_core', '核心圈基础分'],
  ['continuous_approach', '持续接近'],
  ['fast_approach', '快速接近'],
  ['next_ring_eta_60', '下一圈 ETA ≤ 60 秒'],
  ['next_ring_eta_30', '下一圈 ETA ≤ 30 秒'],
  ['identity_unverified', '身份未核实'],
  ['weight_class_micro', '微型无人机 (<250g)'],
  ['weight_class_light', '轻型无人机 (250g-4kg)'],
  ['weight_class_small', '小型无人机 (4-25kg)'],
  ['weight_class_medium', '中型无人机 (25-150kg)'],
  ['weight_class_large', '大型无人机 (>150kg)'],
] as const

const loading = ref(false)
const saving = ref(false)
const savingScores = ref(false)
const data = ref<DefenseRingConfig>({ objects: [], rules: null })
const selectedId = ref<number | 'new'>('new')
const mapRef = ref<InstanceType<typeof DefenseRingMap>>()
const form = reactive({ name: '', longitude: null as number | null, latitude: null as number | null, enabled: true })
const ringRows = reactive(DEFENSE_RING_CODES.map((code, index) => ({
  code, name: RING_NAMES[index], color: RING_COLORS[index], radius: DEFAULT_RADII[index], priority: DEFAULT_PRIORITIES[index],
})))
const scores = reactive<Record<string, number>>(Object.fromEntries(SCORE_ROWS.map(([code]) => [code, 0])))

const selectedObject = computed(() => data.value.objects.find((item) => item.id === selectedId.value) ?? null)
const mapRings = computed(() => ringRows.map((ring) => ({ code: ring.code, name: ring.name, radius: Number(ring.radius) || 0, color: ring.color })))
const objectSummary = computed(() => ({
  total: data.value.objects.length,
  enabled: data.value.objects.filter((item) => item.enabled).length,
  disabled: data.value.objects.filter((item) => !item.enabled).length,
}))

function resetForm(object: ProtectedObject | null) {
  form.name = object?.name ?? ''
  form.longitude = object ? Number(object.longitude) : null
  form.latitude = object ? Number(object.latitude) : null
  form.enabled = object?.enabled ?? true
  ringRows.forEach((row, index) => {
    const ring = object?.rings.find((item) => item.code === row.code)
    row.radius = Number(ring?.radius_m ?? DEFAULT_RADII[index])
    row.priority = Number(ring?.priority ?? DEFAULT_PRIORITIES[index])
  })
}

function applyScores() {
  for (const [code] of SCORE_ROWS) scores[code] = Number(data.value.rules?.factors[code]?.score ?? 0)
}

function selectObject(value: number | 'new') {
  selectedId.value = value
  resetForm(value === 'new' ? null : data.value.objects.find((item) => item.id === value) ?? null)
  requestAnimationFrame(() => mapRef.value?.locate())
}

async function load(showSuccess = false, preferredId?: number) {
  loading.value = true
  try {
    data.value = await getDefenseRingConfig()
    if (preferredId && data.value.objects.some((item) => item.id === preferredId)) selectedId.value = preferredId
    else if (selectedId.value !== 'new' && !data.value.objects.some((item) => item.id === selectedId.value)) selectedId.value = data.value.objects[0]?.id ?? 'new'
    else if (selectedId.value === 'new' && data.value.objects.length && !showSuccess) selectedId.value = data.value.objects[0].id
    resetForm(selectedObject.value)
    applyScores()
    if (showSuccess) ElMessage.success('防御圈配置已刷新')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function validateRings() {
  if (!form.name.trim()) throw new Error('请输入保护对象名称')
  if (form.longitude == null || form.latitude == null || form.longitude < -180 || form.longitude > 180 || form.latitude < -90 || form.latitude > 90) throw new Error('请输入有效的 WGS84 经纬度')
  ringRows.forEach((ring, index) => {
    if (!Number.isFinite(ring.radius) || ring.radius <= 0 || ring.radius > 100000) throw new Error(`${ring.name}半径须在 0～100000 米之间`)
    if (!Number.isSafeInteger(ring.priority)) throw new Error(`${ring.name}优先级须为整数`)
    if (index > 0 && (ring.radius >= ringRows[index - 1].radius || ring.priority <= ringRows[index - 1].priority)) throw new Error('半径须由外向内严格递减，优先级须严格递增')
  })
}

async function publishRings() {
  try {
    validateRings()
    await ElMessageBox.confirm('发布后将生成完整的新版本，历史圆心、半径和优先级保持不变。确认发布？', '发布防御圈配置', { type: 'warning', confirmButtonText: '确认发布' })
    saving.value = true
    const current = selectedObject.value
    const result = await saveDefenseRingConfig({
      id: current?.id ?? null, expected_version: current?.version ?? 0, name: form.name.trim(),
      longitude: form.longitude!, latitude: form.latitude!, enabled: form.enabled,
      radii_m: ringRows.map((ring) => Number(ring.radius)), priorities: ringRows.map((ring) => Number(ring.priority)),
    })
    await load(false, result.id)
    ElMessage.success(`防御圈配置 v${result.version} 已发布`)
  } catch (error) {
    if (error !== 'cancel' && error !== 'close') ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}

function validateScores() {
  for (const [code, name] of SCORE_ROWS) {
    const value = scores[code]
    if (!Number.isInteger(value) || value < 0 || value > 100) throw new Error(`${name}须为 0～100 整数`)
  }
  const zoneScores = DEFENSE_RING_CODES.map((code) => scores[`zone_${code}`])
  if (zoneScores[0] < 20 || zoneScores.some((value, index) => index > 0 && value <= zoneScores[index - 1])) throw new Error('圈层基础分须由外向内严格递增，感知圈至少 20 分')
}

async function publishScores() {
  if (!data.value.rules) return
  try {
    validateScores()
    await ElMessageBox.confirm('修改评分将发布新规则版本，历史评分规则不会改写。确认发布？', '发布评分版本', { type: 'warning', confirmButtonText: '确认发布' })
    savingScores.value = true
    const result = await saveDefenseRiskScores(data.value.rules.version, { ...scores })
    await load()
    ElMessage.success(`评分规则 v${result.version} 已发布`)
  } catch (error) {
    if (error !== 'cancel' && error !== 'close') ElMessage.error((error as Error).message)
  } finally {
    savingScores.value = false
  }
}

function updateCenter(longitude: number, latitude: number) { form.longitude = longitude; form.latitude = latitude }
onMounted(() => load())
</script>

<template>
  <section v-loading="loading" class="defense-page">
    <div class="summary-grid">
      <article><span>保护对象</span><strong>{{ objectSummary.total }}</strong></article>
      <article data-tone="success"><span>已启用</span><strong>{{ objectSummary.enabled }}</strong></article>
      <article data-tone="muted"><span>已停用</span><strong>{{ objectSummary.disabled }}</strong></article>
      <article><span>评分版本</span><strong>v{{ data.rules?.version ?? '--' }}</strong></article>
    </div>

    <div class="page-toolbar">
      <el-select :model-value="selectedId" class="object-select" @change="selectObject">
        <el-option label="新建保护对象" value="new" />
        <el-option v-for="item in data.objects" :key="item.id" :label="`${item.name}（v${item.version}${item.enabled ? '' : ' · 已停用'}）`" :value="item.id" />
      </el-select>
      <el-button :icon="Plus" @click="selectObject('new')">新建</el-button>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Aim" :disabled="form.longitude == null" @click="mapRef?.locate()">定位圆心</el-button>
      <el-button :icon="Refresh" :loading="loading" @click="load(true)">刷新</el-button>
    </div>

    <el-alert title="反制圈、硬打击圈仅表示空间层级，不会触发真实设备动作；所有圈层均为二维距离，不按目标高度筛选。" type="info" :closable="false" />

    <div class="editor-grid">
      <div class="form-panel">
        <div class="panel-heading"><div><strong>{{ selectedObject ? '编辑保护对象' : '新建保护对象' }}</strong><span>{{ selectedObject ? `当前配置 v${selectedObject.version}` : '首次发布将创建 v1' }}</span></div></div>
        <el-form label-position="top">
          <el-form-item label="保护对象名称"><el-input v-model="form.name" maxlength="120" show-word-limit /></el-form-item>
          <div class="coordinate-grid">
            <el-form-item label="经度（WGS84）"><el-input-number v-model="form.longitude" :min="-180" :max="180" :precision="7" controls-position="right" /></el-form-item>
            <el-form-item label="纬度（WGS84）"><el-input-number v-model="form.latitude" :min="-90" :max="90" :precision="7" controls-position="right" /></el-form-item>
          </div>
          <el-form-item label="启用状态"><el-switch v-model="form.enabled" active-text="启用" inactive-text="停用" /></el-form-item>
        </el-form>

        <div class="ring-table">
          <div class="ring-header"><span>圈层</span><span>半径（米）</span><span>选圈优先级</span></div>
          <div v-for="ring in ringRows" :key="ring.code" class="ring-row">
            <span class="ring-name"><i :style="{ backgroundColor: ring.color }" />{{ ring.name }}</span>
            <el-input-number v-model="ring.radius" :min="1" :max="100000" :step="100" controls-position="right" />
            <el-input-number v-model="ring.priority" :step="10" :precision="0" controls-position="right" />
          </div>
        </div>
        <el-button type="primary" :loading="saving" class="publish-button" @click="publishRings">发布五层配置</el-button>
      </div>

      <DefenseRingMap ref="mapRef" :longitude="form.longitude" :latitude="form.latitude" :rings="mapRings" @update:center="updateCenter" />
    </div>

    <div class="score-panel">
      <div class="panel-heading"><div><strong>风险评分因子</strong><span>当前规则 v{{ data.rules?.version ?? '--' }}；发布后生成新版本</span></div><el-button type="primary" :loading="savingScores" :disabled="!data.rules" @click="publishScores">发布评分版本</el-button></div>
      <div v-if="data.rules" class="score-grid">
        <label v-for="([code, name]) in SCORE_ROWS" :key="code"><span>{{ name }}</span><el-input-number v-model="scores[code]" :min="0" :max="100" :precision="0" controls-position="right" /></label>
      </div>
      <el-empty v-else description="暂无评分规则" :image-size="72" />
    </div>
  </section>
</template>

<style scoped>
.defense-page { display: grid; gap: 16px; }
.summary-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.summary-grid article { display: flex; align-items: flex-end; justify-content: space-between; min-height: 72px; padding: 14px 16px; border: 1px solid #dfe4e1; border-left: 3px solid #28a36a; border-radius: 6px; background: #fff; }
.summary-grid article[data-tone="success"] { border-left-color: #16a34a; }
.summary-grid article[data-tone="muted"] { border-left-color: #94a3b8; }
.summary-grid span { color: #69736e; font-size: 13px; }
.summary-grid strong { color: #202522; font-size: 24px; }
.page-toolbar { display: flex; align-items: center; gap: 10px; }
.page-toolbar-spacer { flex: 1; }
.object-select { width: min(420px, 48vw); }
.editor-grid { display: grid; grid-template-columns: minmax(430px, 0.8fr) minmax(500px, 1.2fr); gap: 16px; align-items: stretch; }
.form-panel, .score-panel { padding: 18px; border: 1px solid #dfe4e1; border-radius: 6px; background: #fff; }
.panel-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 16px; }
.panel-heading strong, .panel-heading span { display: block; }
.panel-heading strong { color: #202522; font-size: 16px; }
.panel-heading span { margin-top: 4px; color: #7a847f; font-size: 12px; }
.coordinate-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.coordinate-grid :deep(.el-input-number), .ring-row :deep(.el-input-number), .score-grid :deep(.el-input-number) { width: 100%; }
.ring-table { overflow: hidden; margin-top: 4px; border: 1px solid #e3e7e5; border-radius: 5px; }
.ring-header, .ring-row { display: grid; grid-template-columns: minmax(110px, .8fr) minmax(130px, 1fr) minmax(130px, 1fr); gap: 10px; align-items: center; padding: 10px 12px; }
.ring-header { background: #f3f5f4; color: #59635e; font-size: 12px; font-weight: 600; }
.ring-row + .ring-row { border-top: 1px solid #edf0ee; }
.ring-name { display: flex; align-items: center; gap: 8px; color: #303833; font-weight: 600; }
.ring-name i { width: 10px; height: 10px; border-radius: 50%; }
.publish-button { width: 100%; margin-top: 16px; }
.score-grid { display: grid; grid-template-columns: repeat(5, minmax(150px, 1fr)); gap: 14px; }
.score-grid label { display: grid; gap: 7px; color: #4e5853; font-size: 13px; }
@media (max-width: 1180px) { .editor-grid { grid-template-columns: 1fr; } .score-grid { grid-template-columns: repeat(2, minmax(150px, 1fr)); } }
@media (max-width: 760px) { .summary-grid { grid-template-columns: repeat(2, 1fr); } .page-toolbar { flex-wrap: wrap; } .object-select { width: 100%; } .coordinate-grid { grid-template-columns: 1fr; } .ring-header, .ring-row { grid-template-columns: 1fr; } .ring-header { display: none; } .score-grid { grid-template-columns: 1fr; } }
</style>
