-- 连云港市警务工作站/警务站真实 POI 数据导入（高德来源）。
--
-- 来源：高德 Web 服务 POI 关键字搜索（city=连云港, citylimit=true），
-- 关键字『警务工作站』与『警务站』，按名称命中过滤并与库内天地图记录做实体对齐。
-- 坐标：高德 GCJ-02 已按 coordtransform 近似算法纠偏为 WGS84，写入 EPSG:4326 Point。
-- 幂等：新记录以 source_code = 'AMAP-' || 高德POI id 为冲突键；
-- 已对齐的天地图记录仅合并 metadata（sources、amap 快照），可重复执行。
-- 生成脚本：scripts/import_amap_police_stations.py

begin;

-- 与库内天地图记录对齐：合并 metadata
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B020602DLU", "name": "花果山服务区公安警务站", "address": "沈海高速", "gcj02": [119.086236, 34.632977], "wgs84": [119.080502, 34.633816]}}'::jsonb
where source_code = 'TDT-70186C0D77937C53';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B020601LKN", "name": "锦屏山服务区公安警务站", "address": "锦屏山服务区与G30连霍高速交叉口西300米", "gcj02": [119.166283, 34.520852], "wgs84": [119.16065, 34.521857]}}'::jsonb
where source_code = 'TDT-069596A51A10CCBA';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0FFH0LW5S", "name": "伊山派出所城南警务站", "address": "人民中路55号", "gcj02": [119.257613, 34.290229], "wgs84": [119.252132, 34.291471]}}'::jsonb
where source_code = 'TDT-9B6B82A6563C5E5D';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0JDZ5CLMA", "name": "公安人民路警务工作站", "address": "人民中路", "gcj02": [119.350734, 34.092837], "wgs84": [119.345124, 34.094011]}}'::jsonb
where source_code = 'TDT-D2FE24262C94DE6B';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0FFM7R0S1", "name": "沙河服务区公安警务站", "address": "长深高速沙河服务区", "gcj02": [119.022138, 34.801092], "wgs84": [119.016534, 34.801886]}}'::jsonb
where source_code = 'TDT-D0BB6B6752D6CC69';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0GR3OLK90", "name": "沙河派出所殷庄警务站", "address": "青沙线", "gcj02": [119.019598, 34.786429], "wgs84": [119.014005, 34.787246]}}'::jsonb
where source_code = 'TDT-B3DBFFF4B677C0A9';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0FFFFYD88", "name": "海州湾服务区公安警务站", "address": "G15沈海高速附近", "gcj02": [119.117981, 34.902649], "wgs84": [119.112223, 34.903221]}}'::jsonb
where source_code = 'TDT-3BF38BA6F552B8AE';
update emergency_resource.police_station
set metadata = metadata || '{"sources": ["tianditu", "amap"], "amap": {"id": "B0H0YZJQDX", "name": "赣榆区公安分局综合警务工作站", "address": "黄海路42号", "gcj02": [119.129087, 34.840321], "wgs84": [119.123348, 34.840972]}}'::jsonb
where source_code = 'TDT-69FB12849D650094';

