#!/bin/bash
# На самом Steam Frame, в режиме рабочего стола (Konsole), без компьютера:
#   bash frame_desktop.sh [zip]    ставит сборку Wormhole VR:
#     1. берёт zip: указанный или самый свежий wormhole_vr_*_steam_frame.zip из «Загрузок»;
#     2. кладёт сборку в ~/wormhole-vr/wormhole_vr.arm64 (тот же файл, что у deploy_frame.ps1
#        и export.sh, поэтому в библиотеке Steam одна запись) и делает исполняемой;
#     3. добавляет в библиотеку Steam (только в первый раз).
#   bash frame_desktop.sh logs      логи последних запусков одним файлом wormhole_vr_logs.txt
#                                   в «Загрузки», чтобы приложить к чату.
set -euo pipefail

DEST=$HOME/wormhole-vr
NAME=wormhole_vr.arm64
DL=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
[ -d "$DL" ] || DL=$HOME/Downloads

if [ "${1:-}" = logs ]; then
	LOGS=$HOME/.local/share/godot/app_userdata/"Wormhole VR"/logs
	[ -d "$LOGS" ] || { echo "Нет логов: $LOGS (приложение ещё не запускалось?)"; exit 1; }
	OUT=$DL/wormhole_vr_logs.txt
	# Godot хранит последние запуски: godot.log и переименованные прежние, все подряд, старые первыми
	(cd "$LOGS" && ls -tr ./*.log | xargs tail -n +1) > "$OUT"
	echo "Готово: $OUT"
	echo "Приложи этот файл к чату."
	exit 0
fi

ZIP=${1:-}
if [ -z "$ZIP" ]; then
	ZIP=$(ls -t "$DL"/wormhole_vr_*_steam_frame*.zip 2>/dev/null | head -n 1 || true)
	[ -n "$ZIP" ] || { echo "В $DL нет wormhole_vr_*_steam_frame.zip"; exit 1; }
fi
echo "Сборка: $ZIP"

mkdir -p "$DEST"
# распаковать один файл .arm64 сразу под временным именем рядом с прежним
python3 - "$ZIP" "$DEST/$NAME.new" <<'EOF'
import sys, zipfile, shutil
z = zipfile.ZipFile(sys.argv[1])
names = [n for n in z.namelist() if n.endswith('.arm64')]
if not names:
    sys.exit('В архиве нет файла .arm64')
with z.open(names[0]) as src, open(sys.argv[2], 'wb') as dst:
    shutil.copyfileobj(src, dst)
EOF
chmod +x "$DEST/$NAME.new"
# mv заменяет файл, даже если прежняя сборка сейчас запущена
mv -f "$DEST/$NAME.new" "$DEST/$NAME"
echo "Готово: $DEST/$NAME"

if grep -aqs "$DEST/$NAME" "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf \
		"$HOME"/.steam/steam/userdata/*/config/shortcuts.vdf; then
	echo "Уже в библиотеке Steam: запускай оттуда."
else
	steamos-add-to-steam "$DEST/$NAME"
	echo "Добавлено в библиотеку Steam."
fi
