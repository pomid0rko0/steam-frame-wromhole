param([string]$Out)
# Забирает с Steam Frame логи Wormhole VR одним текстовым файлом wormhole_vr_logs.txt
# в «Загрузки». Его можно просто приложить к чату: в логах замеры частоты (строки «refresh:»),
# по ним агент сам проверит, успевают ли кадры.
#
# Запуск: двойной щелчок по frame_logs.bat. Имя и адрес Фрейма берутся из deploy_frame.ps1.
# Пароль Фрейма спросят один раз.

$ErrorActionPreference = "Stop"

$m = Select-String -Path (Join-Path $PSScriptRoot "deploy_frame.ps1") -Pattern '^\$Frame\s*=\s*"([^"]*)"' |
    Select-Object -First 1
$Frame = if ($m) { $m.Matches[0].Groups[1].Value } else { "" }
if (-not $Frame -or $Frame -like "ИМЯ@*") {
    throw "Открой deploy_frame.ps1 и впиши в `$Frame имя и адрес Фрейма."
}

if (-not $Out) {
    $downloads = (New-Object -ComObject Shell.Application).NameSpace("shell:Downloads").Self.Path
    $Out = Join-Path $downloads "wormhole_vr_logs.txt"
}

# Godot хранит последние запуски: godot.log и переименованные прежние, все подряд, старые первыми
$remote = "cd ~/.local/share/godot/app_userdata/'Wormhole VR'/logs && ls -tr *.log | xargs tail -n +1"
Write-Host "Забираю логи с $Frame ..."
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$text = ssh $Frame $remote
if ($LASTEXITCODE -ne 0) { throw "Не удалось забрать логи (ssh вернул $LASTEXITCODE)" }
$text | Set-Content -Path $Out -Encoding UTF8
Write-Host "Готово: $Out"
Write-Host "Приложи этот файл к чату."
