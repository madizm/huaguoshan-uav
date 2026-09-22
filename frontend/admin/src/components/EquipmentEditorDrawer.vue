<script setup lang="ts">
import { computed, defineAsyncComponent, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import type { FormInstance, FormRules } from 'element-plus'
import {
  getEquipmentConfiguration,
  listCapabilityCatalog,
  listRadarModels,
  saveEquipmentConfiguration,
  type AssetCategory,
  type AssetCapabilityConfiguration,
  type AssetCoverageConfiguration,
  type CapabilityCatalogItem,
  type DispatchResourceConfiguration,
  type EquipmentAsset,
  type RadarModel,
} from '../api/equipment'
import { emptyProfile, equipmentProfileFields } from '../equipmentProfiles'
import {
  generateCapabilityCoverage,
  readCapabilityRangeParameters,
  validateCapabilityRangeParameters,
  type CapabilityRangeParameters,
  type CoverageGenerationMode,
} from '../capabilityCoverage'
const CoverageMapDialog = defineAsyncComponent(() => import('./CoverageMapDialog.vue'))

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{
  asset: EquipmentAsset | null
  categories: AssetCategory[]
}>()
const emit = defineEmits<{ saved: [] }>()

const isEdit = computed(() => props.asset !== null)
const categoryName = computed(() => props.categories.find((item) => item.code === form.category_code)?.name ?? '设备')
const drawerTitle = computed(() => `${isEdit.value ? '编辑' : '新增'}${categoryName.value}`)
const profileFields = computed(() => equipmentProfileFields[form.category_code] ?? [])
const isSensitive = computed(() => ['counter_uas', 'jamming_device', 'directed_energy_device'].includes(form.category_code))

const formRef = ref<FormInstance>()
const saving = ref(false)
const loading = ref(false)
const radarModels = ref<RadarModel[]>([])
const capabilityCatalog = ref<CapabilityCatalogItem[]>([])
const capabilities = ref<AssetCapabilityConfiguration[]>([])
const capabilityToAdd = ref('')
interface SensorChannelDraft {
  channel_code: string
  metric_code: string
  unit: string
  warning_threshold_text: string
}
const sensorChannels = ref<SensorChannelDraft[]>([])
interface CoverageDraft extends Omit<AssetCoverageConfiguration, 'coverage_geom'> {
  coverage_geom_text: string
  generation_mode: CoverageGenerationMode
  radius_m: number | null
  azimuth_start_deg: number | null
  azimuth_end_deg: number | null
}
const coverages = ref<CoverageDraft[]>([])
const coverageMapVisible = ref(false)
const editingCoverageIndex = ref(-1)
const capabilityParameterVisible = ref(false)
const editingCapabilityIndex = ref(-1)
const capabilityParameterForm = reactive<CapabilityRangeParameters>({
  min_range_m: null,
  max_range_m: null,
  range_basis: 'vendor_spec',
  frequency_min_mhz: null,
  frequency_max_mhz: null,
  positioning_mode: '',
})
const editingCoverageGeojson = computed({
  get: () => coverages.value[editingCoverageIndex.value]?.coverage_geom_text ?? '',
  set: (value: string) => {
    const coverage = coverages.value[editingCoverageIndex.value]
    if (coverage) {
      coverage.coverage_geom_text = value
      coverage.generation_mode = 'manual'
      coverage.metadata = { ...coverage.metadata, coverage_model: 'manual' }
    }
  },
})
const dispatchEnabled = ref(false)
const dispatchResource = reactive<DispatchResourceConfiguration>({
  resource_role: '', active: true, available_from: null, available_to: null, metadata: {},
})
const profile = reactive<Record<string, unknown>>({})
const form = reactive({
  asset_code: '',
  category_code: '',
  type_code: '',
  name: '',
  managing_unit_name: '',
  deployment_mode: 'fixed',
  longitude: null as number | null,
  latitude: null as number | null,
  elevation_amsl_m: null as number | null,
  manufacturer: '',
  model: '',
  serial_no: '',
  is_simulated: false,
  updated_at: '',
})

const rules: FormRules = {
  asset_code: [{ required: true, message: '请输入资产编码', trigger: 'blur' }],
  category_code: [{ required: true, message: '请选择设备类别', trigger: 'change' }],
  name: [{ required: true, message: '请输入设备名称', trigger: 'blur' }],
  longitude: [{ required: true, message: '请输入经度', trigger: 'blur' }],
  latitude: [{ required: true, message: '请输入纬度', trigger: 'blur' }],
}

const radarModelCode = computed({
  get: () => String(profile.model_code ?? ''),
  set: (code: string) => {
    profile.model_code = code
    const model = radarModels.value.find((item) => item.model_code === code)
    if (model) profile.face_count = model.scan_mode === 'four_face_phase' ? 4 : 1
  },
})
const selectedRadarModel = computed(() => radarModels.value.find((item) => item.model_code === radarModelCode.value) ?? null)
const dispatchable = computed(() => ['uav', 'unmanned_vehicle', 'vehicle_surveillance', 'video_surveillance'].includes(form.category_code))
const availableCapabilities = computed(() => capabilityCatalog.value.filter(
  (item) => !capabilities.value.some((assigned) => assigned.capability_code === item.code),
))
const accessLevels = [
  { value: 'observable', label: '可观测' },
  { value: 'recommendable', label: '可推荐' },
  { value: 'linkable', label: '可联动' },
  { value: 'controllable', label: '可控制' },
] as const

function resetForm() {
  Object.assign(form, {
    asset_code: '', category_code: '', type_code: '', name: '', managing_unit_name: '',
    deployment_mode: 'fixed', longitude: null, latitude: null, elevation_amsl_m: null,
    manufacturer: '', model: '', serial_no: '', is_simulated: false, updated_at: '',
  })
  for (const key of Object.keys(profile)) delete profile[key]
}

function resetProfile(categoryCode: string) {
  for (const key of Object.keys(profile)) delete profile[key]
  Object.assign(profile, emptyProfile(categoryCode))
}
function resetRelatedConfiguration() {
  capabilities.value = []
  sensorChannels.value = []
  coverages.value = []
  dispatchEnabled.value = false
  Object.assign(dispatchResource, {
    resource_role: '', active: true, available_from: null, available_to: null, metadata: {},
  })
}

async function ensureRadarModels() {
  if (radarModels.value.length === 0) radarModels.value = await listRadarModels()
}

async function categoryChanged(categoryCode: string) {
  resetProfile(categoryCode)
  resetRelatedConfiguration()
  if (categoryCode === 'microwave_radar') await ensureRadarModels()
}

watch(visible, async (open) => {
  if (!open) return
  resetForm()
  resetRelatedConfiguration()
  formRef.value?.clearValidate()
  loading.value = true
  try {
    if (capabilityCatalog.value.length === 0) capabilityCatalog.value = await listCapabilityCatalog()
    if (!props.asset) return
    const configuration = await getEquipmentConfiguration(props.asset.id)
    const asset = configuration.asset
    Object.assign(form, {
      asset_code: asset.asset_code,
      category_code: asset.category_code,
      type_code: asset.type_code ?? '',
      name: asset.name,
      managing_unit_name: asset.managing_unit_name ?? '',
      deployment_mode: asset.deployment_mode ?? 'fixed',
      longitude: asset.longitude,
      latitude: asset.latitude,
      elevation_amsl_m: asset.elevation_amsl_m,
      manufacturer: asset.manufacturer ?? '',
      model: asset.model ?? '',
      serial_no: asset.serial_no ?? '',
      is_simulated: asset.is_simulated,
      updated_at: asset.updated_at,
    })
    resetProfile(asset.category_code)
    Object.assign(profile, configuration.profile)
    capabilities.value = configuration.capabilities
    coverages.value = configuration.coverages.map((coverage) => ({
      id: coverage.id,
      capability_code: coverage.capability_code,
      coverage_geom_text: JSON.stringify(coverage.coverage_geom),
      min_height_amsl_m: coverage.min_height_amsl_m,
      max_height_amsl_m: coverage.max_height_amsl_m,
      valid_from: coverage.valid_from,
      valid_to: coverage.valid_to,
      metadata: coverage.metadata ?? {},
      generation_mode: ['radial', 'sector'].includes(String(coverage.metadata?.coverage_model))
        ? coverage.metadata?.coverage_model as CoverageGenerationMode : 'manual',
      radius_m: typeof coverage.metadata?.radius_m === 'number' ? coverage.metadata.radius_m : null,
      azimuth_start_deg: typeof coverage.metadata?.azimuth_start_deg === 'number' ? coverage.metadata.azimuth_start_deg : null,
      azimuth_end_deg: typeof coverage.metadata?.azimuth_end_deg === 'number' ? coverage.metadata.azimuth_end_deg : null,
    }))
    sensorChannels.value = configuration.sensor_channels.map((channel) => ({
      channel_code: channel.channel_code,
      metric_code: channel.metric_code,
      unit: channel.unit ?? '',
      warning_threshold_text: JSON.stringify(channel.warning_threshold ?? {}),
    }))
    dispatchEnabled.value = configuration.dispatch_resource !== null
    if (configuration.dispatch_resource) Object.assign(dispatchResource, configuration.dispatch_resource)
    if (asset.category_code === 'microwave_radar') await ensureRadarModels()
  } catch (error) {
    ElMessage.error((error as Error).message)
    visible.value = false
  } finally {
    loading.value = false
  }
})

function profileText(key: string): string {
  const value = profile[key]
  return value == null ? '' : String(value)
}
function profileNumber(key: string): number | null {
  const value = profile[key]
  return typeof value === 'number' ? value : null
}
function profileTags(key: string): string[] {
  return Array.isArray(profile[key]) ? profile[key] as string[] : []
}
function setProfileText(key: string, value: string) {
  profile[key] = value === '' ? null : value
}
function setProfileValue(key: string, value: unknown) {
  profile[key] = value
}
function addCapability() {
  const item = capabilityCatalog.value.find((candidate) => candidate.code === capabilityToAdd.value)
  if (!item) return
  capabilities.value.push({
    capability_code: item.code,
    capability_name: item.name,
    capability_type: item.capability_type,
    access_level: 'observable',
    enabled: true,
    parameters: {},
  })
  capabilityToAdd.value = ''
}

function capabilityHasRange(capability: AssetCapabilityConfiguration): boolean {
  return capability.capability_type === 'detection'
    || ['electro_optical_observation', 'remote_id_identification'].includes(capability.capability_code)
}

function rangeSummary(capability: AssetCapabilityConfiguration): string {
  const values = readCapabilityRangeParameters(capability.parameters ?? {})
  if (values.max_range_m === null) return '未配置'
  const minimum = values.min_range_m === null ? '' : `${values.min_range_m}–`
  return `${minimum}${values.max_range_m} m`
}

function openCapabilityParameters(index: number) {
  const capability = capabilities.value[index]
  if (!capability) return
  editingCapabilityIndex.value = index
  Object.assign(capabilityParameterForm, readCapabilityRangeParameters(capability.parameters ?? {}))
  capabilityParameterVisible.value = true
}

function saveCapabilityParameters() {
  const error = validateCapabilityRangeParameters(capabilityParameterForm)
  if (error) {
    ElMessage.warning(error)
    return
  }
  const capability = capabilities.value[editingCapabilityIndex.value]
  if (!capability) return
  capability.parameters = {
    ...(capability.parameters ?? {}),
    min_range_m: capabilityParameterForm.min_range_m,
    max_range_m: capabilityParameterForm.max_range_m,
    range_basis: capabilityParameterForm.range_basis,
    frequency_min_mhz: capabilityParameterForm.frequency_min_mhz,
    frequency_max_mhz: capabilityParameterForm.frequency_max_mhz,
    positioning_mode: capabilityParameterForm.positioning_mode || null,
  }
  capabilityParameterVisible.value = false
}

function addSensorChannel() {
  sensorChannels.value.push({ channel_code: '', metric_code: '', unit: '', warning_threshold_text: '{}' })
}
function addCoverage() {
  coverages.value.push({
    capability_code: capabilities.value[0]?.capability_code ?? '',
    coverage_geom_text: '{"type":"Polygon","coordinates":[]}',
    min_height_amsl_m: null, max_height_amsl_m: null,
    valid_from: null, valid_to: null, metadata: {}, generation_mode: 'manual',
    radius_m: null, azimuth_start_deg: null, azimuth_end_deg: null,
  })
}
function openCoverageMap(index: number) {
  editingCoverageIndex.value = index
  coverageMapVisible.value = true
}

function generateCoverage(index: number) {
  const coverage = coverages.value[index]
  if (!coverage || coverage.generation_mode === 'manual') return
  if (form.longitude === null || form.latitude === null || coverage.radius_m === null) {
    ElMessage.warning('请先填写设备经纬度和覆盖半径')
    return
  }
  try {
    coverage.coverage_geom_text = JSON.stringify(generateCapabilityCoverage({
      longitude: form.longitude,
      latitude: form.latitude,
      radiusM: coverage.radius_m,
      mode: coverage.generation_mode,
      azimuthStartDeg: coverage.azimuth_start_deg ?? undefined,
      azimuthEndDeg: coverage.azimuth_end_deg ?? undefined,
    }))
    coverage.metadata = {
      ...coverage.metadata,
      coverage_model: coverage.generation_mode,
      radius_m: coverage.radius_m,
      generated_from_asset_position: true,
      ...(coverage.generation_mode === 'sector' ? {
        azimuth_start_deg: coverage.azimuth_start_deg,
        azimuth_end_deg: coverage.azimuth_end_deg,
      } : {}),
    }
    ElMessage.success('覆盖范围已根据设备位置生成')
  } catch (error) {
    ElMessage.warning((error as Error).message)
  }
}

function parseCoverages(): AssetCoverageConfiguration[] {
  return coverages.value.map((coverage, index) => {
    if (!coverage.capability_code) throw new Error(`第 ${index + 1} 个覆盖范围未选择能力`)
    if (coverage.generation_mode !== 'manual') {
      if (form.longitude === null || form.latitude === null || coverage.radius_m === null) {
        throw new Error(`第 ${index + 1} 个覆盖范围缺少设备位置或覆盖半径`)
      }
      coverage.coverage_geom_text = JSON.stringify(generateCapabilityCoverage({
        longitude: form.longitude,
        latitude: form.latitude,
        radiusM: coverage.radius_m,
        mode: coverage.generation_mode,
        azimuthStartDeg: coverage.azimuth_start_deg ?? undefined,
        azimuthEndDeg: coverage.azimuth_end_deg ?? undefined,
      }))
    }
    let geometry: Record<string, unknown>
    try {
      geometry = JSON.parse(coverage.coverage_geom_text)
    } catch {
      throw new Error(`第 ${index + 1} 个覆盖范围不是有效 GeoJSON`)
    }
    if (!['Polygon', 'MultiPolygon'].includes(String(geometry.type))) throw new Error(`第 ${index + 1} 个覆盖范围必须是 Polygon 或 MultiPolygon`)
    return {
      id: coverage.id, capability_code: coverage.capability_code, coverage_geom: geometry,
      min_height_amsl_m: coverage.min_height_amsl_m,
      max_height_amsl_m: coverage.max_height_amsl_m,
      valid_from: coverage.valid_from, valid_to: coverage.valid_to,
      metadata: {
        ...coverage.metadata,
        coverage_model: coverage.generation_mode,
        ...(coverage.generation_mode === 'manual' ? {} : {
          radius_m: coverage.radius_m,
          generated_from_asset_position: true,
          ...(coverage.generation_mode === 'sector' ? {
            azimuth_start_deg: coverage.azimuth_start_deg,
            azimuth_end_deg: coverage.azimuth_end_deg,
          } : {}),
        }),
      },
    }
  })
}

function parseSensorChannels() {
  return sensorChannels.value.map((channel, index) => {
    if (!channel.channel_code || !channel.metric_code) throw new Error(`第 ${index + 1} 个传感通道缺少编码或指标`)
    let threshold: Record<string, unknown>
    try {
      threshold = JSON.parse(channel.warning_threshold_text || '{}')
    } catch {
      throw new Error(`传感通道「${channel.channel_code}」的预警阈值不是有效 JSON`)
    }
    return { channel_code: channel.channel_code, metric_code: channel.metric_code, unit: channel.unit || null, warning_threshold: threshold }
  })
}

async function save() {
  await formRef.value?.validate()
  if (form.category_code === 'microwave_radar' && !radarModelCode.value) {
    ElMessage.warning('请选择雷达型号')
    return
  }
  if (dispatchable.value && dispatchEnabled.value && !dispatchResource.resource_role) {
    ElMessage.warning('请输入应急资源角色')
    return
  }
  saving.value = true
  try {
    const radarModel = selectedRadarModel.value
    await saveEquipmentConfiguration({
      asset: {
        ...(props.asset ? { id: props.asset.id } : {}),
        asset_code: form.asset_code,
        category_code: form.category_code,
        type_code: form.type_code || null,
        name: form.name,
        source_system: 'admin_console',
        source_asset_id: form.asset_code,
        managing_unit_name: form.managing_unit_name || null,
        deployment_mode: form.deployment_mode,
        longitude: form.longitude!,
        latitude: form.latitude!,
        elevation_amsl_m: form.elevation_amsl_m,
        manufacturer: (radarModel?.manufacturer ?? form.manufacturer) || null,
        model: (radarModel?.model_code ?? form.model) || null,
        serial_no: form.serial_no || null,
        is_simulated: form.is_simulated,
        capabilities: capabilities.value.map((item) => ({
          capability_code: item.capability_code,
          access_level: item.access_level,
          enabled: item.enabled,
          parameters: item.parameters ?? {},
        })),
        coverages: parseCoverages(),
        ...(form.category_code === 'sensor' ? { sensor_channels: parseSensorChannels() } : {}),
        dispatch_resource: dispatchable.value && dispatchEnabled.value ? { ...dispatchResource } : null,
      },
      profile: { ...profile },
      expectedUpdatedAt: isEdit.value ? form.updated_at : undefined,
    })
    ElMessage.success('保存成功')
    visible.value = false
    emit('saved')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <el-drawer v-model="visible" :title="drawerTitle" size="560px" destroy-on-close>
    <el-form ref="formRef" v-loading="loading" :model="form" :rules="rules" label-width="130px">
      <el-alert
        v-if="isSensitive"
        title="该类设备仅用于展示和方案推荐，后台不提供真实设备控制。"
        type="warning"
        :closable="false"
        show-icon
        class="safety-alert"
      />

      <el-divider content-position="left">基本信息</el-divider>
      <el-form-item label="设备类别" prop="category_code">
        <el-select v-model="form.category_code" :disabled="isEdit" placeholder="选择设备类别" style="width: 100%" @change="categoryChanged">
          <el-option v-for="category in categories" :key="category.code" :label="category.name" :value="category.code" :disabled="!category.enabled" />
        </el-select>
      </el-form-item>
      <el-form-item label="资产编码" prop="asset_code">
        <el-input v-model="form.asset_code" placeholder="平台唯一资产编码" :disabled="isEdit" />
      </el-form-item>
      <el-form-item label="设备名称" prop="name"><el-input v-model="form.name" /></el-form-item>
      <el-form-item label="类别内类型"><el-input v-model="form.type_code" /></el-form-item>
      <el-form-item label="制造商" v-if="form.category_code !== 'microwave_radar'"><el-input v-model="form.manufacturer" /></el-form-item>
      <el-form-item label="型号" v-if="form.category_code !== 'microwave_radar'"><el-input v-model="form.model" /></el-form-item>
      <el-form-item label="序列号"><el-input v-model="form.serial_no" /></el-form-item>
      <el-form-item label="管理单位"><el-input v-model="form.managing_unit_name" /></el-form-item>
      <el-form-item label="部署方式">
        <el-radio-group v-model="form.deployment_mode">
          <el-radio value="fixed">固定</el-radio><el-radio value="mobile">移动</el-radio>
        </el-radio-group>
      </el-form-item>
      <el-form-item label="数据类型">
        <el-radio-group v-model="form.is_simulated" :disabled="isEdit">
          <el-radio :value="false">真实设备</el-radio><el-radio :value="true">模拟设备</el-radio>
        </el-radio-group>
      </el-form-item>

      <el-divider content-position="left">登记位置</el-divider>
      <el-form-item label="经度" prop="longitude">
        <el-input-number v-model="form.longitude" :precision="6" :step="0.001" :min="-180" :max="180" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="纬度" prop="latitude">
        <el-input-number v-model="form.latitude" :precision="6" :step="0.001" :min="-90" :max="90" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="AMSL 高程（m）">
        <el-input-number v-model="form.elevation_amsl_m" :precision="1" controls-position="right" style="width: 100%" />
      </el-form-item>

      <template v-if="form.category_code">
        <el-divider content-position="left">专业属性</el-divider>
        <el-form-item v-if="form.category_code === 'microwave_radar'" label="雷达型号" required>
          <el-select v-model="radarModelCode" placeholder="选择型号" style="width: 100%">
            <el-option v-for="item in radarModels" :key="item.model_code" :label="`${item.name}（${item.model_code}）`" :value="item.model_code" />
          </el-select>
        </el-form-item>
        <el-descriptions v-if="selectedRadarModel" :column="1" border size="small" class="model-spec">
          <el-descriptions-item label="工作体制">{{ selectedRadarModel.work_system }}</el-descriptions-item>
          <el-descriptions-item label="作用距离">≥{{ selectedRadarModel.range_search_m / 1000 }}km @ RCS=0.01㎡</el-descriptions-item>
          <el-descriptions-item label="目标容量">搜索 {{ selectedRadarModel.capacity_search }} 批 / 跟踪 {{ selectedRadarModel.capacity_track }} 批</el-descriptions-item>
        </el-descriptions>

        <el-form-item v-for="field in profileFields" :key="field.key" :label="field.label">
          <el-input
            v-if="field.kind === 'text'"
            :model-value="profileText(field.key)"
            :placeholder="field.placeholder"
            @update:model-value="setProfileText(field.key, $event)"
          />
          <el-input-number
            v-else-if="field.kind === 'number'"
            :model-value="profileNumber(field.key)"
            :min="field.min" :max="field.max" :precision="field.precision"
            controls-position="right" style="width: 100%"
            @update:model-value="setProfileValue(field.key, $event)"
          />
          <el-switch
            v-else-if="field.kind === 'boolean'"
            :model-value="Boolean(profile[field.key])"
            active-text="是" inactive-text="否"
            @update:model-value="setProfileValue(field.key, $event)"
          />
          <el-select
            v-else
            :model-value="profileTags(field.key)"
            multiple filterable allow-create default-first-option
            :placeholder="field.placeholder ?? '输入后回车添加'" style="width: 100%"
            @update:model-value="setProfileValue(field.key, $event)"
          />
        </el-form-item>
      </template>

      <el-divider content-position="left">设备能力</el-divider>
      <div class="inline-add">
        <el-select v-model="capabilityToAdd" filterable placeholder="选择能力" style="flex: 1">
          <el-option
            v-for="item in availableCapabilities"
            :key="item.code"
            :label="`${item.name}（${item.capability_type}）`"
            :value="item.code"
          />
        </el-select>
        <el-button :disabled="!capabilityToAdd" @click="addCapability">添加能力</el-button>
      </div>
      <el-table :data="capabilities" size="small" border empty-text="尚未配置能力">
        <el-table-column label="能力" min-width="140">
          <template #default="{ row }">{{ row.capability_name ?? row.capability_code }}</template>
        </el-table-column>
        <el-table-column label="接入级别" width="130">
          <template #default="{ row }">
            <el-select v-model="row.access_level" size="small">
              <el-option
                v-for="level in accessLevels"
                :key="level.value"
                :label="level.label"
                :value="level.value"
                :disabled="isSensitive && ['linkable', 'controllable'].includes(level.value)"
              />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="启用" width="75">
          <template #default="{ row }"><el-switch v-model="row.enabled" /></template>
        </el-table-column>
        <el-table-column label="范围参数" width="105">
          <template #default="{ row, $index }">
            <el-button v-if="capabilityHasRange(row)" text type="primary" @click="openCapabilityParameters($index)">
              {{ rangeSummary(row) }}
            </el-button>
            <span v-else>--</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="70">
          <template #default="{ $index }"><el-button text type="danger" @click="capabilities.splice($index, 1)">移除</el-button></template>
        </el-table-column>
      </el-table>

      <el-divider content-position="left">能力覆盖范围</el-divider>
      <el-alert title="覆盖范围使用 WGS84 Polygon/MultiPolygon GeoJSON，高度统一为 AMSL。" type="info" :closable="false" class="safety-alert" />
      <el-button class="section-add" :disabled="capabilities.length === 0" @click="addCoverage">添加覆盖范围</el-button>
      <div v-for="(coverage, index) in coverages" :key="coverage.id ?? `new-${index}`" class="coverage-card">
        <el-form-item label="对应能力">
          <el-select v-model="coverage.capability_code" style="width: 100%">
            <el-option v-for="item in capabilities" :key="item.capability_code" :label="item.capability_name ?? item.capability_code" :value="item.capability_code" />
          </el-select>
        </el-form-item>
        <el-form-item label="生成方式">
          <el-radio-group v-model="coverage.generation_mode">
            <el-radio-button value="manual">地图绘制</el-radio-button>
            <el-radio-button value="radial">全向半径</el-radio-button>
            <el-radio-button value="sector">方位扇区</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <template v-if="coverage.generation_mode !== 'manual'">
          <el-form-item label="覆盖半径（m）">
            <el-input-number v-model="coverage.radius_m" :min="1" :precision="1" style="width: 100%" />
          </el-form-item>
          <template v-if="coverage.generation_mode === 'sector'">
            <el-form-item label="起始方位（°）">
              <el-input-number v-model="coverage.azimuth_start_deg" :min="0" :max="360" :precision="1" style="width: 100%" />
            </el-form-item>
            <el-form-item label="结束方位（°）">
              <el-input-number v-model="coverage.azimuth_end_deg" :min="0" :max="360" :precision="1" style="width: 100%" />
            </el-form-item>
          </template>
          <el-form-item>
            <el-button type="primary" plain @click="generateCoverage(index)">根据设备位置生成覆盖面</el-button>
          </el-form-item>
        </template>
        <el-form-item label="覆盖图形">
          <div class="geometry-editor">
            <el-input v-model="coverage.coverage_geom_text" type="textarea" :rows="4" :readonly="coverage.generation_mode !== 'manual'" />
            <el-button v-if="coverage.generation_mode === 'manual'" type="primary" plain @click="openCoverageMap(index)">地图绘制</el-button>
          </div>
        </el-form-item>
        <el-form-item label="最低高度（m）"><el-input-number v-model="coverage.min_height_amsl_m" :precision="1" style="width: 100%" /></el-form-item>
        <el-form-item label="最高高度（m）"><el-input-number v-model="coverage.max_height_amsl_m" :precision="1" style="width: 100%" /></el-form-item>
        <el-form-item><el-button type="danger" plain @click="coverages.splice(index, 1)">删除覆盖范围</el-button></el-form-item>
      </div>

      <template v-if="form.category_code === 'sensor'">
        <el-divider content-position="left">传感通道</el-divider>
        <el-button class="section-add" @click="addSensorChannel">添加通道</el-button>
        <el-table :data="sensorChannels" size="small" border empty-text="尚未配置通道">
          <el-table-column label="通道编码" min-width="120"><template #default="{ row }"><el-input v-model="row.channel_code" /></template></el-table-column>
          <el-table-column label="指标编码" min-width="120"><template #default="{ row }"><el-input v-model="row.metric_code" /></template></el-table-column>
          <el-table-column label="单位" width="90"><template #default="{ row }"><el-input v-model="row.unit" /></template></el-table-column>
          <el-table-column label="预警阈值 JSON" min-width="150"><template #default="{ row }"><el-input v-model="row.warning_threshold_text" /></template></el-table-column>
          <el-table-column label="操作" width="70"><template #default="{ $index }"><el-button text type="danger" @click="sensorChannels.splice($index, 1)">移除</el-button></template></el-table-column>
        </el-table>
      </template>

      <template v-if="dispatchable">
        <el-divider content-position="left">应急调度资源</el-divider>
        <el-form-item label="登记为调度资源"><el-switch v-model="dispatchEnabled" /></el-form-item>
        <template v-if="dispatchEnabled">
          <el-form-item label="资源角色" required><el-input v-model="dispatchResource.resource_role" placeholder="如 aerial_inspection" /></el-form-item>
          <el-form-item label="资源启用"><el-switch v-model="dispatchResource.active" /></el-form-item>
          <el-form-item label="可用时间开始">
            <el-date-picker v-model="dispatchResource.available_from" type="datetime" value-format="YYYY-MM-DDTHH:mm:ssZ" clearable style="width: 100%" />
          </el-form-item>
          <el-form-item label="可用时间结束">
            <el-date-picker v-model="dispatchResource.available_to" type="datetime" value-format="YYYY-MM-DDTHH:mm:ssZ" clearable style="width: 100%" />
          </el-form-item>
        </template>
      </template>

      <div class="drawer-footer">
        <el-button @click="visible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </div>
    </el-form>
    <el-dialog v-model="capabilityParameterVisible" title="配置侦测能力参数" width="520px" append-to-body>
      <el-form label-width="125px">
        <el-form-item label="最小距离（m）"><el-input-number v-model="capabilityParameterForm.min_range_m" :min="0" :precision="1" style="width: 100%" /></el-form-item>
        <el-form-item label="最大距离（m）"><el-input-number v-model="capabilityParameterForm.max_range_m" :min="1" :precision="1" style="width: 100%" /></el-form-item>
        <el-form-item label="参数依据">
          <el-select v-model="capabilityParameterForm.range_basis" style="width: 100%">
            <el-option label="厂商规格" value="vendor_spec" />
            <el-option label="现场测量" value="measured" />
            <el-option label="业务估算" value="estimated" />
            <el-option label="人工配置" value="manual" />
          </el-select>
        </el-form-item>
        <el-form-item label="最低频率（MHz）"><el-input-number v-model="capabilityParameterForm.frequency_min_mhz" :min="0" :precision="3" style="width: 100%" /></el-form-item>
        <el-form-item label="最高频率（MHz）"><el-input-number v-model="capabilityParameterForm.frequency_max_mhz" :min="0" :precision="3" style="width: 100%" /></el-form-item>
        <el-form-item label="定位方式"><el-input v-model="capabilityParameterForm.positioning_mode" placeholder="如 ranging、direction_finding" /></el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="capabilityParameterVisible = false">取消</el-button>
        <el-button type="primary" @click="saveCapabilityParameters">确定</el-button>
      </template>
    </el-dialog>
    <CoverageMapDialog
      v-model:visible="coverageMapVisible"
      v-model:geojson="editingCoverageGeojson"
      :longitude="form.longitude"
      :latitude="form.latitude"
    />
  </el-drawer>
</template>

<style scoped>
.safety-alert { margin-bottom: 16px; }
.model-spec { margin: 0 0 16px 130px; }
.inline-add { display: flex; gap: 8px; margin-bottom: 12px; }
.section-add { margin-bottom: 12px; }
.coverage-card { margin-bottom: 12px; padding: 12px; border: 1px solid #dfe4e1; border-radius: 6px; background: #fafbfa; }
.geometry-editor { display: grid; width: 100%; gap: 8px; }
.drawer-footer { display: flex; justify-content: flex-end; gap: 12px; margin-top: 24px; }
</style>