-- 高德独有点位：新增记录
insert into emergency_resource.police_station (
  source_code, name, station_type, managing_unit_name, contact_phone, address, county_name,
  availability_status, is_simulated, metadata, geom
) values
  ('AMAP-B0FFKXOWST', '东海县公安局兴隆警务工作站', 'workstation', '东海县公安局', null, '瑞安路与三兴路交叉口西北40米', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0FFKXOWST", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.759236, "latitude": 34.616762, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.753762, 34.617805), 4326)),
  ('AMAP-B0FFKJ1HPD', '东海县公安局南辰警务工作站', 'workstation', '东海县公安局', null, '横山公路南辰乡政府', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0FFKJ1HPD", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.740356, "latitude": 34.742498, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.734871, 34.743424), 4326)),
  ('AMAP-B0M625WDYC', '东海县公安局曲阳警务工作站', 'workstation', '东海县公安局', null, '311国道东侧', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0M625WDYC", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.645761, "latitude": 34.440403, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.640476, 34.441719), 4326)),
  ('AMAP-B0FFJOEL7I', '东海县公安局浦西警务工作站', 'workstation', '东海县公安局', null, '石泉公路', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0FFJOEL7I", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.735289, "latitude": 34.569356, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.729825, 34.570441), 4326)),
  ('AMAP-B0KADZRPEQ', '水晶城警务工作站', 'workstation', null, null, '牛山街道中华路1号', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0KADZRPEQ", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.740662, "latitude": 34.54094, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.735197, 34.542044), 4326)),
  ('AMAP-B0MR3S0UNM', '薛团警务工作站', 'workstation', null, null, '薛团人口文化广场东北侧140米', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0MR3S0UNM", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.548776, "latitude": 34.494511, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.543467, 34.495783), 4326)),
  ('AMAP-B0L6XC3V13', '西双湖警务工作站', 'workstation', null, null, '湖滨南路009号', '东海县', 'unknown', false, '{"provider": "amap", "amapId": "B0L6XC3V13", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.735648, "latitude": 34.528242, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.730188, 34.529358), 4326)),
  ('AMAP-B0JBLARC02', '110公安郁洲路警务工作站', 'workstation', null, null, '解放东路与郁洲北路交叉口东北40米', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0JBLARC02", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.189638, "latitude": 34.61247, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.184048, 34.613446), 4326)),
  ('AMAP-B0M69SACES', '公安局警务工作站(白虎山数字贸易产业园站)', 'workstation', null, null, '一带一路数字贸易产业园东北侧70米', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0M69SACES", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.140852, "latitude": 34.577062, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.13516, 34.57798), 4326)),
  ('AMAP-B020601F7Z', '朐阳派出所东片警务工作站', 'workstation', '朐阳派出所', null, '网疃村果园队1-2附近', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B020601F7Z", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.153782, "latitude": 34.569403, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.148117, 34.570348), 4326)),
  ('AMAP-B0206022JL', '洪门派出所市场警务工作站', 'workstation', '洪门派出所', '0518-85253120', '连云港农产品交易市场', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0206022JL", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.11984, "latitude": 34.590132, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.114117, 34.591014), 4326)),
  ('AMAP-B0G0FRBV11', '海州公安分局警务站', 'station', '海州公安分局', null, '通灌南路与青圃路交叉口西南40米', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0G0FRBV11", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.190789, "latitude": 34.56553, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.185206, 34.566546), 4326)),
  ('AMAP-B0K6C720N9', '盐河巷警务工作站', 'workstation', null, null, '陇海西路盐河北路红绿灯东侧', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0K6C720N9", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.171325, "latitude": 34.599534, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.165695, 34.600487), 4326)),
  ('AMAP-B0M6CHVJIT', '连云港市公安局吾悦广场警务工作站', 'workstation', '连云港市公安局', null, '秦东门大街390号', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0M6CHVJIT", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.194484, "latitude": 34.569492, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.188909, 34.570512), 4326)),
  ('AMAP-B0M6CHURFI', '连云港市公安局海州分局花果山派出所飞泉警务工作站', 'workstation', '连云港市公安局海州分局花果山派出所', null, '花果山加油站西北侧110米', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0M6CHURFI", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.244636, "latitude": 34.642416, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.239118, 34.643425), 4326)),
  ('AMAP-B0J6AC4JI8', '连云港市公安局警务工作站', 'workstation', '连云港市公安局', null, '郁洲北路与解放东路交叉口东40米', '海州区', 'unknown', false, '{"provider": "amap", "amapId": "B0J6AC4JI8", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.189726, "latitude": 34.612316, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.184136, 34.613292), 4326)),
  ('AMAP-B0FFM7W9CO', '东王集派出所盐河闸东警务站', 'station', '东王集派出所', null, '盐河村闸东交通枢纽中心', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0FFM7W9CO", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.284984, "latitude": 34.226924, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.279486, 34.22817), 4326)),
  ('AMAP-B0GUM97FGF', '和风风电警务站', 'station', null, null, '燕板线西侧', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0GUM97FGF", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.621408, "latitude": 34.466353, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.616244, 34.467667), 4326)),
  ('AMAP-B0JAVSOC5G', '灌云县公安局城东警务工作站', 'workstation', '灌云县公安局', null, '振兴路与建安巷交叉口东北100米', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0JAVSOC5G", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.26687, "latitude": 34.308975, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.261382, 34.310204), 4326)),
  ('AMAP-B0KU4CSXEP', '灌云县公安局城北警务工作站', 'workstation', '灌云县公安局', null, '伊山路与向阳路交叉口西北40米', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0KU4CSXEP", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.254637, "latitude": 34.304876, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.249155, 34.306112), 4326)),
  ('AMAP-B0JAZO73NT', '灌云县公安局城南警务工作站', 'workstation', '灌云县公安局', null, '新民中路与人民中路交叉口西北100米', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0JAZO73NT", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.250107, "latitude": 34.290117, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.244626, 34.29136), 4326)),
  ('AMAP-B0MDYKT3YU', '灌云县公安局城西警务工作站', 'workstation', '灌云县公安局', null, '云山北路与126乡道交叉口北460米', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0MDYKT3YU", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.225175, "latitude": 34.308975, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.219677, 34.310199), 4326)),
  ('AMAP-B0MAM178CU', '灌云县公安局文体广场警务工作站', 'workstation', '灌云县公安局', null, '人民西路与幸福大道交叉口西140米', '灌云县', 'unknown', false, '{"provider": "amap", "amapId": "B0MAM178CU", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.239775, "latitude": 34.288725, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.234291, 34.289967), 4326)),
  ('AMAP-B0J2F5SNCD', '吾悦广场警务工作站', 'workstation', null, null, '金海东路201号', '赣榆区', 'unknown', false, '{"provider": "amap", "amapId": "B0J2F5SNCD", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.15781, "latitude": 34.849642, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.152124, 34.850327), 4326)),
  ('AMAP-B0G1AUXMQH', '欢墩警务站', 'station', null, null, '班庄镇凤凰路原欢墩镇政府驻地', '赣榆区', 'unknown', false, '{"provider": "amap", "amapId": "B0G1AUXMQH", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.837602, "latitude": 34.81984, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.832235, 34.820796), 4326)),
  ('AMAP-B0M2ZH310L', '沙河物流园警务站', 'station', null, null, '233国道与金桥富路交叉口西南40米', '赣榆区', 'unknown', false, '{"provider": "amap", "amapId": "B0M2ZH310L", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 118.938025, "latitude": 34.725675, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(118.932708, 34.726769), 4326)),
  ('AMAP-B0MRM4SI9V', '赣榆区公安局高铁站警务站', 'station', '赣榆区公安局', null, null, '赣榆区', 'unknown', false, '{"provider": "amap", "amapId": "B0MRM4SI9V", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.112086, "latitude": 34.877897, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.106326, 34.878492), 4326)),
  ('AMAP-B0LR3UCF9W', '宿城派出所苹果园警务站', 'station', '宿城派出所', null, '环西路与连子山路交叉口东120米', '连云区', 'unknown', false, '{"provider": "amap", "amapId": "B0LR3UCF9W", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.434612, "latitude": 34.694766, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.428931, 34.695563), 4326)),
  ('AMAP-B020601CAD', '朝阳派出所第三警务工作站', 'workstation', '朝阳派出所', null, '前进路与新县路交叉口东南280米', '连云区', 'unknown', false, '{"provider": "amap", "amapId": "B020601CAD", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.281485, "latitude": 34.678597, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.275945, 34.679555), 4326)),
  ('AMAP-B020601CA8', '朝阳派出所第五警务工作站', 'workstation', '朝阳派出所', null, '港城大道与松花江路交叉口北300米', '连云区', 'unknown', false, '{"provider": "amap", "amapId": "B020601CA8", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.310154, "latitude": 34.696453, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.304564, 34.697351), 4326)),
  ('AMAP-B0H1DCN9KS', '西大堤警务工作站', 'workstation', null, null, '西大堤与海头湾路交叉口北40米', '连云区', 'unknown', false, '{"provider": "amap", "amapId": "B0H1DCN9KS", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.372273, "latitude": 34.76271, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.36656, 34.763436), 4326)),
  ('AMAP-B020601BBY', '青口盐场派出所警务工作站', 'workstation', '青口盐场派出所', null, '青口盐场大新工区附近', '连云区', 'unknown', false, '{"provider": "amap", "amapId": "B020601BBY", "keyword": "警务站", "sources": ["amap"], "sourceCoordinates": {"longitude": 119.178599, "latitude": 34.762963, "coordinateSystem": "GCJ-02"}, "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)"}'::jsonb, ST_SetSRID(ST_MakePoint(119.172969, 34.763778), 4326))
on conflict (source_code) do update set
  name = excluded.name,
  station_type = excluded.station_type,
  managing_unit_name = excluded.managing_unit_name,
  contact_phone = excluded.contact_phone,
  address = excluded.address,
  county_name = excluded.county_name,
  metadata = excluded.metadata,
  geom = excluded.geom,
  is_simulated = false;

commit;
