param([string]$Zip)
# Ставит сборку Wormhole VR на Steam Frame:
#   1. распаковывает zip со сборкой;
#   2. копирует её на Фрейм;
#   3. делает исполняемой;
#   4. добавляет в библиотеку Steam (только в первый раз).
# Каждая новая сборка ложится в тот же файл, поэтому в библиотеке одна запись, wormhole_vr.arm64.
#
# Запуск: перетащи zip на deploy_frame.bat. Без zip берётся самый свежий
# wormhole_vr_*_steam_frame.zip из «Загрузок».
# Пароль Фрейма спросят дважды: при копировании и при установке.

# ---- впиши свои данные ----
$Frame = "ИМЯ@АДРЕС"            # как для ssh, например steamos@192.168.0.42
# ----------------------------

$Dir  = "wormhole-vr"            # папка в домашнем каталоге на Фрейме
$Name = "wormhole_vr.arm64"

$ErrorActionPreference = "Stop"

if ($Frame -like "ИМЯ@*") {
    throw "Открой deploy_frame.ps1 и впиши в `$Frame имя и адрес Фрейма."
}

if (-not $Zip) {
    $downloads = (New-Object -ComObject Shell.Application).NameSpace("shell:Downloads").Self.Path
    $found = Get-ChildItem -Path $downloads -Filter "wormhole_vr_*_steam_frame.zip" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { throw "В $downloads нет wormhole_vr_*_steam_frame.zip" }
    $Zip = $found.FullName
}
Write-Host "Сборка: $Zip"

# 1. распаковать
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wormhole_" + [guid]::NewGuid())
Expand-Archive -Path $Zip -DestinationPath $tmp
$bin = Get-ChildItem -Path $tmp -Recurse -Filter "*.arm64" | Select-Object -First 1
if (-not $bin) { throw "В архиве нет файла .arm64" }

try {
    # 2. скопировать (в домашнюю папку, под временным именем)
    Write-Host "Копирую на $Frame ..."
    scp $bin.FullName "${Frame}:$Name.new"
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скопировать (scp вернул $LASTEXITCODE)" }

    # 3-4. сделать исполняемым, поставить на место, добавить в библиотеку, если ещё нет.
    # mv заменяет файл, даже если прежняя сборка сейчас запущена.
    $remote = "chmod +x ~/$Name.new && mkdir -p ~/$Dir && mv -f ~/$Name.new ~/$Dir/$Name && " +
        "if grep -qs '$Dir/$Name' ~/.steam/steam/userdata/*/config/shortcuts.vdf ~/.local/share/Steam/userdata/*/config/shortcuts.vdf; " +
        "then echo 'already in the Steam library'; " +
        "else steamos-add-to-steam ~/$Dir/$Name; fi"
    Write-Host "Устанавливаю ..."
    ssh $Frame $remote
    if ($LASTEXITCODE -ne 0) { throw "Установка не удалась (ssh вернул $LASTEXITCODE)" }
    Write-Host "Готово: ~/$Dir/$Name на Фрейме."
}
finally {
    Remove-Item -Recurse -Force $tmp
}
