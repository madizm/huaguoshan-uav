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
import { useBasemapConfig } from '../api/basemapStore'

interface RingPreview { code: string; name: string; radius: number; color: string }

const props = defineProps<{ longitude: number | null; latitude: number | null; rings: RingPreview[] }>()
const emit = defineEmits<{ 'update:center': [longitude: number, latitude: number] }>()
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

function locate() {
  if (!map || props.longitude == null || props.latitude == null) return
  const center = fromLonLat([props.longitude, props.latitude])
  const outerRadius = Math.max(...props.rings.map((ring) => ring.radius), 1000)
  map.getView().fit([center[0] - outerRadius, center[1] - outerRadius, center[0] + outerRadius, center[1] + outerRadius], { padding: [40, 40, 40, 40], maxZoom: 15, duration: 250 })
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
  map.on('pointermove', (event) => {
    const hit = map!.forEachFeatureAtPixel(event.pixel, (f) => f.get('marker'))
    mapElement.value!.style.cursor = hit ? 'grab' : ''
  })
  let dragging = false
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  map.on('pointerdown' as any, (event: any) => {
    const hit = map!.forEachFeatureAtPixel(event.pixel, (f) => f.get('marker'))
    if (hit) dragging = true
  })
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  map.on('pointerup' as any, (event: any) => {
    if (!dragging) return
    dragging = false
    const [lon, lat] = toLonLat(event.coordinate)
    emit('update:center', Number(lon.toFixed(7)), Number(lat.toFixed(7)))
  })
  redraw()
}

watch(() => [props.longitude, props.latitude, props.rings] as const, () => redraw(true), { deep: true })

onMounted(async () => {
  await loadBasemap()
  await nextTick()
  createMap()
})

onBeforeUnmount(() => { map?.setTarget(undefined); map = null })

defineExpose({ locate })
</script>

<template>
  <div ref="mapElement" class="defense-ring-map" />
</template>

<style scoped>
.defense-ring-map { width: 100%; height: 420px; border: 1px solid #dfe4e1; border-radius: 6px; overflow: hidden; }
</style>
