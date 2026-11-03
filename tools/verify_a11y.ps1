# 触控里程 · 无障碍能力自证（Windows 一键版）
# 用法：右键「使用 PowerShell 运行」，或
#       powershell -ExecutionPolicy Bypass -File verify_a11y.ps1 .\app-release.apk
#
# 它做的事：从 APK 的二进制清单里读出无障碍服务真正申请了哪些能力。
# 不需要 Android SDK，不需要安装任何东西（有 Node.js 就行）。

param(
    [Parameter(Position = 0)]
    [string]$Apk = ".\app-release.apk"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Node {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $x86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $cands = @(
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path $x86 "nodejs\node.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\nodejs\node.exe")
    )
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-Aapt2 {
    $cmd = Get-Command aapt2 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
                  (Join-Path $env:LOCALAPPDATA "Android\Sdk")) |
                Where-Object { $_ -and (Test-Path $_) }
    foreach ($root in $sdkRoots) {
        $bt = Join-Path $root "build-tools"
        if (-not (Test-Path $bt)) { continue }
        $hit = Get-ChildItem $bt -Directory |
               Sort-Object Name -Descending |
               ForEach-Object { Join-Path $_.FullName "aapt2.exe" } |
               Where-Object { Test-Path $_ } |
               Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $Apk)) {
    Write-Host "找不到 APK：$Apk" -ForegroundColor Red
    Write-Host "用法：verify_a11y.ps1 <app-release.apk 的路径>" -ForegroundColor Yellow
    exit 2
}

$node = Find-Node
$script = Join-Path $here "verify_a11y.mjs"

if ($node -and (Test-Path -LiteralPath $script)) {
    & $node $script (Resolve-Path -LiteralPath $Apk).Path
    exit $LASTEXITCODE
}

# 没有 Node：退回到 Android SDK 的 aapt2（装了 Android Studio 就有）
$aapt2 = Find-Aapt2
if ($aapt2) {
    Write-Host "未找到 Node.js，改用 aapt2 读取（结果等价）：" -ForegroundColor Yellow
    & $aapt2 dump xmltree $Apk --file AndroidManifest.xml 2>$null |
        Select-String -Pattern "accessibility|permission" |
        ForEach-Object { $_.Line }
    Write-Host ""
    Write-Host "无障碍配置详情请执行：" -ForegroundColor Cyan
    Write-Host ('  aapt2 dump xmltree "' + $Apk + '" --file <上面对应的 res/*.xml>')
    exit 0
}

Write-Host "需要 Node.js（https://nodejs.org）或 Android SDK 的 aapt2 才能读取 APK。" -ForegroundColor Red
Write-Host "这个工具本身不联网、不上传任何东西，只读你指定的文件。" -ForegroundColor Gray
exit 3
