<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  listAssets,
  listCategories,
  updateAsset,
  type AssetCategory,
  type EquipmentAsset,
} from '../api/equipment'
import RadarEditorDrawer from '../components/RadarEditorDrawer.vue'

const categories = ref<AssetCategory[]>([])
const categoryNameMap = reactive<Record<string, string>>({})

const filters = reactive({ categoryCode: '', keyword: '', simulation: 'real' as 'real' | 'simulated' | 'all' })
const assets = ref<EquipmentAsset[]>([])
const total = ref(0)
const page = reactive({ current: 1, size: 20 })
const loading = ref(false)

const drawerVisible = ref(false)
const editingAsset = ref<EquipmentAsset | null>(null)

async function loadAssets() {
  loading.value = true
  try {
    const result = await listAssets({
      categoryCode: filters.categoryCode || undefined,
      keyword: filters.keyword || undefined,
      isSimulated: filters.simulation === 'all' ? undefined : filters.simulation === 'simulated',
      limit: page.size,
      offset: (page.current - 1) * page.size,
    })
    assets.value = result.rows
    total.value = result.total
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function search() {
  page.current = 1
  loadAssets()
}

function openCreate() {
  editingAsset.value = null
  drawerVisible.value = true
}

function openEdit(asset: EquipmentAsset) {
  editingAsset.value = asset
  drawerVisible.value = true
}

async function toggleLifecycle(asset: EquipmentAsset) {
  const retiring = asset.lifecycle_status === 'active'
  const action = retiring ? '退役' : '重新启用'
  await ElMessageBox.confirm(`确认${action}设备「${asset.name}」？`, action, { type: 'warning' })
  try {
    await updateAsset(asset.id, { lifecycle_status: retiring ? 'retired' : 'active' })
    ElMessage.success(`${action}成功`)
    loadAssets()
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

function lifecycleTagType(status: string) {
  return status === 'active' ? 'success' : status === 'retired' ? 'info' : 'warning'
}

function lifecycleLabel(status: string) {
  return { active: '在役', retired: '已退役', maintenance: '维护中' }[status] ?? status
}

onMounted(async () => {
  try {
    categories.value = await listCategories()
    for (const c of categories.value) categoryNameMap[c.code] = c.name
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
  loadAssets()
})
</script>

<template>
  <section>
    <div class="page-toolbar">
        <el-select
          v-model="filters.categoryCode"
          placeholder="全部类别"
          clearable
          style="width: 200px"
          @change="search"
        >
          <el-option v-for="c in categories" :key="c.code" :label="c.name" :value="c.code" />
        </el-select>
        <el-input
          v-model="filters.keyword"
          placeholder="资产编码 / 名称"
          clearable
          style="width: 240px"
          @keyup.enter="search"
          @clear="search"
        />
        <el-button type="primary" @click="search">查询</el-button>
        <el-select v-model="filters.simulation" style="width: 150px" @change="search">
          <el-option label="真实设备" value="real" />
          <el-option label="模拟设备" value="simulated" />
          <el-option label="全部设备" value="all" />
        </el-select>
        <div class="page-toolbar-spacer" />
        <el-button type="primary" @click="openCreate">新增雷达设备</el-button>
    </div>

    <div class="table-shell">
      <el-table v-loading="loading" :data="assets" stripe>
        <el-table-column prop="asset_code" label="资产编码" width="180" />
        <el-table-column prop="name" label="名称" min-width="200" show-overflow-tooltip />
        <el-table-column label="类别" width="150">
          <template #default="{ row }">{{ categoryNameMap[row.category_code] ?? row.category_code }}</template>
        </el-table-column>
        <el-table-column prop="model" label="型号" width="130" />
        <el-table-column prop="managing_unit_name" label="管理单位" min-width="140" show-overflow-tooltip />
        <el-table-column label="生命周期" width="100">
          <template #default="{ row }">
            <el-tag :type="lifecycleTagType(row.lifecycle_status)">{{ lifecycleLabel(row.lifecycle_status) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="数据类型" width="100">
          <template #default="{ row }">
            <el-tag :type="row.is_simulated ? 'warning' : 'success'" effect="plain">
              {{ row.is_simulated ? '模拟' : '真实' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="updated_at" label="更新时间" width="180">
          <template #default="{ row }">{{ new Date(row.updated_at).toLocaleString('zh-CN') }}</template>
        </el-table-column>
        <el-table-column label="操作" width="160">
          <template #default="{ row }">
            <el-button
              v-if="row.category_code === 'microwave_radar'"
              text
              type="primary"
              @click="openEdit(row)"
            >
              编辑
            </el-button>
            <el-button text :type="row.lifecycle_status === 'active' ? 'danger' : 'success'" @click="toggleLifecycle(row)">
              {{ row.lifecycle_status === 'active' ? '退役' : '启用' }}
            </el-button>
          </template>
        </el-table-column>
      </el-table>
    </div>

    <el-pagination
        v-model:current-page="page.current"
        v-model:page-size="page.size"
        :total="total"
        :page-sizes="[20, 50, 100]"
        layout="total, sizes, prev, pager, next"
        class="page-pagination"
        @current-change="loadAssets"
        @size-change="search"
    />
    <RadarEditorDrawer v-model="drawerVisible" :asset="editingAsset" @saved="loadAssets" />
  </section>
</template>

<style scoped>
.page-toolbar :deep(.el-input),
.page-toolbar :deep(.el-select) {
  max-width: 100%;
}
</style>
