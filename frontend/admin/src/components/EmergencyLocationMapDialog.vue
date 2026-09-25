<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import Map from 'ol/Map'
import View from 'ol/View'
import Feature from 'ol/Feature'
import Point from 'ol/geom/Point'
import Modify from 'ol/interaction/Modify'
import TileLayer from 'ol/layer/Tile'
import VectorLayer from 'ol/layer/Vector'
import OSM from 'ol/source/OSM'
import XYZ from 'ol/source/XYZ'
import VectorSource from 'ol/source/Vector'
import { fromLonLat, toLonLat } from 'ol/proj'
import 'ol/ol.css'
import { useBasemapConfig } from '../api/basemapStore'

const visible = defineModel<boolean>('visible', { required: true })
const longitude = defineModel<number | null>('longitude', { required: true })
const latitude = defineModel<number | null>('latitude', { required: true })
const mapElement = ref<HTMLDivElement>()
const source = new VectorSource()
const { basemap, load: loadBasemap } = useBasemapConfig()
let map: Map | null = null

function baseLayers() {
  if (basemap.provider === 'none') return []
  if (basemap.provider === 'tianditu' && basemap.tiandituToken) return [
    new TileLayer({ source: new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=vec_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(basemap.tiandituToken)}` }) }),
    new TileLayer({ source: new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=cva_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(basemap.tiandituToken)}` }) }),
  ]
  if (basemap.provider === 'custom' && basemap.customUrl) return [new TileLayer({ source: new XYZ({ url: basemap.customUrl }) })]
  return [new TileLayer({ source: new OSM() })]
}

function setMarker(lon: number, lat: number) {
  source.clear()
  source.addFeature(new Feature(new Point(fromLonLat([lon, lat]))))
}
function createMap() {
  if (map || !mapElement.value) return
  map = new Map({
    target: mapElement.value,
    layers: [...baseLayers(), new VectorLayer({ source, style: { 'circle-radius': 8, 'circle-fill-color': '#28a36a', 'circle-stroke-color': '#fff', 'circle-stroke-width': 2 } })],
    view: new View({ center: fromLonLat([longitude.value ?? 119.25, latitude.value ?? 34.65]), zoom: 14 }),
  })
  map.addInteraction(new Modify({ source }))
  map.on('singleclick', (event) => setMarker(...toLonLat(event.coordinate) as [number, number]))
}
function applyLocation() {
  const feature = source.getFeatures()[0]
  const geometry = feature?.getGeometry()
  if (!(geometry instanceof Point)) { ElMessage.warning('请在地图上选择位置'); return }
  const [lon, lat] = toLonLat(geometry.getCoordinates())
  longitude.value = Number(lon.toFixed(7)); latitude.value = Number(lat.toFixed(7)); visible.value = false
}
watch(visible, async (open) => {
  if (!open) return
  await loadBasemap()
  await nextTick(); createMap(); map?.setTarget(mapElement.value); map?.updateSize()
  if (longitude.value != null && latitude.value != null) setMarker(longitude.value, latitude.value)
})
onBeforeUnmount(() => map?.setTarget(undefined))
</script>
<template><el-dialog v-model="visible" title="选择资源位置" width="820px" append-to-body destroy-on-close><el-alert title="单击地图设置位置；已有点位可以拖动调整。底图配置请在系统设置中修改。" type="info" :closable="false" class="hint"/><div ref="mapElement" class="location-map"/><template #footer><el-button @click="visible=false">取消</el-button><el-button type="primary" @click="applyLocation">应用位置</el-button></template></el-dialog></template>
<style scoped>.hint{margin-bottom:10px}.location-map{height:520px;border:1px solid #dfe4e1;border-radius:6px;overflow:hidden}</style>
