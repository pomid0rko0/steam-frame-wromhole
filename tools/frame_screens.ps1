param([int]$Days = 7, [string]$Out)
# Забирает со Steam Frame скриншоты за последние дни (по умолчанию за 7) одним архивом
# wormhole_vr_screenshots.zip в «Загрузки»: его можно приложить к чату. Рядом папка
# wormhole_vr_screenshots с теми же картинками: если чат не примет zip, выдели их все и перетащи.
#
# Запуск: двойной щелчок по frame_screens.bat (за 30 дней: frame_screens.bat 30).
# Имя и адрес Фрейма берутся из deploy_frame.ps1. Пароль Фрейма спросят один раз.
# Скриншот — JPEG 1920×1080.

$ErrorActionPreference = "Stop"

$m = Select-String -Path (Join-Path $PSScriptRoot "deploy_frame.ps1") -Pattern '^\$Frame\s*=\s*"([^"]*)"' |
    Select-Object -First 1
$Frame = if ($m) { $m.Matches[0].Groups[1].Value } else { "" }
if (-not $Frame -or $Frame -like "ИМЯ@*") {
    throw "Открой deploy_frame.ps1 и впиши в `$Frame имя и адрес Фрейма."
}

if (-not $Out) {
    $downloads = (New-Object -ComObject Shell.Application).NameSpace("shell:Downloads").Self.Path
    $Out = Join-Path $downloads "wormhole_vr_screenshots.zip"
}
$dir = Join-Path (Split-Path $Out) ([IO.Path]::GetFileNameWithoutExtension($Out))

# Steam кладёт скриншоты в userdata/<id>/760/remote/<игра>/screenshots (уменьшенные копии
# в thumbnails рядом), KDE - в ~/Pictures. Каждый файл идёт строкой «FILE путь» и base64,
# так что ssh хватает одного, без scp. Если там пусто, строки «ELSEWHERE путь» называют
# свежие картинки в других местах домашней папки. Только одинарные кавычки: двойные
# Windows PowerShell передаёт ssh неверно.
$remote = ('cd ~ && set -f && IFS=$''\n'' && n=0 && for f in $(find -H .local/share/Steam/userdata .steam/steam/userdata Pictures ' +
    '-type f -mtime -DAYS -not -path ''*/thumbnails/*'' -regextype posix-extended -iregex ''.*[.](jpe?g|png|webp)'' ' +
    '-exec realpath --relative-to=. {} + 2>/dev/null | sort -u); do n=1; echo FILE $f; base64 $f; done; ' +
    '[ $n = 1 ] || find . -xdev -type f -mtime -DAYS -size +100k -regextype posix-extended -iregex ''.*[.](jpe?g|png|webp)'' ' +
    '-not -path ''./.cache/*'' -not -path ''*/appcache/*'' -not -path ''*/htmlcache/*'' -printf ''ELSEWHERE %p\n'' 2>/dev/null | head -20'
    ).Replace('DAYS', [string]$Days)

Write-Host "Забираю с $Frame скриншоты за $Days дн. ..."
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lines = ssh $Frame $remote
if ($LASTEXITCODE -ne 0) { throw "Не удалось забрать скриншоты (ssh вернул $LASTEXITCODE)" }

if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
New-Item -ItemType Directory -Path $dir | Out-Null

$paths = New-Object System.Collections.Generic.List[string]
$data = $null
function Save-Shot {
    if ($paths.Count -eq 0) { return }
    $path = $paths[$paths.Count - 1]
    # <игра>_<файл> для скриншотов Steam, путь от домашней папки через «_» для прочих
    $name = $path -replace '^.*/760/remote/', '' -replace '/screenshots/', '_' -replace '/', '_'
    [IO.File]::WriteAllBytes((Join-Path $dir $name), [Convert]::FromBase64String($data.ToString()))
}
foreach ($s in $lines) {
    if ($s.StartsWith("FILE ")) {
        Save-Shot
        $paths.Add($s.Substring(5))
        $data = New-Object System.Text.StringBuilder
    } elseif ($data) {
        [void]$data.Append($s)
    }
}
Save-Shot

if ($paths.Count -eq 0) {
    Remove-Item -Recurse -Force $dir
    $other = @($lines | Where-Object { $_.StartsWith("ELSEWHERE ") } | ForEach-Object { "  ~" + $_.Substring(11) })
    if ($other.Count -gt 0) {
        Write-Host "В папке скриншотов Steam и в ~/Pictures за $Days дн. пусто. Свежие картинки нашлись тут"
        Write-Host "(пришли этот список в чат, агент поправит скрипт):"
        $other | ForEach-Object { Write-Host $_ }
    }
    throw "На Фрейме нет скриншотов за $Days дн. Если они старше: frame_screens.bat 30"
}
# где они лежали на Фрейме: по этому списку агент поймёт, откуда их брать
$paths | Set-Content -Path (Join-Path $dir "where.txt") -Encoding UTF8
Compress-Archive -Path (Join-Path $dir "*") -DestinationPath $Out -Force
$mb = [math]::Round((Get-Item $Out).Length / 1MB, 1)
Write-Host "Готово: $Out ($($paths.Count) шт., $mb МБ)"
Write-Host "Приложи этот файл к чату (или картинки из папки $dir)."
