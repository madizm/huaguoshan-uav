#!/bin/bash
# 历正科技 RF 侦测设备连接器启动脚本
# 支持后台运行、PID 管理、日志轮转

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="$PROJECT_DIR/logs/lizheng_connector.pid"
LOG_FILE="$PROJECT_DIR/logs/lizheng_connector.log"

cd "$PROJECT_DIR"

export DETECTION_DATABASE_DSN='postgresql://detection_connector:detection_conn%40geovis%400920@10.1.109.151:5432/huaguoshan_projd'
export DETECTION_DATABASE_ROLE='detection_ingest'
export LOG_LEVEL="${LOG_LEVEL:-INFO}"

# 确保日志目录存在
mkdir -p "$PROJECT_DIR/logs"

show_help() {
    echo "用法: $0 {start|stop|restart|status|logs}"
    echo ""
    echo "命令:"
    echo "  start    启动连接器（后台运行）"
    echo "  stop     停止连接器"
    echo "  restart  重启连接器"
    echo "  status   显示运行状态"
    echo "  logs     查看实时日志"
    echo ""
    echo "环境变量:"
    echo "  LOG_LEVEL  日志级别 (DEBUG|INFO|WARNING|ERROR), 默认: INFO"
    exit 1
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE"
    fi
}

do_start() {
    if is_running; then
        echo "❌ 连接器已在运行 (PID: $(get_pid))"
        exit 1
    fi

    echo "🚀 启动历正 RF 侦测连接器..."
    echo "  Base URL: https://10.10.0.93"
    echo "  Database: 10.1.109.151:5432/huaguoshan_projd"
    echo "  Log level: $LOG_LEVEL"
    echo "  Log file: $LOG_FILE"
    echo ""

    # 后台启动，使用 nohup 确保进程在终端关闭后继续运行
    nohup uv run scripts/lizheng_connector.py \
        --base-url https://10.10.0.93 \
        --username admin \
        --password admin \
        --no-verify-ssl \
        --reconcile-seconds 30 \
        --device-sync-seconds 300 \
        >> "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # 等待一下确认进程启动成功
    sleep 2
    if is_running; then
        echo "✅ 连接器已启动 (PID: $pid)"
        echo "   使用 '$0 logs' 查看日志"
        echo "   使用 '$0 status' 查看状态"
    else
        echo "❌ 启动失败，请检查日志: $LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi
}

do_stop() {
    if ! is_running; then
        echo "⚠️  连接器未运行"
        rm -f "$PID_FILE"
        exit 0
    fi

    local pid=$(get_pid)
    echo "🛑 停止连接器 (PID: $pid)..."

    # 优雅关闭：先发送 SIGTERM
    kill "$pid" 2>/dev/null || true

    # 后台请求可能正在等待设备超时；与 systemd TimeoutStopSec 保持一致。
    for i in {1..40}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "✅ 连接器已停止"
            rm -f "$PID_FILE"
            return 0
        fi
        sleep 1
    done

    # 强制关闭
    echo "⚠️  进程未响应，强制终止..."
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "✅ 连接器已强制停止"
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

do_status() {
    if is_running; then
        local pid=$(get_pid)
        echo "✅ 连接器运行中 (PID: $pid)"
        echo ""
        echo "进程信息:"
        ps -p "$pid" -o pid,etime,pcpu,pmem,command | tail -n 1
        echo ""
        echo "最近日志:"
        tail -n 10 "$LOG_FILE" 2>/dev/null || echo "  (日志文件不存在)"
    else
        echo "❌ 连接器未运行"
        rm -f "$PID_FILE"
    fi
}

do_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "⚠️  日志文件不存在: $LOG_FILE"
        exit 1
    fi

    echo "📋 实时日志 (Ctrl+C 退出):"
    echo ""
    tail -f "$LOG_FILE"
}

# 主命令处理
case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_restart
        ;;
    status)
        do_status
        ;;
    logs)
        do_logs
        ;;
    *)
        show_help
        ;;
esac
