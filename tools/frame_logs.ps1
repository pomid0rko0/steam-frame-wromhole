param([string]$Out)
# Забирает с Steam Frame логи Wormhole VR в папку wormhole_vr_logs в «Загрузках»: каждый запуск
# приложения отдельным файлом <дата>_<время>_<сборка>.txt (время - когда запуск кончился или, у
# идущего сейчас, последняя запись). Godot хранит на Фрейме пять последних запусков; файлы прежних
# забираний в папке остаются. К чату прикладывай файлы нужных запусков, обычно самый свежий: в них
# замеры частоты (строки «refresh:»), по ним агент сам проверит, успевают ли кадры.
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
    $Out = Join-Path $downloads "wormhole_vr_logs"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Каждый лог идёт строкой «==> LOG время файл» и своим текстом, старые первыми. Только одинарные
# кавычки: двойные Windows PowerShell передаёт ssh неверно.
$remote = 'cd ~/.local/share/godot/app_userdata/''Wormhole VR''/logs && for f in $(ls -tr *.log); do echo ''==> LOG'' $(date -r $f +%Y-%m-%d_%H-%M-%S) $f; cat $f; done'
Write-Host "Забираю логи с $Frame ..."
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lines = ssh $Frame $remote
if ($LASTEXITCODE -ne 0) { throw "Не удалось забрать логи (ssh вернул $LASTEXITCODE)" }

$runs = New-Object System.Collections.Generic.List[object]
foreach ($s in $lines) {
    if ($s -match '^==> LOG (\S+) (\S+)$') {
        $runs.Add([pscustomobject]@{ Time = $Matches[1]; Build = "source"; Text = New-Object System.Collections.Generic.List[string] })
    } elseif ($runs.Count -gt 0) {
        $run = $runs[$runs.Count - 1]
        if ($run.Build -eq "source" -and $s -match '^build: (\S+)') { $run.Build = $Matches[1] }
        $run.Text.Add($s)
    }
}
if ($runs.Count -eq 0) { throw "На Фрейме нет логов Wormhole VR" }

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($run in $runs) {
    $name = "$($run.Time)_$($run.Build).txt"
    $path = Join-Path $Out $name
    [IO.File]::WriteAllLines($path, $run.Text, $utf8)
    $mb = [math]::Round((Get-Item $path).Length / 1MB, 1)
    Write-Host "  $name  $mb МБ"
}
Write-Host "Готово: $Out, запусков $($runs.Count), самый свежий - последний."
Write-Host "Приложи к чату файлы нужных запусков."
