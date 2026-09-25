# 历正 RF 侦测连接器使用指南

## 概述

历正 RF 侦测连接器（`lizheng_connector.py`）用于接入历正科技的 RF 侦测设备数据，将无人机目标信息实时同步到平台的态势系统中。

## 启动脚本

启动脚本位于 `scripts/start_lizheng_connector.sh`，支持以下命令：

### 基本命令

```bash
# 启动连接器（后台运行）
./scripts/start_lizheng_connector.sh start

# 停止连接器
./scripts/start_lizheng_connector.sh stop

# 重启连接器
./scripts/start_lizheng_connector.sh restart

# 查看运行状态
./scripts/start_lizheng_connector.sh status

# 查看实时日志
./scripts/start_lizheng_connector.sh logs
```

### 命令说明

- **start**: 启动连接器进程，使用 nohup 确保在终端关闭后继续运行
- **stop**: 优雅停止连接器，先发送 SIGTERM 信号，等待 10 秒后强制终止
- **restart**: 先停止再启动连接器
- **status**: 显示连接器运行状态、进程信息和最近日志
- **logs**: 实时查看连接器日志（Ctrl+C 退出）

### 环境变量

可以通过环境变量配置日志级别：

```bash
# 设置日志级别为 DEBUG
LOG_LEVEL=DEBUG ./scripts/start_lizheng_connector.sh start
```

支持的日志级别：`DEBUG`、`INFO`、`WARNING`、`ERROR`（默认：`INFO`）

## 文件位置

- **启动脚本**: `scripts/start_lizheng_connector.sh`
- **连接器代码**: `scripts/lizheng_connector.py`
- **PID 文件**: `logs/lizheng_connector.pid`
- **日志文件**: `logs/lizheng_connector.log`

## 连接配置

连接器使用以下配置连接到历正设备：

- **设备地址**: `https://10.10.0.93`
- **数据库**: `10.1.109.151:5432/huaguoshan_projd`
- **对账间隔**: 30 秒
- **设备同步间隔**: 300 秒（5 分钟）
- **SSL 验证**: 禁用（设备使用自签名证书）

## 数据接入

连接器接入以下数据：

### 1. 无人机目标数据

- **实时推送**: 通过 WebSocket subscription 接收无人机状态变更
- **对账机制**: 每 30 秒轮询一次，检测消失的无人机
- **数据字段**: 位置、高度、速度、方向、频率、飞手位置等

### 2. 设备状态数据

- **传感器状态**: 每 5 分钟同步一次传感器在线状态和温度
- **设备遥测**: 写入 `counter_uas_telemetry_current` 表
- **资产状态**: 更新设备资产的位置和连接状态

### 3. 连接器状态

- **连接状态**: 通过 `observation_source_status_current` 表跟踪
- **错误记录**: 记录连接错误和断开事件
- **增量事件**: 生成 `change_event` 供态势客户端消费

## 监控和故障排查

### 查看运行状态

```bash
./scripts/start_lizheng_connector.sh status
```

输出示例：
```
✅ 连接器运行中 (PID: 17400)

进程信息:
17400   00:13   0.0  0.1 uv run scripts/lizheng_connector.py ...

最近日志:
2026-09-25 19:27:39,266 INFO sensor telemetry written sensors=3 operational=3 temp=None
2026-09-25 19:27:39,266 INFO device sync complete count=1
2026-09-25 19:27:39,729 INFO graphql-ws connection acknowledged
```

### 查看实时日志

```bash
./scripts/start_lizheng_connector.sh logs
```

### 数据库验证

```sql
-- 查看观测来源状态
select 
  os.id, os.source_system, os.name,
  osc.connector_state, osc.last_message_at
from situation.observation_source os
left join situation.observation_source_status_current osc 
  on osc.observation_source_id = os.id
where os.source_system = 'lizheng';

-- 查看设备遥测数据
select 
  asset_id, asset_code, asset_name,
  observed_at, detection_device_online,
  counter_temperature_c, telemetry_stale
from api.counter_uas_telemetry_current
where asset_id = 96;  -- 历正设备 asset_id
```

