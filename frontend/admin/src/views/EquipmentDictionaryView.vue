<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { listCategories, listCapabilityCatalog, listRadarModels, listUavModels, updateCategory, updateCapability, updateRadarModel, updateUavModel, createUavModel, type AssetCategory, type CapabilityCatalogItem, type RadarModel, type UavModel } from '../api/equipment'

const categories = ref<AssetCategory[]>([])
const capabilities = ref<CapabilityCatalogItem[]>([])
const radarModels = ref<RadarModel[]>([])
const uavModels = ref<UavModel[]>([])
const loading = ref(false)
const route = useRoute()
const activeTab = ref(route.hash === '#capability-catalog' ? 'capabilities' : 'categories')
watch(() => route.hash, (hash) => {
  if (hash === '#capability-catalog') activeTab.value = 'capabilities'
})

// 新增无人机机型对话框
const showAddUavDialog = ref(false)
const newUavModel = ref<Partial<UavModel>>({
  model_code: '',
  name: '',
  manufacturer: '',
  weight_class: 'light',
  max_takeoff_weight_kg: 0,
  max_speed_kph: null,
  max_endurance_min: null,
  max_payload_kg: null,
})

async function load() {
  loading.value = true
  try { [categories.value, capabilities.value, radarModels.value, uavModels.value] = await Promise.all([listCategories(), listCapabilityCatalog(), listRadarModels(), listUavModels()]) }
  catch (error) { ElMessage.error((error as Error).message) }
  finally { loading.value = false }
}
async function saveCategory(row: AssetCategory) {
  try { await updateCategory(row.code, row); ElMessage.success('类别已保存') }
  catch (error) { ElMessage.error((error as Error).message); await load() }
}
async function saveCapability(row: CapabilityCatalogItem) {
  try { await updateCapability(row.code, row); ElMessage.success('能力已保存') }
  catch (error) { ElMessage.error((error as Error).message); await load() }
}
async function saveRadarModel(row: RadarModel) {
  try { await updateRadarModel(row.model_code, row); ElMessage.success('型号规格已保存') }
  catch (error) { ElMessage.error((error as Error).message); await load() }
}
async function saveUavModel(row: UavModel) {
  try { await updateUavModel(row.model_code, row); ElMessage.success('机型规格已保存') }
  catch (error) { ElMessage.error((error as Error).message); await load() }
}

function openAddUavDialog() {
  newUavModel.value = {
    model_code: '',
    name: '',
    manufacturer: '',
    weight_class: 'light',
    max_takeoff_weight_kg: 0,
    max_speed_kph: null,
    max_endurance_min: null,
    max_payload_kg: null,
  }
  showAddUavDialog.value = true
}

