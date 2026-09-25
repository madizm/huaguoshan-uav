import { reactive } from 'vue'
import { getMapBasemapConfig, saveMapBasemapConfig, type MapBasemapConfig } from '../api/systemConfig'

/** 全局底图配置缓存；首次使用时从数据库加载，保存后同步更新。 */
const basemapState = reactive<MapBasemapConfig>({ provider: 'osm', tiandituToken: '', customUrl: '' })
let loaded = false
let loadPromise: Promise<MapBasemapConfig> | null = null

export function useBasemapConfig() {
  async function load(): Promise<MapBasemapConfig> {
    if (loaded) return { ...basemapState }
    if (loadPromise) return loadPromise
    loadPromise = getMapBasemapConfig().then((config) => {
      Object.assign(basemapState, config)
      loaded = true
      return { ...basemapState }
    })
    return loadPromise
  }

  async function save(config: MapBasemapConfig): Promise<void> {
    await saveMapBasemapConfig(config)
    Object.assign(basemapState, config)
    loaded = true
  }

  return { basemap: basemapState, load, save }
}
