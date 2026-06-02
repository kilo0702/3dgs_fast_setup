$ErrorActionPreference = "Stop"

Write-Host "==================================================="
Write-Host "3DGS 環境建置腳本"
Write-Host "==================================================="

# 確保必要套件已安裝
Write-Host "確認環境中是否安裝基本套件..."
uv pip install setuptools ninja wheel plyfile tqdm opencv-python joblib

# 1. 尋找 Visual Studio 
Write-Host "`n 尋找 Visual Studio 安裝路徑..."
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "找不到 vswhere.exe，請確認是否已安裝 Visual Studio。"
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Error "找不到包含 C++ 開發工具的 Visual Studio 安裝。請在 Visual Studio Installer 勾選「使用 C++ 的桌面開發」。"
}

$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Error "找不到 vcvars64.bat: $vcvars"
}
Write-Host "✅ 找到 Visual Studio: $vsPath"

# 2. 自動判斷合適的 MSVC 版本
Write-Host "`n 檢查可用的 MSVC 版本..."
$msvcPath = Join-Path $vsPath "VC\Tools\MSVC"
$versions = Get-ChildItem -Path $msvcPath -Directory | Select-Object -ExpandProperty Name | Sort-Object -Descending

# 優先選擇小於 14.50 的版本 (因為 14.5x 目前會讓 NVCC 發生 0xC0000005 崩潰)
$selectedVersion = $versions | Where-Object { [version]$_ -lt [version]"14.50" } | Select-Object -First 1

if (-not $selectedVersion) {
    $selectedVersion = $versions[0]
    Write-Warning " 找不到 < 14.50 的 MSVC 版本，將使用最新的 $selectedVersion，這可能會在編譯 CUDA 時發生崩潰錯誤。"
    Write-Warning "   建議至 VS Installer 安裝較舊版的 MSVC (例如 v14.44 或 v14.39)。"
} else {
    Write-Host "✅ 自動選擇最穩定的 MSVC 版本: $selectedVersion"
}

# 3. 修補 setup.py 注入 nvcc 參數
Write-Host "`n 正在檢查 setup.py 並注入 -allow-unsupported-compiler 參數..."

function Patch-SetupPy {
    param([string]$path)
    if (-not (Test-Path $path)) {
        Write-Warning "找不到 $path，略過修補。"
        return
    }
    
    $content = Get-Content $path -Raw
    
    if ($content -notmatch "-allow-unsupported-compiler") {
        # 將 "-allow-unsupported-compiler" 插入到 extra_compile_args={"nvcc": [ 後面
        $content = $content -replace '"nvcc":\s*\[', '"nvcc": ["-allow-unsupported-compiler", '
        $content = $content -replace "'nvcc':\s*\[", "'nvcc': ['-allow-unsupported-compiler', "
        [System.IO.File]::WriteAllText((Resolve-Path $path).Path, $content, [System.Text.Encoding]::UTF8)
        Write-Host "  -> ✅ 已修補 $path"
    } else {
        Write-Host "  -> $path 已經包含所需參數"
    }
}

Patch-SetupPy "submodules\diff-gaussian-rasterization\setup.py"
Patch-SetupPy "submodules\simple-knn\setup.py"

# 4. 透過 CMD 環境呼叫 vcvars64.bat 並開始編譯
Write-Host "`n 開始編譯與安裝 CUDA 模組..."
$cmdScript = @"
@echo off
set DISTUTILS_USE_SDK=1
call "$vcvars" -vcvars_ver=$selectedVersion
echo ========================================
echo [1/2] Installing diff-gaussian-rasterization...
echo ========================================
uv pip install submodules\diff-gaussian-rasterization --no-build-isolation
if %errorlevel% neq 0 exit /b %errorlevel%

echo ========================================
echo [2/2] Installing simple-knn...
echo ========================================
uv pip install submodules\simple-knn --no-build-isolation
if %errorlevel% neq 0 exit /b %errorlevel%
"@

$tempBat = Join-Path $env:TEMP "build_cuda_modules.bat"
[System.IO.File]::WriteAllText($tempBat, $cmdScript, [System.Text.Encoding]::ASCII)
& cmd.exe /c $tempBat

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n 所有模組安裝成功！" -ForegroundColor Green
} else {
    Write-Host "`n❌ 安裝過程發生錯誤，請檢查上方紅字錯誤訊息。" -ForegroundColor Red
}

Remove-Item $tempBat -ErrorAction SilentlyContinue
