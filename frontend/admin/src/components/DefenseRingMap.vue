<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import Feature from 'ol/Feature'
import Map from 'ol/Map'
import View from 'ol/View'
import Circle from 'ol/geom/Circle'
import Point from 'ol/geom/Point'
import TileLayer from 'ol/layer/Tile'
import VectorLayer from 'ol/layer/Vector'
import { fromLonLat, toLonLat } from 'ol/proj'
import OSM from 'ol/source/OSM'
import VectorSource from 'ol/source/Vector'
import XYZ from 'ol/source/XYZ'
import { Circle as CircleStyle, Fill, Stroke, Style } from 'ol/style'
import 'ol/ol.css'

interface RingPreview { code: string; name: string; radius: number; color: string }

const props = defineProps<{ longitude: number | null; latitude: number | null; rings: RingPreview[] }>()
const emit = defineEmits<{ 'update:center': [longitude: number, latitude: number] }>()
const mapElement = ref<HTMLDivElement>()
const source = new VectorSource()
let map: Map | null = null
const STORAGE_KEY = 'huaguoshan.admin.coverageBasemap'

function baseLayers() {
  let settings: { provider?: string; tiandituToken?: string; customUrl?: string } = {}
  try { settings = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') } catch { /* ignore invalid local settings */ }
  if (settings.provider === 'none') return []
  if (settings.provider === 'tianditu' && settings.tiandituToken) return [
    new TileLayer({ source: new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=vec_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(settings.tiandituToken)}` }) }),
    new TileLayer({ source: new XYZ({ url: `https://t0.tianditu.gov.cn/DataServer?T=cva_w&x={x}&y={y}&l={z}&tk=${encodeURIComponent(settings.tiandituToken)}` }) }),
  ]
  if (settings.provider === 'custom' && settings.customUrl) return [new TileLayer({ source: new XYZ({ url: settings.customUrl }) })]
  return [new TileLayer({ source: new OSM() })]
}

function redraw(centerMap = false) {
  source.clear()
  if (props.longitude == null || props.latitude == null) return
  const center = fromLonLat([props.longitude, props.latitude])
  for (const ring of [...props.rings].reverse()) {
    const feature = new Feature(new Circle(center, ring.radius))
    feature.set('color', ring.color)
    source.addFeature(feature)
  }
  const marker = new Feature(new Point(center))
  marker.set('marker', true)
  source.addFeature(marker)
  if (centerMap && map) {
    const outerRadius = Math.max(...props.rings.map((ring) => ring.radius), 1000)
    map.getView().fit([center[0] - outerRadius, center[1] - outerRadius, center[0] + outerRadius, center[1] + outerRadius], { padding: [40, 40, 40, 40], maxZoom: 15, duration: 250 })
  }
}

function createMap() {
  if (map || !mapElement.value) return
  const vectorLayer = new VectorLayer({
    source,
    style: (feature) => {
      if (feature.get('marker')) return new Style({ image: new CircleStyle({ radius: 7, fill: new Fill({ color: '#202522' }), stroke: new Stroke({ color: '#fff', width: 2 }) }) })
      const color = String(feature.get('color') ?? '#28a36a')
      return new Style({ fill: new Fill({ color: `${color}18` }), stroke: new Stroke({ color, width: 2 }) })
    },
  })
  map = new Map({
    target: mapElement.value,
    layers: [...baseLayers(), vectorLayer],
    view: new View({ center: fromLonLat([props.longitude ?? 119.25, props.latitude ?? 34.65]), zoom: 12 }),
  })
  map.on('singleclick', (event) => {
    const [longitude, latitude] = toLonLat(event.coordinate)
    emit('update:center', Number(longitude.toFixed(7)), Number(latitude.toFixed(7)))
  })
  redraw(true)
}

watch(() => [props.longitude, props.latitude, ...props.rings.map((ring) => ring.radius)], () => redraw(), { deep: true })
onMounted(async () => { await nextTick(); createMap() })
onBeforeUnmount(() => map?.setTarget(undefined))

defineExpose({ locate: () => redraw(true) })
</script>

<template>
  <div class="defense-map-shell">
    <div ref="mapElement" class="defense-map" />
    <div class="map-legend">
      <span v-for="ring in rings" :key="ring.code"><i :style="{ backgroundColor: ring.color }" />{{ ring.name }}</span>
    </div>
    <div class="map-hint">单击地图更新圆心；圆形仅按二维距离展示，不使用高度条件。</div>
  </div>
</template>

<style scoped>
.defense-map-shell { position: relative; min-height: 520px; overflow: hidden; border: 1px solid #dfe4e1; border-radius: 6px; background: #eef1ef; }
.defense-map { position: absolute; inset: 0; }
.map-legend { position: absolute; top: 12px; left: 12px; z-index: 2; display: flex; flex-wrap: wrap; gap: 8px 12px; max-width: calc(100% - 24px); padding: 8px 10px; border: 1px solid rgba(32,37,34,.15); border-radius: 4px; background: rgba(255,255,255,.92); color: #3f4944; font-size: 12px; }
.map-legend span { display: inline-flex; align-items: center; gap: 5px; }
.map-legend i { width: 9px; height: 9px; border-radius: 50%; }
.map-hint { position: absolute; right: 12px; bottom: 12px; z-index: 2; padding: 7px 10px; border-radius: 4px; background: rgba(32,37,34,.86); color: #fff; font-size: 12px; }
@media (max-width: 900px) { .defense-map-shell { min-height: 420px; } }
</style>
