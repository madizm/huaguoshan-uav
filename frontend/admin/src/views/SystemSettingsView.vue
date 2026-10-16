<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getMapBasemapConfig, saveMapBasemapConfig, type MapBasemapConfig } from '../api/systemConfig'
import { useServerClock } from '../components/useServerClock'

const loading = ref(false)
const saving = ref(false)
const basemap = reactive<MapBasemapConfig>({ provider: 'osm', tiandituToken: '', customUrl: '' })
const updatedAt = ref('')
const { currentTime, status: clockStatus, syncing: clockSyncing, syncError: clockSyncError, sync: syncClock } = useServerClock()
const clockFormatter = new Intl.DateTimeFormat('zh-CN', {
  timeZone: 'Asia/Shanghai',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
  timeZoneName: 'short',
})
const clockText = computed(() => currentTime.value ? clockFormatter.format(currentTime.value) : '等待服务器时间…')

async function load() {
  loading.value = true
  try {
    const config = await getMapBasemapConfig()
    Object.assign(basemap, config)
  } catch (e: unknown) {
    ElMessage.error(`加载配置失败：${(e as Error).message}`)
  } finally {
    loading.value = false
  }
}

async function save() {
  if (basemap.provider === 'tianditu' && !basemap.tiandituToken) {
    ElMessage.warning('使用天地图底图需要填写访问令牌')
    return
  }
  if (basemap.provider === 'custom' && !basemap.customUrl) {
    ElMessage.warning('使用自定义底图需要填写 XYZ 瓦片地址')
    return
  }
  saving.value = true
  try {
    await saveMapBasemapConfig({ ...basemap })
    ElMessage.success('底图配置已保存')
    updatedAt.value = new Date().toLocaleString()
  } catch (e: unknown) {
    ElMessage.error(`保存失败：${(e as Error).message}`)
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="settings-page">
    <el-card shadow="never" class="clock-card">
      <template #header>
        <div class="card-header"><span>系统时钟</span><el-tag type="info">只读</el-tag></div>
      </template>
      <time v-if="currentTime" class="system-clock" :datetime="currentTime.toISOString()">{{ clockText }}</time>
      <span v-else class="system-clock">{{ clockText }}</span>
      <div class="clock-status">
        <el-tag :type="clockStatus === '已同步' ? 'success' : 'warning'">{{ clockStatus }}</el-tag>
        <el-button text :loading="clockSyncing" @click="syncClock">重新同步</el-button>
      </div>
      <div class="form-hint">数据库服务器时间 · 北京时间（UTC+8）。每秒刷新，每 30 秒校准，只读。</div>
      <div v-if="clockStatus === '同步已过期'" class="form-hint">当前显示为上次同步后的估算时间，请重新同步。</div>
      <div v-else-if="clockSyncError" class="form-hint">无法获取服务器时间，请检查网络或服务器接口。</div>
    </el-card>
    <el-card shadow="never" v-loading="loading">
      <template #header>
        <div class="card-header">
          <span>地图底图配置</span>
          <small v-if="updatedAt">上次保存：{{ updatedAt }}</small>
        </div>
      </template>

      <el-form label-width="120px" style="max-width: 600px">
        <el-form-item label="底图类型">
          <el-select v-model="basemap.provider" style="width: 100%">
            <el-option label="OpenStreetMap" value="osm" />
            <el-option label="天地图矢量" value="tianditu" />
            <el-option label="自定义 XYZ" value="custom" />
            <el-option label="无底图" value="none" />
          </el-select>
        </el-form-item>

        <el-form-item v-if="basemap.provider === 'tianditu'" label="天地图令牌">
          <el-input
            v-model="basemap.tiandituToken"
            type="password"
            show-password
            placeholder="请输入天地图 tk"
          />
          <div class="form-hint">
            在
            <a href="https://console.tianditu.gov.cn" target="_blank" rel="noopener">天地图控制台</a>
            申请 Web 服务类型的令牌。
          </div>
        </el-form-item>

        <el-form-item v-if="basemap.provider === 'custom'" label="XYZ 地址">
          <el-input
            v-model="basemap.customUrl"
            placeholder="https://example.com/{z}/{x}/{y}.png"
          />
          <div class="form-hint">支持 {x}、{y}、{z} 占位符的标准 XYZ 瓦片地址。</div>
        </el-form-item>

        <el-form-item>
          <el-button type="primary" :loading="saving" @click="save">保存配置</el-button>
        </el-form-item>
      </el-form>

      <el-alert
        title="此配置为全局设置，保存后所有地图组件（能力覆盖、防御圈、应急资源位置）将统一使用新的底图。"
        type="info"
        :closable="false"
      />
    </el-card>
  </div>
</template>

<style scoped>
.settings-page {
  max-width: 800px;
}
.clock-card {
  margin-bottom: 20px;
}
.clock-status {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 8px;
}
.system-clock {
  font-size: 24px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.card-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}
.card-header span {
  font-size: 16px;
  font-weight: 600;
}
.card-header small {
  color: #909399;
  font-size: 12px;
}
.form-hint {
  margin-top: 4px;
  color: #909399;
  font-size: 12px;
  line-height: 1.5;
}
.form-hint a {
  color: #28a36a;
  text-decoration: none;
}
.form-hint a:hover {
  text-decoration: underline;
}
</style>
