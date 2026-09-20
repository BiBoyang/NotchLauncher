#!/bin/bash
# NotchLauncher 几何回归冒烟测试
#
# 一条命令完成:构建 debug 版 → 1-app 夹具断言面板 325×152 → 7-app 夹具断言 590×254
# → 恢复 apps.json → 重启日常安装态实例。全 PASS exit 0,任一 FAIL exit 1。
#
# 注意:运行期间鼠标会被 warp 移动几秒,请勿触碰鼠标;面板开合断言读系统窗口服务器的
# 真实 bounds(CGWindowList),不需要辅助功能/屏幕录制权限。
#
# 几何基线(规格常量,独立于实现):
#   cell 84×92、行距 10、padding 水平 36 / 顶 notchHeight+12 / 底 16、刘海 185×32
#   1 app:325×152;7 app(6 列折 2 行):590×254;窗口 layer = statusBar(25)+8 = 33

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEBUG_BIN="$ROOT/.build/debug/NotchLauncher"
APPS_DIR="$HOME/Library/Application Support/NotchLauncher"
APPS_JSON="$APPS_DIR/apps.json"
DAILY_APP="$HOME/Applications/NotchLauncher.app"

# 夹具:几何只取决于条目数量(运行态排序不改变尺寸)
FIXTURE_1='{"apps":[{"name":"Safari","bundleID":"com.apple.Safari"}]}'
FIXTURE_7='{"apps":[
{"name":"Safari","bundleID":"com.apple.Safari"},
{"name":"备忘录","bundleID":"com.apple.Notes"},
{"name":"日历","bundleID":"com.apple.iCal"},
{"name":"音乐","bundleID":"com.apple.Music"},
{"name":"照片","bundleID":"com.apple.Photos"},
{"name":"信息","bundleID":"com.apple.MobileSMS"},
{"name":"FaceTime","bundleID":"com.apple.FaceTime"}
]}'

FAIL=0
note() { echo "[smoke] $*"; }

BACKUP=""
HAD_CONFIG=0
DEBUG_PID=""

cleanup() {
    # 恢复配置
    if [ "$HAD_CONFIG" = 1 ] && [ -n "$BACKUP" ]; then
        if cp "$BACKUP" "$APPS_JSON"; then
            note "apps.json 已恢复"
        else
            note "警告:apps.json 恢复失败,备份在 $BACKUP"
        fi
    fi
    [ -n "$BACKUP" ] && rm -f "$BACKUP"
    # 停 debug 实例
    if [ -n "$DEBUG_PID" ] && kill -0 "$DEBUG_PID" 2>/dev/null; then
        pkill -f "$DEBUG_BIN" 2>/dev/null
        note "debug 实例已停止"
    fi
    # 恢复日常安装态实例
    if [ -d "$DAILY_APP" ]; then
        if open "$DAILY_APP"; then
            note "日常实例已拉起($DAILY_APP)"
        else
            note "警告:未能拉起日常实例 $DAILY_APP"
        fi
    else
        note "警告:未找到 $DAILY_APP,跳过恢复日常实例"
    fi
}
trap cleanup EXIT

# ---------- 1. 构建 ----------
note "swift build…"
if ! BUILD_LOG=$(swift build --package-path "$ROOT" 2>&1); then
    echo "$BUILD_LOG"
    note "FAIL:构建失败"
    exit 1
fi
[ -x "$DEBUG_BIN" ] || { note "FAIL:未找到 $DEBUG_BIN"; exit 1; }

# ---------- 2. 备份并替换配置为 1-app 夹具 ----------
mkdir -p "$APPS_DIR"
if [ -f "$APPS_JSON" ]; then
    BACKUP=$(mktemp -t notchlauncher-smoke)
    cp "$APPS_JSON" "$BACKUP"
    HAD_CONFIG=1
fi
printf '%s' "$FIXTURE_1" > "$APPS_JSON"
note "apps.json 已替换为 1-app 夹具(原配置已备份)"

# ---------- 3. 切换到 debug 实例 ----------
pkill -f 'NotchLauncher.app/Contents/MacOS/NotchLauncher' 2>/dev/null && note "日常实例已停止" || true
pkill -f "$DEBUG_BIN" 2>/dev/null && note "残留 debug 实例已停止" || true
sleep 0.5

DEBUG_LOG=$(mktemp -t notchlauncher-debug)
"$DEBUG_BIN" > "$DEBUG_LOG" 2>&1 &
DEBUG_PID=$!
disown "$DEBUG_PID"

# 等待就绪日志(最多 10s)
READY=0
for _ in $(seq 1 50); do
    if grep -q "就绪" "$DEBUG_LOG" 2>/dev/null; then READY=1; break; fi
    kill -0 "$DEBUG_PID" 2>/dev/null || break
    sleep 0.2
done
if [ "$READY" != 1 ]; then
    note "FAIL:debug 实例未就绪,日志尾部:"
    tail -5 "$DEBUG_LOG" 2>/dev/null
    rm -f "$DEBUG_LOG"
    exit 1
fi
rm -f "$DEBUG_LOG"
note "debug 实例已启动(pid=$DEBUG_PID)"

# ---------- 4. 场景一:1 app → 325×152 ----------
note "场景 1/2:1 app,断言面板 325×152(鼠标将被 warp,勿动)…"
if swift "$ROOT/scripts/smoke-probe.swift" "$DEBUG_PID" "1-app" 325 152; then
    note "场景 1 PASS"
else
    note "场景 1 FAIL"
    FAIL=1
fi

# ---------- 5. 场景二:7 app → 590×254 ----------
printf '%s' "$FIXTURE_7" > "$APPS_JSON"
note "apps.json 已替换为 7-app 夹具"
note "场景 2/2:7 app,断言面板 590×254(鼠标将被 warp,勿动)…"
if swift "$ROOT/scripts/smoke-probe.swift" "$DEBUG_PID" "7-app" 590 254; then
    note "场景 2 PASS"
else
    note "场景 2 FAIL"
    FAIL=1
fi

# ---------- 6. 汇总 ----------
echo
if [ "$FAIL" = 0 ]; then
    echo "===== 冒烟结果:ALL PASS ====="
    exit 0
else
    echo "===== 冒烟结果:FAIL ====="
    exit 1
fi
