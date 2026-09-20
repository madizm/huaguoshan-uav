<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import type { FormInstance, FormRules } from 'element-plus'
import {
  createAsset,
  getRadarProfile,
  listRadarModels,
  updateAsset,
  upsertRadarProfile,
  type EquipmentAsset,
  type MicrowaveRadarProfile,
  type RadarModel,
} from '../api/equipment'

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{ asset: EquipmentAsset | null }>()
const emit = defineEmits<{ saved: [] }>()

const isEdit = computed(() => props.asset !== null)
const drawerTitle = computed(() => (isEdit.value ? '编辑雷达设备' : '新增雷达设备'))

const models = ref<RadarModel[]>([])
const formRef = ref<FormInstance>()
const saving = ref(false)

const form = reactive({
  asset_code: '',
  name: '',
  managing_unit_name: '',
  deployment_mode: 'fixed',
  lon: null as number | null,
  lat: null as number | null,
  elevation_amsl_m: null as number | null,
  model_code: '' as string,
  serial_no: '',
  face_count: 1,
  install_azimuth_deg: null as number | null,
  install_tilt_deg: null as number | null,
  control_host: '',
  control_port: null as number | null,
  protocol: '',
})

const rules: FormRules = {
  asset_code: [{ required: true, message: '请输入资产编码', trigger: 'blur' }],
  name: [{ required: true, message: '请输入设备名称', trigger: 'blur' }],
  model_code: [{ required: true, message: '请选择型号', trigger: 'change' }],
  lon: [{ required: true, message: '请输入经度', trigger: 'blur' }],
  lat: [{ required: true, message: '请输入纬度', trigger: 'blur' }],
}

const selectedModel = computed(() => models.value.find((m) => m.model_code === form.model_code) ?? null)

// 选中四面固态型号时自动带出面数。
watch(
  () => form.model_code,
  (code) => {
    const model = models.value.find((m) => m.model_code === code)
    if (model) form.face_count = model.scan_mode === 'four_face_phase' ? 4 : 1
  },
)

watch(visible, async (open) => {
  if (!open) return
  if (models.value.length === 0) {
    models.value = await listRadarModels().catch(() => [])
  }
  formRef.value?.resetFields()
  Object.assign(form, {
    asset_code: '',
    name: '',
    managing_unit_name: '',
    deployment_mode: 'fixed',
    lon: null,
    lat: null,
    elevation_amsl_m: null,
    model_code: '',
    serial_no: '',
    face_count: 1,
    install_azimuth_deg: null,
    install_tilt_deg: null,
    control_host: '',
    control_port: null,
    protocol: '',
  })
  if (props.asset) {
    const asset = props.asset
    form.asset_code = asset.asset_code
    form.name = asset.name
    form.managing_unit_name = asset.managing_unit_name ?? ''
    form.deployment_mode = asset.deployment_mode ?? 'fixed'
    form.elevation_amsl_m = asset.elevation_amsl_m
    form.serial_no = ''
    // 编辑模式从 profile 回填型号与接入信息。
    const profiles = await getRadarProfile(asset.id).catch(() => [] as MicrowaveRadarProfile[])
    const profile = profiles[0]
    if (profile) {
      form.model_code = profile.model_code ?? ''
      form.face_count = profile.face_count
      form.install_azimuth_deg = profile.install_azimuth_deg
      form.install_tilt_deg = profile.install_tilt_deg
      form.control_host = profile.control_host ?? ''
      form.control_port = profile.control_port
      form.protocol = profile.protocol ?? ''
    }
  }
})

function geomEwkt(): string {
  return `SRID=4326;POINT(${form.lon} ${form.lat})`
}