async function submitAddUav() {
  if (!newUavModel.value.model_code || !newUavModel.value.name) {
    ElMessage.warning('型号编码和名称不能为空')
    return
  }
  if (!newUavModel.value.max_takeoff_weight_kg || newUavModel.value.max_takeoff_weight_kg <= 0) {
    ElMessage.warning('最大起飞重量必须大于 0')
    return
  }
  
  try {
    await createUavModel(newUavModel.value as UavModel)
    ElMessage.success('机型已添加')
    showAddUavDialog.value = false
    await load()
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

onMounted(load)
</script>

<template>
  <el-tabs v-model="activeTab" v-loading="loading">
    <el-tab-pane name="categories" label="设备类别">
      <el-table :data="categories" border stripe>
        <el-table-column prop="code" label="编码" width="190" />
        <el-table-column label="名称" width="180"><template #default="{ row }"><el-input v-model="row.name" /></template></el-table-column>
        <el-table-column label="分组" width="160"><template #default="{ row }"><el-input v-model="row.category_group" /></template></el-table-column>
        <el-table-column label="说明"><template #default="{ row }"><el-input v-model="row.description" /></template></el-table-column>
        <el-table-column label="启用" width="80"><template #default="{ row }"><el-switch v-model="row.enabled" /></template></el-table-column>
        <el-table-column label="排序" width="100"><template #default="{ row }"><el-input-number v-model="row.sort_order" :min="0" controls-position="right" /></template></el-table-column>
        <el-table-column label="操作" width="90"><template #default="{ row }"><el-button type="primary" text @click="saveCategory(row)">保存</el-button></template></el-table-column>
      </el-table>
    </el-tab-pane>
    <el-tab-pane name="capabilities" label="能力字典">
      <div id="capability-catalog" class="catalog-note">
        <el-alert title="设备能力描述资产能做什么；侦测方式描述单条目标观测如何产生。编码不要求相同，也不自动互相约束。例如微波探测能力（microwave_detection）与雷达侦测方式（radar）属于不同字典。" type="info" :closable="false" />
        <router-link :to="{ name: 'detection-sources', hash: '#detection-methods' }">查看侦测方式与相关设备能力示例</router-link>
      </div>
      <el-table :data="capabilities" border stripe>
        <el-table-column prop="code" label="编码" width="210" />
        <el-table-column label="名称" width="190"><template #default="{ row }"><el-input v-model="row.name" /></template></el-table-column>
        <el-table-column label="类型" width="150"><template #default="{ row }"><el-input v-model="row.capability_type" /></template></el-table-column>
        <el-table-column label="说明"><template #default="{ row }"><el-input v-model="row.description" /></template></el-table-column>
        <el-table-column label="操作" width="90"><template #default="{ row }"><el-button type="primary" text @click="saveCapability(row)">保存</el-button></template></el-table-column>
      </el-table>
    </el-tab-pane>
    <el-tab-pane name="radar-models" label="雷达型号">
      <el-alert title="型号规格由所有同型号设备共用，修改前请核对厂商资料。型号编码不可修改。" type="warning" :closable="false" class="model-alert" />
      <el-table :data="radarModels" border stripe>
        <el-table-column prop="model_code" label="型号编码" width="120" fixed />
        <el-table-column label="名称" width="180"><template #default="{ row }"><el-input v-model="row.name" /></template></el-table-column>
        <el-table-column label="制造商" width="120"><template #default="{ row }"><el-input v-model="row.manufacturer" /></template></el-table-column>
        <el-table-column label="工作体制" min-width="220"><template #default="{ row }"><el-input v-model="row.work_system" /></template></el-table-column>
        <el-table-column label="频段" width="90"><template #default="{ row }"><el-input v-model="row.frequency_band" /></template></el-table-column>
        <el-table-column label="搜索距离(m)" width="140"><template #default="{ row }"><el-input-number v-model="row.range_search_m" :min="1" /></template></el-table-column>
        <el-table-column label="覆盖高度(m)" width="140"><template #default="{ row }"><el-input-number v-model="row.coverage_height_m" :min="1" /></template></el-table-column>
        <el-table-column label="搜索容量" width="120"><template #default="{ row }"><el-input-number v-model="row.capacity_search" :min="1" /></template></el-table-column>
        <el-table-column label="跟踪容量" width="120"><template #default="{ row }"><el-input-number v-model="row.capacity_track" :min="1" /></template></el-table-column>
        <el-table-column label="功耗(W)" width="120"><template #default="{ row }"><el-input-number v-model="row.power_w" :min="0" /></template></el-table-column>
        <el-table-column label="操作" width="90" fixed="right"><template #default="{ row }"><el-button type="primary" text @click="saveRadarModel(row)">保存</el-button></template></el-table-column>
      </el-table>
    </el-tab-pane>
    <el-tab-pane name="uav-models" label="无人机机型">
      <div class="uav-header">
        <el-alert title="机型目录记录无人机型号级参数，用于风险评估的重量分级和性能参考。型号编码不可修改。" type="info" :closable="false" class="model-alert" />
        <el-button type="primary" @click="openAddUavDialog">新增机型</el-button>
      </div>
      <el-table :data="uavModels" border stripe>
        <el-table-column prop="model_code" label="型号编码" width="180" fixed />
        <el-table-column label="名称" width="180"><template #default="{ row }"><el-input v-model="row.name" /></template></el-table-column>
        <el-table-column label="制造商" width="120"><template #default="{ row }"><el-input v-model="row.manufacturer" /></template></el-table-column>
        <el-table-column label="重量分级" width="120">
          <template #default="{ row }">
            <el-select v-model="row.weight_class" style="width: 100%">
              <el-option label="微型" value="micro" />
              <el-option label="轻型" value="light" />
              <el-option label="小型" value="small" />
              <el-option label="中型" value="medium" />
              <el-option label="大型" value="large" />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="最大起飞重量(kg)" width="160"><template #default="{ row }"><el-input-number v-model="row.max_takeoff_weight_kg" :min="0" :precision="2" :step="0.1" /></template></el-table-column>
        <el-table-column label="最大速度(km/h)" width="140"><template #default="{ row }"><el-input-number v-model="row.max_speed_kph" :min="0" :precision="1" :step="1" /></template></el-table-column>
        <el-table-column label="续航时间(min)" width="140"><template #default="{ row }"><el-input-number v-model="row.max_endurance_min" :min="0" :step="1" /></template></el-table-column>
        <el-table-column label="最大载荷(kg)" width="140"><template #default="{ row }"><el-input-number v-model="row.max_payload_kg" :min="0" :precision="2" :step="0.1" /></template></el-table-column>
        <el-table-column label="操作" width="90" fixed="right"><template #default="{ row }"><el-button type="primary" text @click="saveUavModel(row)">保存</el-button></template></el-table-column>
      </el-table>
    </el-tab-pane>
  </el-tabs>

  <!-- 新增无人机机型对话框 -->
  <el-dialog v-model="showAddUavDialog" title="新增无人机机型" width="600px">
    <el-form :model="newUavModel" label-width="140px">
      <el-form-item label="型号编码" required>
        <el-input v-model="newUavModel.model_code" placeholder="如：DJI_MINI_4_PRO" />
      </el-form-item>
      <el-form-item label="型号名称" required>
        <el-input v-model="newUavModel.name" placeholder="如：DJI Mini 4 Pro" />
      </el-form-item>
      <el-form-item label="制造商">
        <el-input v-model="newUavModel.manufacturer" placeholder="如：DJI" />
      </el-form-item>
      <el-form-item label="重量分级" required>
        <el-select v-model="newUavModel.weight_class" style="width: 100%">
          <el-option label="微型 (<250g)" value="micro" />
          <el-option label="轻型 (250g-4kg)" value="light" />
          <el-option label="小型 (4-25kg)" value="small" />
          <el-option label="中型 (25-150kg)" value="medium" />
          <el-option label="大型 (>150kg)" value="large" />
        </el-select>
      </el-form-item>
      <el-form-item label="最大起飞重量(kg)" required>
        <el-input-number v-model="newUavModel.max_takeoff_weight_kg" :min="0" :precision="2" :step="0.1" style="width: 100%" />
      </el-form-item>
      <el-form-item label="最大速度(km/h)">
        <el-input-number v-model="newUavModel.max_speed_kph" :min="0" :precision="1" :step="1" style="width: 100%" />
      </el-form-item>
      <el-form-item label="续航时间(min)">
        <el-input-number v-model="newUavModel.max_endurance_min" :min="0" :step="1" style="width: 100%" />
      </el-form-item>
      <el-form-item label="最大载荷(kg)">
        <el-input-number v-model="newUavModel.max_payload_kg" :min="0" :precision="2" :step="0.1" style="width: 100%" />
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="showAddUavDialog = false">取消</el-button>
      <el-button type="primary" @click="submitAddUav">确定</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.model-alert { margin-bottom: 12px; }
.catalog-note { margin-bottom: 12px; }
.catalog-note a { display: inline-block; margin-top: 8px; }
.uav-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 12px; }
.uav-header .model-alert { flex: 1; margin-right: 12px; margin-bottom: 0; }
</style>
