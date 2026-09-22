export type CoverageGenerationMode = 'manual' | 'radial' | 'sector'

export interface CapabilityRangeParameters {
  min_range_m: number | null
  max_range_m: number | null
  range_basis: string
  frequency_min_mhz: number | null
  frequency_max_mhz: number | null
  positioning_mode: string
}

export interface GeneratedCoverageOptions {
  longitude: number
  latitude: number
  radiusM: number
  mode: Exclude<CoverageGenerationMode, 'manual'>
  azimuthStartDeg?: number
  azimuthEndDeg?: number
  segments?: number
}

const EARTH_RADIUS_M = 6_371_008.8

function finiteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

export function readCapabilityRangeParameters(parameters: Record<string, unknown>): CapabilityRangeParameters {
  return {
    min_range_m: finiteNumber(parameters.min_range_m),
    max_range_m: finiteNumber(parameters.max_range_m),
    range_basis: typeof parameters.range_basis === 'string' ? parameters.range_basis : 'vendor_spec',
    frequency_min_mhz: finiteNumber(parameters.frequency_min_mhz),
    frequency_max_mhz: finiteNumber(parameters.frequency_max_mhz),
    positioning_mode: typeof parameters.positioning_mode === 'string' ? parameters.positioning_mode : '',
  }
}

export function validateCapabilityRangeParameters(values: CapabilityRangeParameters): string | null {
  if (values.min_range_m !== null && values.min_range_m < 0) return '最小侦测距离不能小于 0'
  if (values.max_range_m !== null && values.max_range_m <= 0) return '最大侦测距离必须大于 0'
  if (values.min_range_m !== null && values.max_range_m !== null && values.min_range_m > values.max_range_m) {
    return '最小侦测距离不能大于最大侦测距离'
  }
  if (values.frequency_min_mhz !== null && values.frequency_min_mhz < 0) return '最低频率不能小于 0'
  if (values.frequency_max_mhz !== null && values.frequency_max_mhz < 0) return '最高频率不能小于 0'
  if (values.frequency_min_mhz !== null && values.frequency_max_mhz !== null
      && values.frequency_min_mhz > values.frequency_max_mhz) {
    return '最低频率不能大于最高频率'
  }
  return null
}

function destination(longitude: number, latitude: number, distanceM: number, azimuthDeg: number): [number, number] {
  const angularDistance = distanceM / EARTH_RADIUS_M
  const bearing = azimuthDeg * Math.PI / 180
  const lat1 = latitude * Math.PI / 180
  const lon1 = longitude * Math.PI / 180
  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(angularDistance)
      + Math.cos(lat1) * Math.sin(angularDistance) * Math.cos(bearing),
  )
  const lon2 = lon1 + Math.atan2(
    Math.sin(bearing) * Math.sin(angularDistance) * Math.cos(lat1),
    Math.cos(angularDistance) - Math.sin(lat1) * Math.sin(lat2),
  )
  const normalizedLongitude = ((lon2 * 180 / Math.PI + 540) % 360) - 180
  return [normalizedLongitude, lat2 * 180 / Math.PI]
}

export function generateCapabilityCoverage(options: GeneratedCoverageOptions): Record<string, unknown> {
  if (!Number.isFinite(options.longitude) || options.longitude < -180 || options.longitude > 180
      || !Number.isFinite(options.latitude) || options.latitude < -90 || options.latitude > 90) {
    throw new Error('设备经纬度无效，无法生成覆盖范围')
  }
  if (!Number.isFinite(options.radiusM) || options.radiusM <= 0) throw new Error('覆盖半径必须大于 0')
  const segments = Math.max(16, Math.min(360, Math.round(options.segments ?? 72)))
  let ring: [number, number][]
  if (options.mode === 'radial') {
    ring = Array.from({ length: segments + 1 }, (_, index) => (
      destination(options.longitude, options.latitude, options.radiusM, index * 360 / segments)
    ))
  } else {
    const start = finiteNumber(options.azimuthStartDeg)
    const endValue = finiteNumber(options.azimuthEndDeg)
    if (start === null || endValue === null || start < 0 || start > 360 || endValue < 0 || endValue > 360) {
      throw new Error('扇区起止方位角必须在 0–360° 之间')
    }
    let end = endValue
    if (end <= start) end += 360
    const span = end - start
    if (span <= 0 || span > 360) throw new Error('扇区方位范围无效')
    const arcSegments = Math.max(8, Math.ceil(segments * span / 360))
    ring = [[options.longitude, options.latitude]]
    for (let index = 0; index <= arcSegments; index += 1) {
      ring.push(destination(options.longitude, options.latitude, options.radiusM, start + span * index / arcSegments))
    }
    ring.push([options.longitude, options.latitude])
  }
  return { type: 'Polygon', coordinates: [ring] }
}
