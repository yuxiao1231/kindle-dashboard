#!/bin/sh

KDB_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$KDB_ROOT"

export KDB_ROOT
export LD_LIBRARY_PATH="$KDB_ROOT/lib:$LD_LIBRARY_PATH"
export LD_PRELOAD="$KDB_ROOT/lib/libstdc++.so.6"

LUA_BIN="$KDB_ROOT/bin/luajit"
FBINK="$KDB_ROOT/bin/fbink"
LOG="$KDB_ROOT/debug.log"

CUSTOM_SPLASH_PNG="$KDB_ROOT/custom_splash.png"
CUSTOM_SPLASH_RAW="$KDB_ROOT/custom_splash.raw"
SPLASH_FILE="$KDB_ROOT/splash.raw"

> "$LOG"
exec >> "$LOG" 2>&1
set -x

echo "--- KDB 启动: $(date) (K4NT Pure Edition) ---"

# ── 依赖预检 ────────────────────────────────────────────────
MISSING=0
for dep in "$LUA_BIN" "$FBINK" "$KDB_ROOT/lib/libstdc++.so.6" "$KDB_ROOT/lib/libkoreader-nnsvg.so" "$KDB_ROOT/lib/liblodepng.so"; do
    [ ! -f "$dep" ] && echo "[ERROR] 缺少依赖: $dep" && MISSING=1
done
[ "$MISSING" -eq 1 ] && $FBINK -q -pm -M -S 2 "KDB: Missing deps." && exit 1

SW=600
SH=800
INPUT_NODE="/dev/input/event0"

/etc/init.d/framework stop
lipc-set-prop com.lab126.powerd preventScreenSaver 1

if [ -f "$CUSTOM_SPLASH_PNG" ]; then
    $FBINK -q -c -g file="$CUSTOM_SPLASH_PNG"
elif [ -f "$CUSTOM_SPLASH_RAW" ]; then
    cat "$CUSTOM_SPLASH_RAW" > /dev/fb0
    $FBINK -q -f -s
elif [ -f "$SPLASH_FILE" ]; then
    cat "$SPLASH_FILE" > /dev/fb0
    $FBINK -q -f -s
else
    $FBINK -q -c
    $FBINK -q -M -m -S 2 'KDB loading...'
fi


while true; do

    $LUA_BIN "$KDB_ROOT/main.lua" "$SW" "$SH" "$INPUT_NODE"
    RET=$?
    echo "[start.sh] main.lua exited: $RET"

    case "$RET" in
        42)
            echo "[start.sh] Evacuation requested."
            if [ -f "$CUSTOM_SPLASH_PNG" ] || [ -f "$CUSTOM_SPLASH_RAW" ]; then
                echo "[start.sh] Static mode active. Skipping dd."
            else
                dd if=/dev/fb0 of="$SPLASH_FILE" bs=4096 2>/dev/null
            fi
            break
            ;;
        0)
            sleep 5
            ;;
        *)
            $FBINK -q -M -m -S 2 "KDB crash ($RET). Restarting..."
            sleep 5
            ;;
    esac
done

lipc-set-prop com.lab126.powerd preventScreenSaver 0
lipc-set-prop com.lab126.wifid enable 0 2>/dev/null || true
/etc/init.d/framework start
echo "[start.sh] Framework restored."