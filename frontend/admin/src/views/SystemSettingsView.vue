<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getMapBasemapConfig, saveMapBasemapConfig, type MapBasemapConfig } from '../api/systemConfig'

const loading = ref(false)
const saving = ref(false)
const basemap = reactive<MapBasemapConfig>({ provider: 'osm', tiandituToken: '', customUrl: '' })
const updatedAt = ref('')

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
  <div class="settings-page" v-loading="loading">
    <el-card shadow="never">
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
