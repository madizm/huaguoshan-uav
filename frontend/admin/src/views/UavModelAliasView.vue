<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  listUavModelAliasStatistics,
  createUavModelAlias,
  updateUavModelAlias,
  deleteUavModelAlias,
  testUavModelMatch,
  listUavModels,
  type UavModelAliasStatistics,
  type UavModel,
  type TestMatchResult,
} from '../api/equipment'

const loading = ref(false)
const aliasList = ref<UavModelAliasStatistics[]>([])
const uavModels = ref<UavModel[]>([])

// 对话框状态
const dialogVisible = ref(false)
const dialogMode = ref<'create' | 'edit'>('create')
const editingAlias = ref<UavModelAliasStatistics | null>(null)

// 表单数据
const form = ref({
  alias_pattern: '',
  model_code: '',
  priority: 10,
})

// 测试匹配
const testModel = ref('')
const testResult = ref<TestMatchResult | null>(null)
const testLoading = ref(false)

// 加载数据
async function loadData() {
  loading.value = true
  try {
    const [aliases, models] = await Promise.all([
      listUavModelAliasStatistics(),
      listUavModels(),
    ])
    aliasList.value = aliases
    uavModels.value = models
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

// 打开创建对话框
function openCreateDialog() {
  dialogMode.value = 'create'
  editingAlias.value = null
  form.value = {
    alias_pattern: '',
    model_code: '',
    priority: 10,
  }
  dialogVisible.value = true
}

// 打开编辑对话框
function openEditDialog(alias: UavModelAliasStatistics) {
  dialogMode.value = 'edit'
  editingAlias.value = alias
  form.value = {
    alias_pattern: alias.alias_pattern,
    model_code: alias.model_code,
    priority: alias.priority,
  }
  dialogVisible.value = true
}

// 提交表单
async function submitForm() {
  if (!form.value.alias_pattern || !form.value.model_code) {
    ElMessage.warning('请填写完整的表单')
    return
  }

  try {
    if (dialogMode.value === 'create') {
      await createUavModelAlias({
        alias_pattern: form.value.alias_pattern,
        model_code: form.value.model_code,
        priority: form.value.priority,
      })
      ElMessage.success('创建成功')
    } else {
      if (!editingAlias.value) return
      await updateUavModelAlias(editingAlias.value.alias_pattern, {
        alias_pattern: form.value.alias_pattern,
        model_code: form.value.model_code,
        priority: form.value.priority,
      })
      ElMessage.success('更新成功')
    }
    dialogVisible.value = false
    await loadData()
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

// 删除规则
async function handleDelete(alias: UavModelAliasStatistics) {
  try {
    await ElMessageBox.confirm(
      `确定要删除匹配规则 "${alias.alias_pattern}" 吗？`,
      '确认删除',
      { type: 'warning' }
    )
    await deleteUavModelAlias(alias.alias_pattern)
    ElMessage.success('删除成功')
    await loadData()
  } catch (error) {
    if (error !== 'cancel') {
      ElMessage.error((error as Error).message)
    }
  }
}

// 测试匹配
async function handleTestMatch() {
  if (!testModel.value) {
    ElMessage.warning('请输入要测试的机型名称')
    return
  }

  testLoading.value = true
  testResult.value = null
  try {
    const result = await testUavModelMatch(testModel.value)
    testResult.value = result
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    testLoading.value = false
  }
}

// 获取机型名称
function getModelName(modelCode: string): string {
  const model = uavModels.value.find(m => m.model_code === modelCode)
  return model ? model.name : modelCode
}

onMounted(loadData)
</script>

<template>
  <div class="uav-model-alias-view">
    <!-- 测试匹配区域 -->
    <el-card class="test-card">
      <template #header>
        <div class="card-header">
          <span>测试匹配</span>
        </div>
      </template>
      <el-form :inline="true" @submit.prevent="handleTestMatch">
        <el-form-item label="观测机型名称">
          <el-input
            v-model="testModel"
            placeholder="例如：DJI-Mavic-O4"
            style="width: 300px"
            @keyup.enter="handleTestMatch"
          />
        </el-form-item>
        <el-form-item>
          <el-button type="primary" :loading="testLoading" @click="handleTestMatch">
            测试
          </el-button>
        </el-form-item>
      </el-form>
      <div v-if="testResult" class="test-result">
        <el-alert
          v-if="testResult.matched"
          type="success"
          :closable="false"
          show-icon
        >
          <template #title>
            匹配成功
          </template>
          <div class="result-details">
            <p><strong>标准机型：</strong>{{ testResult.model_name }}</p>
            <p><strong>机型编码：</strong>{{ testResult.model_code }}</p>
            <p><strong>制造商：</strong>{{ testResult.manufacturer }}</p>
            <p><strong>重量分级：</strong>{{ testResult.weight_class }}</p>
            <p><strong>最大起飞重量：</strong>{{ testResult.max_takeoff_weight_kg }} kg</p>
          </div>
        </el-alert>
        <el-alert
          v-else
          type="warning"
          :closable="false"
          show-icon
        >
          <template #title>
            未匹配
          </template>
          <div class="result-details">
            <p>{{ testResult.reason }}</p>
          </div>
        </el-alert>
      </div>
    </el-card>

    <!-- 规则列表 -->
    <el-card class="alias-card">
      <template #header>
        <div class="card-header">
          <span>匹配规则列表</span>
          <el-button type="primary" @click="openCreateDialog">
            新增规则
          </el-button>
        </div>
      </template>
      <el-alert
        type="info"
        :closable="false"
        show-icon
        style="margin-bottom: 16px"
      >
        <template #title>
          匹配规则按优先级排序，高优先级规则优先匹配。同一观测数据可能匹配多条规则，取优先级最高的。
        </template>
      </el-alert>
      <el-table
        :data="aliasList"
        v-loading="loading"
        stripe
        border
        style="width: 100%"
      >
        <el-table-column prop="priority" label="优先级" width="100" sortable />
        <el-table-column prop="alias_pattern" label="匹配模式" min-width="200" />
        <el-table-column label="标准机型" min-width="200">
          <template #default="{ row }">
            <div>
              <div>{{ getModelName(row.model_code) }}</div>
              <div style="color: #909399; font-size: 12px">{{ row.model_code }}</div>
            </div>
          </template>
        </el-table-column>
        <el-table-column prop="manufacturer" label="制造商" width="120" />
        <el-table-column prop="match_count" label="命中次数" width="120" sortable>
          <template #default="{ row }">
            <el-tag :type="row.match_count > 0 ? 'success' : 'info'">
              {{ row.match_count.toLocaleString() }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="150" fixed="right">
          <template #default="{ row }">
            <el-button type="primary" link @click="openEditDialog(row)">
              编辑
            </el-button>
            <el-button type="danger" link @click="handleDelete(row)">
              删除
            </el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 新增/编辑对话框 -->
    <el-dialog
      v-model="dialogVisible"
      :title="dialogMode === 'create' ? '新增匹配规则' : '编辑匹配规则'"
      width="500px"
    >
      <el-form :model="form" label-width="100px">
        <el-form-item label="匹配模式" required>
          <el-input
            v-model="form.alias_pattern"
            placeholder="例如：%Mavic-O4%"
          />
          <div style="color: #909399; font-size: 12px; margin-top: 4px">
            支持 SQL LIKE 通配符：% 匹配任意字符，_ 匹配单个字符
          </div>
        </el-form-item>
        <el-form-item label="标准机型" required>
          <el-select
            v-model="form.model_code"
            placeholder="请选择标准机型"
            filterable
            style="width: 100%"
          >
            <el-option
              v-for="model in uavModels"
              :key="model.model_code"
              :label="`${model.name} (${model.model_code})`"
              :value="model.model_code"
            />
          </el-select>
        </el-form-item>
        <el-form-item label="优先级" required>
          <el-input-number
            v-model="form.priority"
            :min="1"
            :max="100"
            style="width: 100%"
          />
          <div style="color: #909399; font-size: 12px; margin-top: 4px">
            数值越大优先级越高（建议 1-100）
          </div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dialogVisible = false">取消</el-button>
        <el-button type="primary" @click="submitForm">确定</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.uav-model-alias-view {
  padding: 20px;
}

.test-card {
  margin-bottom: 20px;
}

.alias-card {
  margin-bottom: 20px;
}

.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.test-result {
  margin-top: 16px;
}

.result-details {
  margin-top: 8px;
  line-height: 1.8;
}

.result-details p {
  margin: 0;
}
</style>
