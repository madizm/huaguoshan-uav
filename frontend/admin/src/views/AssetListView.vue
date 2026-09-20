<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { authStore, logout } from '../api/auth'
import {
  listAssets,
  listCategories,
  updateAsset,
  type AssetCategory,
  type EquipmentAsset,
} from '../api/equipment'
import RadarEditorDrawer from '../components/RadarEditorDrawer.vue'

const router = useRouter()

const categories = ref<AssetCategory[]>([])
const categoryNameMap = reactive<Record<string, string>>({})

const filters = reactive({ categoryCode: '', keyword: '' })
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

function handleLogout() {
  logout()
  router.push({ name: 'login' })
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
  <el-container class="layout">
    <el-header class="header">
      <span class="header-title">花果山设备管理后台</span>
      <div class="header-right">
        <span class="header-user">{{ authStore.username }}</span>
        <el-button text type="primary" @click="handleLogout">退出登录</el-button>
      </div>
    </el-header>
    <el-main>
      <div class="toolbar">
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
        <div class="toolbar-spacer" />
        <el-button type="primary" @click="openCreate">新增雷达设备</el-button>
      </div>

      <el-table v-loading="loading" :data="assets" border stripe>
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
        <el-table-column prop="updated_at" label="更新时间" width="180">
          <template #default="{ row }">{{ new Date(row.updated_at).toLocaleString('zh-CN') }}</template>
        </el-table-column>
        <el-table-column label="操作" width="160" fixed="right">
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

      <el-pagination
        v-model:current-page="page.current"
        v-model:page-size="page.size"
        :total="total"
        :page-sizes="[20, 50, 100]"
        layout="total, sizes, prev, pager, next"
        class="pagination"
        @current-change="loadAssets"
        @size-change="search"
      />
    </el-main>

    <RadarEditorDrawer v-model="drawerVisible" :asset="editingAsset" @saved="loadAssets" />
  </el-container>
</template>

<style scoped>
.layout {
  min-height: 100vh;
}
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: #001529;
  color: #fff;
}
.header-title {
  font-size: 17px;
  font-weight: 600;
}
.header-right {
  display: flex;
  align-items: center;
  gap: 12px;
}
.header-user {
  color: rgba(255, 255, 255, 0.85);
}
.header-right :deep(.el-button) {
  color: #79bbff;
}
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}
.toolbar-spacer {
  flex: 1;
}
.pagination {
  margin-top: 16px;
  justify-content: flex-end;
}
</style>
