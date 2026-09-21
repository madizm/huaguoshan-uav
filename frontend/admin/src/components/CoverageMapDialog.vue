<script setup lang="ts">
import { nextTick, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import Map from 'ol/Map'
import View from 'ol/View'
import GeoJSON from 'ol/format/GeoJSON'
import Draw from 'ol/interaction/Draw'
import Modify from 'ol/interaction/Modify'
import Snap from 'ol/interaction/Snap'
import TileLayer from 'ol/layer/Tile'
import VectorLayer from 'ol/layer/Vector'
import OSM from 'ol/source/OSM'
import XYZ from 'ol/source/XYZ'
import VectorSource from 'ol/source/Vector'
import { fromLonLat } from 'ol/proj'
import MultiPolygon from 'ol/geom/MultiPolygon'
import Polygon from 'ol/geom/Polygon'
import 'ol/ol.css'

const visible = defineModel<boolean>('visible', { required: true })
const geojson = defineModel<string>('geojson', { required: true })
const props = defineProps<{ longitude: number | null; latitude: number | null }>()

const mapElement = ref<HTMLDivElement>()
const source = new VectorSource()
const settingsVisible = ref(false)
const STORAGE_KEY = 'huaguoshan.admin.coverageBasemap'
const basemap = reactive({ provider: 'osm', tiandituToken: '', customUrl: '' })
try { Object.assign(basemap, JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}')) } catch { /* ignore invalid local settings */ }
const baseLayer = new TileLayer({ source: new OSM() })
const labelLayer = new TileLayer({ visible: false })
let map: Map | null = null
let draw: Draw | null = null
const format = new GeoJSON()

function createMap() {
  if (map || !mapElement.value) return
  map = new Map({
    target: mapElement.value,
    layers: [
      baseLayer,
      labelLayer,
      new VectorLayer({ source, style: { 'fill-color': 'rgba(40,163,106,.22)', 'stroke-color': '#1f8a58', 'stroke-width': 2 } }),
    ],
    view: new View({ center: fromLonLat([props.longitude ?? 119.25, props.latitude ?? 34.65]), zoom: 13 }),
  })
  map.addInteraction(new Modify({ source }))
  map.addInteraction(new Snap({ source }))
  applyBasemap(false)
  startDrawing()
}

function applyBasemap(persist = true) {
  labelLayer.setVisible(false)
  if (basemap.provider === 'none') {
    baseLayer.setVisible(false)
  } else if (basemap.provider === 'tianditu') {
    if (!basemap.tiandituToken) {
      ElMessage.warning('请先填写天地图访问令牌')
      settingsVisible.value = true
      return
    }
    baseLayer.setSource(new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=vec_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(basemap.tiandituToken)}`, crossOrigin: 'anonymous' }))
    labelLayer.setSource(new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=cva_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(basemap.tiandituToken)}`, crossOrigin: 'anonymous' }))
    baseLayer.setVisible(true)
    labelLayer.setVisible(true)
  } else if (basemap.provider === 'custom') {
    if (!basemap.customUrl) {
      ElMessage.warning('请填写 XYZ 瓦片地址')
      settingsVisible.value = true
      return
    }
    baseLayer.setSource(new XYZ({ url: basemap.customUrl, crossOrigin: 'anonymous' }))
    baseLayer.setVisible(true)
  } else {
    baseLayer.setSource(new OSM())
    baseLayer.setVisible(true)
  }
  if (persist) localStorage.setItem(STORAGE_KEY, JSON.stringify(basemap))
  map?.render()
}

function saveBasemapSettings() {
  applyBasemap()
  if ((basemap.provider !== 'tianditu' || basemap.tiandituToken) && (basemap.provider !== 'custom' || basemap.customUrl)) settingsVisible.value = false
}

function startDrawing() {
  if (!map) return
  if (draw) map.removeInteraction(draw)
  draw = new Draw({ source, type: 'Polygon' })
  map.addInteraction(draw)
}

