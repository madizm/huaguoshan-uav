<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { ElMessage } from 'element-plus'
import { listCategories, listCapabilityCatalog, listRadarModels, updateCategory, updateCapability, updateRadarModel, type AssetCategory, type CapabilityCatalogItem, type RadarModel } from '../api/equipment'

const categories = ref<AssetCategory[]>([])
const capabilities = ref<CapabilityCatalogItem[]>([])
const radarModels = ref<RadarModel[]>([])
const loading = ref(false)
const route = useRoute()
const activeTab = ref(route.hash === '#capability-catalog' ? 'capabilities' : 'categories')
watch(() => route.hash, (hash) => {
  if (hash === '#capability-catalog') activeTab.value = 'capabilities'
})

async function load() {
  loading.value = true
  try { [categories.value, capabilities.value, radarModels.value] = await Promise.all([listCategories(), listCapabilityCatalog(), listRadarModels()]) }
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
  </el-tabs>
</template>

<style scoped>
.model-alert { margin-bottom: 12px; }
.catalog-note { margin-bottom: 12px; }
.catalog-note a { display: inline-block; margin-top: 8px; }
</style>