async function save() {
  await formRef.value?.validate()
  saving.value = true
  try {
    const model = selectedModel.value
    const assetPayload = {
      asset_code: form.asset_code,
      category_code: 'microwave_radar',
      name: form.name,
      managing_unit_name: form.managing_unit_name || null,
      deployment_mode: form.deployment_mode,
      geom: geomEwkt(),
      elevation_amsl_m: form.elevation_amsl_m,
      model: model?.model_code ?? null,
      manufacturer: model?.manufacturer ?? null,
    }
    let assetId: number
    if (isEdit.value) {
      assetId = props.asset!.id
      await updateAsset(assetId, assetPayload)
    } else {
      const created = await createAsset({
        ...assetPayload,
        source_system: 'admin_console',
        source_asset_id: form.asset_code,
      })
      assetId = created[0].id
    }
    await upsertRadarProfile({
      asset_id: assetId,
      model_code: form.model_code,
      face_count: form.face_count,
      install_azimuth_deg: form.install_azimuth_deg,
      install_tilt_deg: form.install_tilt_deg,
      control_host: form.control_host || null,
      control_port: form.control_port,
      protocol: form.protocol || null,
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
  <el-drawer v-model="visible" :title="drawerTitle" size="520px" destroy-on-close>
    <el-form ref="formRef" :model="form" :rules="rules" label-width="110px">
      <el-divider content-position="left">基本信息</el-divider>
      <el-form-item label="资产编码" prop="asset_code">
        <el-input v-model="form.asset_code" placeholder="如 HGS-RADAR-001" :disabled="isEdit" />
      </el-form-item>
      <el-form-item label="设备名称" prop="name">
        <el-input v-model="form.name" />
      </el-form-item>
      <el-form-item label="管理单位">
        <el-input v-model="form.managing_unit_name" />
      </el-form-item>
      <el-form-item label="部署方式">
        <el-radio-group v-model="form.deployment_mode">
          <el-radio value="fixed">固定</el-radio>
          <el-radio value="mobile">移动</el-radio>
        </el-radio-group>
      </el-form-item>
      <el-form-item label="经度" prop="lon">
        <el-input-number v-model="form.lon" :precision="6" :step="0.001" :min="-180" :max="180" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="纬度" prop="lat">
        <el-input-number v-model="form.lat" :precision="6" :step="0.001" :min="-90" :max="90" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="阵地高程(m)">
        <el-input-number v-model="form.elevation_amsl_m" :precision="1" controls-position="right" style="width: 100%" />
      </el-form-item>

      <el-divider content-position="left">型号</el-divider>
      <el-form-item label="雷达型号" prop="model_code">
        <el-select v-model="form.model_code" placeholder="选择型号" style="width: 100%">
          <el-option v-for="m in models" :key="m.model_code" :label="`${m.name}（${m.model_code}）`" :value="m.model_code" />
        </el-select>
      </el-form-item>
      <template v-if="selectedModel">
        <el-descriptions :column="1" border size="small" class="model-spec">
          <el-descriptions-item label="工作体制">{{ selectedModel.work_system }}</el-descriptions-item>
          <el-descriptions-item label="作用距离">
            ≥{{ selectedModel.range_search_m / 1000 }}km
            <template v-if="selectedModel.range_phase_search_m">
              （相扫 ≥{{ selectedModel.range_phase_search_m / 1000 }}km）
            </template>
            @ RCS=0.01㎡
          </el-descriptions-item>
          <el-descriptions-item label="目标容量">
            搜索 {{ selectedModel.capacity_search }} 批 / 跟踪 {{ selectedModel.capacity_track }} 批
          </el-descriptions-item>
          <el-descriptions-item label="功耗">{{ selectedModel.power_w ?? '-' }}W</el-descriptions-item>
        </el-descriptions>
      </template>

      <el-divider content-position="left">部署与接入</el-divider>
      <el-form-item label="阵面数量">
        <el-input-number v-model="form.face_count" :min="1" :max="4" controls-position="right" />
      </el-form-item>
      <el-form-item label="安装方位角(°)">
        <el-input-number v-model="form.install_azimuth_deg" :min="0" :max="359.9" :precision="1" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="安装俯仰角(°)">
        <el-input-number v-model="form.install_tilt_deg" :min="-90" :max="90" :precision="1" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="控制 IP">
        <el-input v-model="form.control_host" placeholder="如 192.168.1.10" />
      </el-form-item>
      <el-form-item label="控制端口">
        <el-input-number v-model="form.control_port" :min="1" :max="65535" controls-position="right" style="width: 100%" />
      </el-form-item>
      <el-form-item label="对接协议">
        <el-input v-model="form.protocol" placeholder="如 JBHT-V1" />
      </el-form-item>

      <div class="drawer-footer">
        <el-button @click="visible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </div>
    </el-form>
  </el-drawer>
</template>

<style scoped>
.model-spec {
  margin: 0 0 16px 110px;
}
.drawer-footer {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
  margin-top: 24px;
}
</style>
