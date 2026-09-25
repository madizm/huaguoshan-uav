# 无人机机型目录功能

## 概述

无人机机型目录是设备字典的一部分，记录无人机型号级的性能参数，用于风险评估的重量分级和性能参考。

## 数据模型

### 表结构

- **`equipment.device_model`**: 通用设备型号字典（已有）
- **`equipment.uav_model_spec`**: 无人机型号专用规格表（新增）

### 字段说明

| 字段 | 类型 | 说明 | 风险评估用途 |
|---|---|---|---|
| `model_code` | text | 型号唯一编码，如 `DJI_MAVIC_3E` | 关联键 |
| `weight_class` | enum | 重量分级 | **核心**：决定地面风险等级 |
| `max_takeoff_weight_kg` | numeric | 最大起飞重量（千克） | **核心**：重量分级依据 |
| `max_speed_kph` | numeric | 最大水平速度（千米/小时） | 碰撞动能评估 |
| `max_endurance_min` | integer | 最大续航时间（分钟） | 持续威胁时间窗口 |
| `max_payload_kg` | numeric | 最大载荷重量（千克） | 任务能力评估 |

### 重量分级标准

- `micro`: 微型（< 250g）
- `light`: 轻型（250g - 4kg）
- `small`: 小型（4kg - 25kg）
- `medium`: 中型（25kg - 150kg）
- `large`: 大型（> 150kg）

## 已入库机型

从开发环境数据库探测到的机型：

| 型号编码 | 名称 | 制造商 | 重量分级 | 最大起飞重量(kg) | 最大速度(km/h) | 续航(min) | 最大载荷(kg) |
|---|---|---|---|---|---|---|---|
| `AUTEL_EVO_MAX_4T` | Autel EVO Max 4T | Autel | light | 1.999 | - | 42 | - |
| `DJI_M30T` | DJI Matrice 30T | DJI | medium | 4.069 | - | 41 | - |
| `DJI_M350_RTK` | DJI Matrice 350 RTK | DJI | medium | 9.2 | - | 55 | 2.7 |
| `DJI_MAVIC_3E` | DJI Mavic 3E | DJI | light | 1.05 | 75.6 | 45 | - |
| `DJI_MAVIC_3T` | DJI Mavic 3T | DJI | light | 1.05 | 75.6 | 45 | - |

## 管理界面

### 访问路径

管理后台 → 设备字典 → **无人机机型** Tab

### 功能

- **新增机型**：点击"新增机型"按钮，填写型号编码、名称、制造商、重量分级、最大起飞重量等参数
- **编辑机型**：在表格中直接编辑机型名称、制造商、性能参数
- **型号编码不可修改**：作为主键，创建后不可更改

### API 接口

- **读取**: `GET /rest/v1/equipment_uav_models`
- **新增**: `POST /rest/v1/rpc/create_equipment_uav_model`
  - 参数: `p_model_code`, `p_name`, `p_manufacturer`, `p_weight_class`, `p_max_takeoff_weight_kg`, `p_max_speed_kph` (可选), `p_max_endurance_min` (可选), `p_max_payload_kg` (可选)
  - 返回: 型号编码 (text)
- **更新**: `POST /rest/v1/rpc/update_equipment_uav_model`
  - 参数: `p_model_code` (text), `p_changes` (jsonb)

## 与资产的关系

无人机资产（`equipment.asset`，`category_code = 'uav'`）通过 `type_code` 字段关联到机型目录：

```
equipment.asset.type_code → equipment.device_model.model_code
                          → equipment.uav_model_spec.model_code
```

已入库的 11 架无人机已全部关联到机型目录。

## 后续扩展

### 风险评估引擎对接

当前风险评估引擎（`risk_engine/domain.py`）尚未使用机型参数。后续可以：

1. 在 `TargetInput` 中新增 `weight_class` 字段
2. 从观测数据中提取机型信息，查询机型目录获取重量分级
3. 新增 `weight_factor` 评分因子，根据重量分级调整风险分数

### 新增机型

添加新机型的步骤：

1. 在管理界面点击"新增机型"按钮
2. 填写型号编码（建议格式：`制造商_型号`，如 `DJI_MINI_4_PRO`）
3. 填写名称、制造商、重量分级、最大起飞重量等参数
4. 点击确定保存

或者通过 SQL 直接插入：

```sql
-- 插入 device_model
INSERT INTO equipment.device_model (model_code, category_code, name, manufacturer)
VALUES ('DJI_MINI_4_PRO', 'uav', 'DJI Mini 4 Pro', 'DJI');

-- 插入 uav_model_spec
INSERT INTO equipment.uav_model_spec (
  model_code, weight_class, max_takeoff_weight_kg,
  max_speed_kph, max_endurance_min, max_payload_kg
) VALUES (
  'DJI_MINI_4_PRO', 'micro', 0.249, 57.6, 34, null
);
```

## 数据来源

- 大疆机型参数：[DJI 官方网站](https://www.dji.com/)
- 道通机型参数：[Autel Robotics 官方网站](https://www.autelrobotics.com/)
- 参数采集时间：2026-02

## Migration 文件

- `backend/create_uav_model_catalog.sql`: 创建表和预置数据
- `backend/create_uav_model_admin_api.sql`: 创建管理 API（包含新增、更新功能）
