export interface EmergencyField { key:string; label:string; kind:'text'|'number'|'json'; required?:boolean; min?:number }
const t=(key:string,label:string,required=false):EmergencyField=>({key,label,kind:'text',required})
const n=(key:string,label:string,min=0):EmergencyField=>({key,label,kind:'number',min})
const j=(key:string,label:string):EmergencyField=>({key,label,kind:'json'})
export const emergencyResourceLabels: Record<string, string> = {
  medical_resource: '医疗资源', expert_force: '专家力量', shelter: '避难场所',
  material_warehouse: '物资仓库', water_point: '取水点', landing_site: '起降点',
  police_station: '智慧警务站',
}

export const emergencyResourceForms:Record<string,{fields:EmergencyField[];statuses:string[]}>= {
 medical_resource:{fields:[t('resource_type','医疗资源类型',true),t('unit_name','所属单位',true),n('service_capacity','服务能力'),n('ambulance_count','救护车数量')],statuses:['available','busy','standby','unavailable']},
 expert_force:{fields:[t('expertise','专业方向',true),t('organization_name','所属机构',true),t('professional_title','专业职称')],statuses:['available','consulting','standby','unavailable']},
 shelter:{fields:[t('venue_type','场所类型',true),t('managing_unit_name','管理单位',true),n('capacity','最大容量',1),n('current_occupancy','当前人数')],statuses:['available','preparing','occupied','unavailable']},
 material_warehouse:{fields:[t('warehouse_type','仓库类型',true),t('managing_unit_name','管理单位',true),n('storage_capacity_t','仓储能力（吨）'),j('inventory_summary','库存摘要 JSON')],statuses:['available','dispatching','restocking','unavailable']},
 water_point:{fields:[t('water_source_type','水源类型',true),t('managing_unit_name','管理单位'),n('estimated_supply_m3_h','供水能力（m³/h）')],statuses:['available','limited','maintenance','unavailable']},
 landing_site:{fields:[t('site_type','场地类型',true),t('managing_unit_name','管理单位',true),n('max_aircraft_count','飞行器容量',1)],statuses:['available','occupied','standby','maintenance','unavailable']},
 police_station:{fields:[t('station_type','站点类型',true),t('managing_unit_name','管理机关'),t('address','地址'),t('county_name','区县')],statuses:['available','unavailable','unknown']},
}
