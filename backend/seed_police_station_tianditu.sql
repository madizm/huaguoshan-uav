-- 连云港市警务工作站/警务站真实 POI 数据导入。
--
-- 来源：天地图地名搜索 V2.0（queryType=13 分类搜索，分类码 190200 公检法机构）
-- 覆盖范围：连云港市全域（连云/海州/赣榆/东海/灌云/灌南，已全量分页拉取）
-- 坐标：天地图 CGCS2000，按 WGS84 等同处理，写入 EPSG:4326 Point。
-- 幂等：以 source_code = 'TDT-' || hotPointID 为冲突键重复导入。

begin;

insert into emergency_resource.police_station (
  source_code, name, station_type, managing_unit_name, address, county_name,
  availability_status, is_simulated, metadata, geom
) values
  ('TDT-B3DBFFF4B677C0A9', '赣榆区公安局沙河派出所殷庄警务工作站', 'workstation', '赣榆区公安局沙河派出所', '沙河镇殷庄泰和街沙河镇殷庄社区卫生中心对面正东方向110米', '赣榆区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "B3DBFFF4B677C0A9", "keyword": "警务工作站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.01415, 34.78732), 4326)),
  ('TDT-2AF52E5BF7941376', '东海县公安局埝河警务工作站', 'workstation', '东海县公安局', '江苏省连云港市东海县石榴街道东海县公安局埝河警务工作站', '东海县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "2AF52E5BF7941376", "keyword": "警务工作站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(118.782424, 34.588974), 4326)),
  ('TDT-D22B0401155F347A', '东海联勤007警务站', 'station', null, '江苏省连云港市东海县江苏东海经济开发区海陵东路297(东海国际水晶珠宝城)', '东海县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "D22B0401155F347A", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(118.780892, 34.530345), 4326)),
  ('TDT-35E61E283AAFF4B9', '东海联勤008警务站', 'station', null, '江苏省连云港市东海县牛山街道东海二四五省道段西侧、晶都路北侧东南方向80米', '东海县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "35E61E283AAFF4B9", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(118.780199, 34.543056), 4326)),
  ('TDT-F98A440575216BC2', '东海联勤009警务站', 'station', null, '江苏省连云港市东海县牛山街道牛山北路203正北方向80米', '东海县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "F98A440575216BC2", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(118.763121, 34.542479), 4326)),
  ('TDT-43EF5104F32FD888', '东海联勤010警务站', 'station', null, '江苏省连云港市东海县牛山街道牛山北路197-18正北方向40米', '东海县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "43EF5104F32FD888", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(118.76211, 34.537177), 4326)),
  ('TDT-67EFBEDE5E83D4B4', '连云港市公安局交警支队海州二大队岗埠警务站', 'station', '连云港市公安局交警支队海州二大队', '腾飞南路12', '海州区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "67EFBEDE5E83D4B4", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.032, 34.5841), 4326)),
  ('TDT-70186C0D77937C53', '连云港市公安局花果山服务区警务站', 'station', '连云港市公安局', '江苏省连云港市海州区浦南镇', '海州区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "70186C0D77937C53", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.080653, 34.634108), 4326)),
  ('TDT-069596A51A10CCBA', '连云港市公安局锦屏山服务区警务站', 'station', '连云港市公安局', '江苏省连云港市海州区锦屏镇', '海州区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "069596A51A10CCBA", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.160633, 34.521686), 4326)),
  ('TDT-9B6B82A6563C5E5D', '灌云县公安局伊山派出所城南警务站', 'station', '灌云县公安局伊山派出所', '人民中路55', '灌云县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "9B6B82A6563C5E5D", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.25213, 34.29135), 4326)),
  ('TDT-301EB19393AFE199', '警务站', 'station', null, '江苏省连云港市灌云县小伊镇物流大道(连云港花果山国际机场)', '灌云县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "301EB19393AFE199", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.188014, 34.409359), 4326)),
  ('TDT-A75BD7DCAAB1B8F3', '警务站', 'station', null, '江苏省连云港市灌云县小伊镇物流大道(连云港花果山国际机场)', '灌云县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "A75BD7DCAAB1B8F3", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.18527, 34.411444), 4326)),
  ('TDT-10368BFFC47FD4E5', '连云港市公安局灌云服务区警务站', 'station', '连云港市公安局', '江苏省连云港市灌云县图河镇', '灌云县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "10368BFFC47FD4E5", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.432945, 34.351072), 4326)),
  ('TDT-D2FE24262C94DE6B', '公安人民路警务工作站', 'workstation', null, '江苏省连云港市灌南县新安镇人民东路8东北方向110米', '灌南县', 'unknown', false, '{"provider": "tianditu", "hotPointID": "D2FE24262C94DE6B", "keyword": "警务工作站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.345057, 34.094084), 4326)),
  ('TDT-D0BB6B6752D6CC69', '沙河服务区公安警务站', 'station', null, '江苏省连云港市赣榆区沙河镇长深高速沙河服务区', '赣榆区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "D0BB6B6752D6CC69", "keyword": "警务站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.0165, 34.80175), 4326)),
  ('TDT-69FB12849D650094', '赣榆区公安分局综合警务工作站', 'workstation', '赣榆区公安分局', '黄海路0121东北方向10米', '赣榆区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "69FB12849D650094", "keyword": "警务工作站", "poiType": "101"}'::jsonb, ST_SetSRID(ST_MakePoint(119.123, 34.84093), 4326)),
  ('TDT-FB203098C75CC2FA', '赣马服务区-警务站', 'station', null, '赣马服务区内正西方向18米', '赣榆区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "FB203098C75CC2FA", "keyword": "警务站", "poiType": "101", "duplicateHint": "与『连云港市公安局海州湾服务区警务站』位置相距约281米，疑为同一实体的重复POI记录"}'::jsonb, ST_SetSRID(ST_MakePoint(119.11234, 34.90338), 4326)),
  ('TDT-3BF38BA6F552B8AE', '连云港市公安局海州湾服务区警务站', 'station', '连云港市公安局', '江苏省连云港市赣榆区赣马镇', '赣榆区', 'unknown', false, '{"provider": "tianditu", "hotPointID": "3BF38BA6F552B8AE", "keyword": "警务站", "poiType": "101", "duplicateHint": "与『赣马服务区-警务站』位置相距约281米，疑为同一实体的重复POI记录"}'::jsonb, ST_SetSRID(ST_MakePoint(119.114175, 34.901396), 4326))
on conflict (source_code) do update set
  name = excluded.name,
  station_type = excluded.station_type,
  managing_unit_name = excluded.managing_unit_name,
  address = excluded.address,
  county_name = excluded.county_name,
  metadata = excluded.metadata,
  geom = excluded.geom,
  is_simulated = false;

commit;
