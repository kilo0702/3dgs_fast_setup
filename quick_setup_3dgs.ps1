$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

Write-Host "==================================================="
Write-Host "3DGS 環境建置腳本"
Write-Host "==================================================="

# 1. 確保基本依賴套件已安裝
Write-Host "`n[步驟 1/5] 確認環境基本套件..."
uv pip install setuptools ninja wheel plyfile tqdm opencv-python joblib

# 2. 檢查並拉取 Git Submodules（防止因缺少子模組導致 setup.py 不存在）
Write-Host "`n[步驟 2/5] 檢查 Git Submodules 狀態..."
$missingSubmodules = (-not (Test-Path "submodules\diff-gaussian-rasterization\setup.py")) -or `
                     (-not (Test-Path "submodules\simple-knn\setup.py"))

if ($missingSubmodules) {
    Write-Host "⚠️  偵測到子模組未拉取或不完整，正在自動初始化與拉取 (git submodule update --init --recursive)..."
    git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) {
        Write-Error "無法順利拉取 Git Submodules，請檢查網路連線或 Git 權限。"
    }
    Write-Host "✅ Submodules 拉取完成！"
} else {
    Write-Host "✅ Submodules 已完整就緒。"
}

# 3. 檢查 PyTorch 與 CUDA 支援（編譯 C++/CUDA 擴展模組必備）
Write-Host "`n[步驟 3/5] 檢查 PyTorch CUDA 支援..."
$hasTorchCuda = $false
try {
    $cudaCheck = uv run python -c "import torch; print(torch.cuda.is_available())" 2>$null
    if ($cudaCheck -match "True") {
        $hasTorchCuda = $true
        $gpuName = uv run python -c "import torch; print(torch.cuda.get_device_name(0))" 2>$null
        Write-Host "✅ 偵測到支援 CUDA 的 PyTorch (GPU: $gpuName)"
    }
} catch {}

if (-not $hasTorchCuda) {
    Write-Host "⚠️  未偵測到 CUDA 版 PyTorch，正在自動下載安裝 (CUDA 13.0)..."
    uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PyTorch 安裝失敗，請檢查網路連線或 PyTorch 來源。"
    }
    Write-Host "✅ PyTorch (CUDA 13.0) 安裝完成！"
}

# 4. 尋找 Visual Studio 與合適的 MSVC 編譯器
Write-Host "`n[步驟 4/5] 檢查 Visual Studio 與 MSVC 編譯器..."
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

$msvcPath = Join-Path $vsPath "VC\Tools\MSVC"
$versions = Get-ChildItem -Path $msvcPath -Directory | Select-Object -ExpandProperty Name | Sort-Object -Descending

# 優先選擇小於 14.50 的版本 (避免 NVCC 在過新 MSVC 上發生 0xC0000005 崩潰)
$selectedVersion = $versions | Where-Object { [version]$_ -lt [version]"14.50" } | Select-Object -First 1

if (-not $selectedVersion) {
    $selectedVersion = $versions[0]
    Write-Warning "⚠️  找不到 < 14.50 的 MSVC 版本，將使用最新的 $selectedVersion，這可能會在編譯 CUDA 時發生崩潰錯誤。"
    Write-Warning "   建議至 VS Installer 安裝較舊版的 MSVC (例如 v14.44 或 v14.39)。"
} else {
    Write-Host "✅ 自動選擇最穩定的 MSVC 版本: $selectedVersion"
}

# 5. 修補 setup.py 並編譯安裝 CUDA 擴展模組
Write-Host "`n[步驟 5/5] 修補 setup.py 並編譯安裝 CUDA 模組..."

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
Patch-SetupPy "submodules\fused-ssim\setup.py"

# 建構 CMD 編譯腳本
$hasFusedSsim = Test-Path "submodules\fused-ssim\setup.py"

$cmdScript = @"
@echo off
set DISTUTILS_USE_SDK=1
set TORCH_DONT_CHECK_COMPILER_ABI=1
call "$vcvars" -vcvars_ver=$selectedVersion

echo ========================================
echo [1/3] Installing diff-gaussian-rasterization...
echo ========================================
uv pip install submodules\diff-gaussian-rasterization --no-build-isolation
if %errorlevel% neq 0 exit /b %errorlevel%

echo ========================================
echo [2/3] Installing simple-knn...
echo ========================================
uv pip install submodules\simple-knn --no-build-isolation
if %errorlevel% neq 0 exit /b %errorlevel%
"@

if ($hasFusedSsim) {
    $cmdScript += @"

echo ========================================
echo [3/3] Installing fused-ssim...
echo ========================================
uv pip install submodules\fused-ssim --no-build-isolation
if %errorlevel% neq 0 exit /b %errorlevel%
"@
}

$tempBat = Join-Path $env:TEMP "build_cuda_modules.bat"
[System.IO.File]::WriteAllText($tempBat, $cmdScript, [System.Text.Encoding]::ASCII)
& cmd.exe /c $tempBat
$buildStatus = $LASTEXITCODE
Remove-Item $tempBat -ErrorAction SilentlyContinue

if ($buildStatus -ne 0) {
    Write-Host "`n❌ 安裝過程發生錯誤，請檢查上方紅字錯誤訊息。" -ForegroundColor Red
    exit $buildStatus
}

Write-Host "`n==================================================="
Write-Host "🔍 正在驗證模組載入狀態..."
Write-Host "==================================================="
$verifyScript = @"
import torch
print(f'[OK] PyTorch: {torch.__version__} (CUDA Available: {torch.cuda.is_available()})')
if torch.cuda.is_available():
    print(f'[OK] GPU Device: {torch.cuda.get_device_name(0)}')

import diff_gaussian_rasterization
print('[OK] diff_gaussian_rasterization: 載入成功')

import simple_knn
print('[OK] simple_knn: 載入成功')

try:
    import fused_ssim
    print('[OK] fused_ssim: 載入成功')
except Exception as e:
    print(f'[INFO] fused_ssim: 未載入 ({e})')
"@

uv run python -c $verifyScript

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n🎉 所有 3DGS CUDA 核心模組建置並驗證成功！" -ForegroundColor Green
} else {
    Write-Host "`n⚠️ 模組載入驗證失敗，請檢查上述錯誤。" -ForegroundColor Yellow
}
