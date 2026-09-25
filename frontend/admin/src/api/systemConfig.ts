import { http } from './http'

export interface SystemConfigRow {
  key: string
  value: Record<string, unknown>
  description: string
  updated_at: string
}

export interface MapBasemapConfig {
  provider: 'osm' | 'tianditu' | 'custom' | 'none'
  tiandituToken: string
  customUrl: string
}

const BASEMAP_KEY = 'map.basemap'

const DEFAULT_BASEMAP: MapBasemapConfig = { provider: 'osm', tiandituToken: '', customUrl: '' }

/** 从数据库读取地图底图配置；不存在时返回默认 OSM。 */
export async function getMapBasemapConfig(): Promise<MapBasemapConfig> {
  const rows = await http.get<SystemConfigRow[]>('/system_config', { key: `eq.${BASEMAP_KEY}` })
  if (rows.length === 0) return { ...DEFAULT_BASEMAP }
  const v = rows[0].value as Partial<MapBasemapConfig>
  return {
    provider: v.provider ?? 'osm',
    tiandituToken: v.tiandituToken ?? '',
    customUrl: v.customUrl ?? '',
  }
}

/** 将地图底图配置写入数据库（upsert by key）。 */
export async function saveMapBasemapConfig(config: MapBasemapConfig): Promise<void> {
  await http.post(
    '/system_config',
    {
      key: BASEMAP_KEY,
      value: config,
      description: '地图底图配置：provider 可选 osm/tianditu/custom/none，tiandituToken 天地图访问令牌，customUrl 自定义 XYZ 瓦片地址。',
    },
    ['resolution=merge-duplicates'],
  )
}
