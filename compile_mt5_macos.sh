#!/bin/bash
#
# Compile a single MQL5 file via MetaEditor (Wine).
#
# Notes:
# - Uses a unique per-run log file so concurrent/aborted runs never collide
#   (this is what caused "Log file not generated" before).
# - Runs MetaEditor and waits for it with a watchdog. Only if it exceeds
#   COMPILE_TIMEOUT seconds does it kill metaeditor64.exe. It NEVER kills
#   wineserver, so a running MetaTrader 5 terminal is left untouched.
#
# Usage:
#   bash compile_mql5_macos.sh path/to/File.mq5
#   COMPILE_TIMEOUT=180 bash compile_mql5_macos.sh src/EA31337.mq5
#

# Khai báo đường dẫn Wine & MetaEditor
WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE_EXEC="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64"
METAEDITOR="C:\Program Files\MetaTrader 5\metaeditor64.exe"

MQ5_FILE="$1"
if [ -z "$MQ5_FILE" ]; then
    echo "Usage: ./compile_mql5_macos.sh yourfile.mq5"
    exit 1
fi

# Watchdog timeout (seconds). Override with: COMPILE_TIMEOUT=180 bash ...
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-120}"

MQ5_WIN_PATH=$("$WINE_EXEC" winepath -w "$(pwd)/$MQ5_FILE")

# Unique log name per run to avoid collisions between parallel/incomplete runs.
LOG_BASE="ea31337_compile_$$_${RANDOM}"
LOG_WIN_PATH="C:\\users\\Public\\${LOG_BASE}.log"
LOG_MAC_PATH="$WINEPREFIX/drive_c/users/Public/${LOG_BASE}.log"

echo "Compiling: $MQ5_FILE..."

# Xóa log cũ nếu tồn tại
rm -f "$LOG_MAC_PATH"

# Chạy MetaEditor (nền), rồi chờ có giới hạn thời gian.
WINEPREFIX="$WINEPREFIX" "$WINE_EXEC" "$METAEDITOR" /compile:"$MQ5_WIN_PATH" /log:"$LOG_WIN_PATH" > /dev/null 2>&1 &
COMPILE_PID=$!

START_TS=$(date +%s)
while kill -0 "$COMPILE_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - START_TS )) -ge "$COMPILE_TIMEOUT" ]; then
        echo "Compile TIMEOUT after ${COMPILE_TIMEOUT}s; killing metaeditor64.exe (leaving wineserver/MT5 alone)..." >&2
        # Chỉ kill MetaEditor, KHÔNG kill wineserver (wineserver đang giữ MT5 terminal).
        pkill -f "metaeditor64.exe" 2>/dev/null
        kill "$COMPILE_PID" 2>/dev/null
        break
    fi
    sleep 1
done
wait "$COMPILE_PID" 2>/dev/null

if [ ! -f "$LOG_MAC_PATH" ]; then
    echo "Compile FAILED: Log file not generated."
    exit 1
fi

# Chuyển đổi mã hóa log từ UTF-16LE sang UTF-8
LOG_CONTENT=$(iconv -f UTF-16LE -t UTF-8 "$LOG_MAC_PATH" 2>/dev/null || cat "$LOG_MAC_PATH" | tr -d '\0')

# Kiểm tra kết quả
if echo "$LOG_CONTENT" | grep -q "Result: 0 errors"; then
    echo "$LOG_CONTENT" | grep "Result:"
    echo "Compile SUCCESS"
    rm -f "$LOG_MAC_PATH"
    exit 0
else
    echo "$LOG_CONTENT"
    echo "Compile FAILED"
    rm -f "$LOG_MAC_PATH"
    exit 1
fi