function loadGeometry() {
  source.clear()
  try {
    const parsed = JSON.parse(geojson.value || '{}')
    if (!['Polygon', 'MultiPolygon'].includes(parsed.type)) return
    const features = format.readFeatures(parsed, { dataProjection: 'EPSG:4326', featureProjection: 'EPSG:3857' })
    source.addFeatures(features)
    const extent = source.getExtent()
    if (extent) map?.getView().fit(extent, { padding: [40, 40, 40, 40], maxZoom: 16 })
  } catch {
    ElMessage.warning('现有 GeoJSON 无法加载，请清空后重新绘制')
  }
}

function clearAll() { source.clear() }

function saveGeometry() {
  const polygons: number[][][][] = []
  for (const feature of source.getFeatures()) {
    const geometry = feature.getGeometry()?.clone().transform('EPSG:3857', 'EPSG:4326')
    if (geometry instanceof Polygon) polygons.push(geometry.getCoordinates())
    if (geometry instanceof MultiPolygon) polygons.push(...geometry.getCoordinates())
  }
  if (polygons.length === 0) {
    ElMessage.warning('请至少绘制一个多边形')
    return
  }
  const geometry = polygons.length === 1
    ? { type: 'Polygon', coordinates: polygons[0] }
    : { type: 'MultiPolygon', coordinates: polygons }
  geojson.value = JSON.stringify(geometry)
  visible.value = false
}

watch(visible, async (open) => {
  if (!open) return
  await nextTick()
  createMap()
  map?.setTarget(mapElement.value)
  map?.updateSize()
  loadGeometry()
})
onBeforeUnmount(() => { map?.setTarget(undefined); map = null })
</script>

<template>
  <el-dialog v-model="visible" title="绘制能力覆盖范围" width="820px" destroy-on-close append-to-body>
    <div class="map-toolbar">
      <span>单击绘制顶点，双击结束；可绘制多个区域并拖动顶点调整。</span>
      <div class="map-actions">
        <el-select v-model="basemap.provider" size="small" style="width: 120px" @change="applyBasemap()">
          <el-option label="OpenStreetMap" value="osm" />
          <el-option label="天地图" value="tianditu" />
          <el-option label="自定义 XYZ" value="custom" />
          <el-option label="无底图" value="none" />
        </el-select>
        <el-button size="small" @click="settingsVisible = true">底图设置</el-button>
        <el-button size="small" type="danger" plain @click="clearAll">清空</el-button>
      </div>
    </div>
    <div ref="mapElement" class="coverage-map" />
    <el-dialog v-model="settingsVisible" title="底图设置" width="520px" append-to-body>
      <el-form label-width="120px">
        <el-form-item label="底图类型">
          <el-select v-model="basemap.provider" style="width: 100%">
            <el-option label="OpenStreetMap" value="osm" />
            <el-option label="天地图矢量" value="tianditu" />
            <el-option label="自定义 XYZ" value="custom" />
            <el-option label="无底图" value="none" />
          </el-select>
        </el-form-item>
        <el-form-item v-if="basemap.provider === 'tianditu'" label="天地图令牌">
          <el-input v-model="basemap.tiandituToken" type="password" show-password placeholder="请输入天地图 tk" />
        </el-form-item>
        <el-form-item v-if="basemap.provider === 'custom'" label="XYZ 地址">
          <el-input v-model="basemap.customUrl" placeholder="https://example.com/{z}/{x}/{y}.png" />
        </el-form-item>
        <el-alert title="设置保存在当前浏览器中，不会写入设备业务数据。" type="info" :closable="false" />
      </el-form>
      <template #footer>
        <el-button @click="settingsVisible = false">取消</el-button>
        <el-button type="primary" @click="saveBasemapSettings">保存并应用</el-button>
      </template>
    </el-dialog>
    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" @click="saveGeometry">应用范围</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.map-toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; color: #5d6862; font-size: 13px; }
.map-actions { display: flex; align-items: center; gap: 8px; }
.coverage-map { width: 100%; height: 520px; border: 1px solid #dfe4e1; border-radius: 6px; overflow: hidden; }
</style>