### 常见问题

#### 1. 连接器启动失败

**症状**: 启动后立即显示"连接器未运行"

**排查步骤**:
1. 检查日志文件：`tail -100 logs/lizheng_connector.log`
2. 检查 VPN 连接：`ping 10.10.0.93`
3. 检查数据库连接：`psql -h 10.1.109.151 -U postgres -d huaguoshan_projd`

**常见原因**:
- VPN 未连接
- 数据库连接失败
- 设备地址不可达

#### 2. SSL 连接错误

**症状**: 日志显示 `SSL: UNEXPECTED_EOF_WHILE_READING`

**解决方案**:
- 这是间歇性问题，连接器会自动重试
- 如果持续出现，检查设备是否正常运行
- 确认 `--no-verify-ssl` 参数已启用

#### 3. 设备遥测数据过期

**症状**: 管理界面显示"数据过期"

**排查步骤**:
1. 检查连接器是否运行：`./scripts/start_lizheng_connector.sh status`
2. 查看最近日志：`./scripts/start_lizheng_connector.sh logs`
3. 验证设备同步是否成功：搜索日志中的 "sensor telemetry written"

**解决方案**:
- 重启连接器：`./scripts/start_lizheng_connector.sh restart`
- 检查设备网络连通性

#### 4. WebSocket 频繁重连

**症状**: 日志显示 "websocket receive timeout, reconnecting"

**说明**:
- 这是正常行为，设备在 30 秒无消息后会超时重连
- 重连后会自动恢复订阅

## 管理界面

连接器启动后，可在管理界面查看：

- **侦测来源**: `/admin/detection-sources`
  - 来源名称：历正科技 RF 侦测设备
  - 接入链路状态：已连接（绿色）
  - 最近合法消息：实时更新

- **设备资产**: `/admin/assets`
  - 资产编码：LIZHENG-001
  - 运行状态：在线（绿色）或数据过期（黄色）
  - 设备坐标：POINT(119.19292 34.592045)

## 自动启动

如需在系统启动时自动运行连接器，可添加到 crontab：

```bash
# 编辑 crontab
crontab -e

# 添加以下行（每分钟检查一次，如果未运行则启动）
* * * * * /Users/madizm/geovis/huaguoshan/scripts/start_lizheng_connector.sh start >/dev/null 2>&1 || true
```

或使用 systemd/launchd 创建服务（推荐用于生产环境）。

## 性能指标

- **内存占用**: ~47MB
- **CPU 使用**: < 1%
- **网络流量**: 
  - WebSocket: ~1KB/消息
  - HTTP 轮询: ~2KB/请求
- **数据库写入**:
  - 目标观测: 实时（每条无人机消息）
  - 设备遥测: 每 5 分钟
  - 连接器状态: 连接/断开时

## 安全注意事项

- **凭据管理**: 启动脚本中包含设备登录凭据，请确保文件权限为 600
- **日志敏感信息**: 日志中可能包含 token，请定期清理日志文件
- **网络隔离**: 设备位于 VPN 内网，确保 VPN 连接稳定

## 更新和部署

### 更新连接器代码

```bash
# 1. 停止连接器
./scripts/start_lizheng_connector.sh stop

# 2. 更新代码
git pull

# 3. 重启连接器
./scripts/start_lizheng_connector.sh start
```

### 部署到生产环境

1. 确保 VPN 连接稳定
2. 复制启动脚本和连接器代码
3. 修改脚本中的数据库连接信息（如需要）
4. 设置文件权限：`chmod 600 scripts/start_lizheng_connector.sh`
5. 启动连接器：`./scripts/start_lizheng_connector.sh start`
6. 验证运行状态：`./scripts/start_lizheng_connector.sh status`

## 技术支持

如遇问题，请提供以下信息：

1. 连接器版本：`head -1 scripts/lizheng_connector.py`
2. 运行状态：`./scripts/start_lizheng_connector.sh status`
3. 最近日志：`tail -100 logs/lizheng_connector.log`
4. 数据库状态：执行上述数据库验证 SQL
