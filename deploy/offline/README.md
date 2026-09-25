# 花果山 Anolis OS 8.6 x86_64 离线部署包

该制品适用于服务器无法访问互联网、客户端浏览器可访问天地图和 jsDelivr 的场景。

## 制品边界

已包含：

- Anolis OS 8.6 x86_64 的 Nginx 1.22、PostgreSQL 13 客户端及相关 RPM。
- Python 3.12 x86_64 运行时、认证入口服务和侦测连接器 wheelhouse。
- PostgREST 16.3 Linux static x86_64。
- 当前工作树的应用代码、外部大屏 `dist.zip` 解压内容及现有 `exports/`。
- 可选的 `gv_bestdb:6.1.0` Docker image save 归档。
- PostgreSQL 13 自定义格式的 `huaguoshan_projd` 完整数据库归档，以及不含角色密码的全局角色脚本。

未包含：

- 数据库角色密码、JWT secret 和管理员明文密码。
- PostgreSQL 服务端及独立的 PostGIS/3DCityDB RPM 安装器；包内数据库镜像是否采用由部署环境决定。
- 客户端浏览器所需的天地图和 jsDelivr 网络资源。
- 当前工作区中缺失的 W/G 空域 3D Tiles；见 `TILESET-INVENTORY.txt`。

## 安装

将整个目录复制到目标机，例如 `/opt/huaguoshan-offline`：

```bash
cd /opt/huaguoshan-offline
sha256sum -c SHA256SUMS
sudo ./install.sh
```

安装脚本会安装 RPM、应用、PostgREST 和 Python 环境，但不会启动服务。随后编辑：

```text
/etc/huaguoshan/auth.env
/etc/huaguoshan/risk-engine.env
/etc/huaguoshan/radar-cloud.env
/etc/huaguoshan/lizheng-connector.env
/etc/huaguoshan/postgrest.conf
```

必须替换所有 `<...>` 占位符。`auth.env` 和 `postgrest.conf` 使用完全相同且足够强的 JWT secret；`radar-cloud.env` 和 `risk-engine.env` 使用各自的数据库连接密码。先按 `app/docs/部署指南.md` 执行检测态势、防御圈和风险评估迁移，然后：

```bash
systemctl enable --now huaguoshan-risk-engine
systemctl enable --now huaguoshan-radar-cloud
systemctl enable --now huaguoshan-lizheng-connector
systemctl status huaguoshan-radar-cloud --no-pager
systemctl status huaguoshan-lizheng-connector --no-pager
systemctl status huaguoshan-risk-engine --no-pager
nginx -t
systemctl enable --now huaguoshan-auth huaguoshan-postgrest nginx
systemctl status huaguoshan-auth huaguoshan-postgrest nginx --no-pager
curl -fsS http://127.0.0.1:20000/healthz
```

数据库归档恢复见 `database/README.md`；完整初始化、初始管理员创建及验收步骤见 `app/docs/部署指南.md`。

数据库归档含平台登录密码哈希及可能的真实业务/源数据，整个离线包必须按敏感数据制品管理。

## 客户端网络

客户端浏览器需访问：

- `api.tianditu.gov.cn`
- `t0.tianditu.gov.cn` 至 `t7.tianditu.gov.cn`
- `cdn.jsdelivr.net`（仅 API 文档门户）

服务器本身不需要互联网连接。

## iBEST-DB 镜像

如果存在 `database/gv_bestdb_6.1.0.tar.gz`，它是 `gv_bestdb:6.1.0` 的 Docker image save 归档，不是 RPM。安装方式：

```bash
docker load -i database/gv_bestdb_6.1.0.tar.gz
docker image inspect gv_bestdb:6.1.0
```

是否使用该镜像启动数据库、端口/卷/许可如何配置，需遵循 GEOVIS iBEST-DB 产品部署手册；本安装脚本不会自动启动或修改该数据库镜像。
