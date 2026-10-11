param(
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

# 強制將工作目錄切換至腳本所在目錄，防止使用者在外部目錄呼叫時相對路徑錯亂
if ($PSScriptRoot) {
    Set-Location -Path $PSScriptRoot
}

Write-Host "==================================================="
Write-Host "3DGS 環境建置腳本"
Write-Host "==================================================="

# 1. 確保基本依賴套件已安裝
Write-Host "`n[步驟 1/5] 確認環境基本套件..."
uv pip install setuptools ninja wheel plyfile tqdm opencv-python joblib

# 2. 檢查並補齊 Submodules（同時支援 Git Clone 與 GitHub Download ZIP 用戶）
Write-Host "`n[步驟 2/5] 檢查 Git Submodules 狀態..."

function Ensure-Submodule {
    param(
        [string]$RelPath,
        [string]$PrimaryUrl,
        [string]$FallbackUrl = "",
        [string]$Branch = ""
    )

    $targetDir = Join-Path $PSScriptRoot $RelPath
    $setupPy = Join-Path $targetDir "setup.py"

    # 若 setup.py 已存在，檢查巢狀依賴 (例如 diff-gaussian-rasterization 的 third_party/glm)
    if (Test-Path $setupPy) {
        if ($RelPath -match "diff-gaussian-rasterization") {
            $glmHeader = Join-Path $targetDir "third_party\glm\glm\glm.hpp"
            if (Test-Path $glmHeader) {
                Write-Host "  -> ✅ $RelPath 已完整就緒"
                return
            }
            Write-Host "  -> ⚠️  $RelPath 缺少 third_party/glm，正在補齊..."
        } else {
            Write-Host "  -> ✅ $RelPath 已完整就緒"
            return
        }
    }

    Write-Host "  -> 正在下載/修復子模組 [$RelPath]..."

    $isGitRepo = Test-Path (Join-Path $PSScriptRoot ".git")

    # 途徑 A: 若本專案為 Git 版本庫，先嘗試官方 git submodule 指令
    if ($isGitRepo) {
        Write-Host "     [嘗試 1] 透過 git submodule 拉取..."
        & git submodule sync $RelPath 2>$null
        & git submodule update --init --recursive --force $RelPath 2>$null
    }

    # 檢查途徑 A 是否成功
    $ready = Test-Path $setupPy
    if ($ready -and ($RelPath -match "diff-gaussian-rasterization")) {
        $glmHeader = Join-Path $targetDir "third_party\glm\glm\glm.hpp"
        if (-not (Test-Path $glmHeader)) {
            Push-Location $targetDir
            & git submodule update --init --recursive 2>$null
            Pop-Location
            $ready = Test-Path $glmHeader
        }
    }

    # 途徑 B: 若非 Git Repo (Download ZIP 用戶) 或 submodule 失敗，改用直接 git clone 備援
    if (-not $ready) {
        if (-not $isGitRepo) {
            Write-Host "     ℹ️ 偵測到本專案非 Git Clone (可能是 GitHub Download ZIP)，切換為直接 clone 備援方案..."
        } else {
            Write-Warning "     git submodule 無法取得檔案，切換為直接 clone 備援方案..."
        }

        # 清除可能殘留的空資料夾
        if (Test-Path $targetDir) {
            Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $parentDir = Split-Path -Parent $targetDir
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        $cloneArgs = @("clone", "--recursive", $PrimaryUrl, $targetDir)
        if ($Branch) {
            $cloneArgs = @("clone", "--recursive", "-b", $Branch, $PrimaryUrl, $targetDir)
        }

        Write-Host "     正在從主來源下載: $PrimaryUrl ..."
        & git @cloneArgs 2>$null

        # 若主來源連線失敗且提供備援鏡像 (例如 simple-knn 的 Inria GitLab 偶爾會連不上，備援至 GitHub 鏡像)
        if ((-not (Test-Path $setupPy)) -and $FallbackUrl) {
            Write-Warning "     主來源連線超時或失敗，切換為備援鏡像: $FallbackUrl ..."
            if (Test-Path $targetDir) {
                Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $fallbackArgs = @("clone", "--recursive", $FallbackUrl, $targetDir)
            & git @fallbackArgs 2>$null
        }
    }

    # 最終驗證：若仍找不到 setup.py 則阻斷並報錯 (Fail Fast)
    if (-not (Test-Path $setupPy)) {
        Write-Error "❌ 無法取得子模組 [$RelPath]！`n請確認已安裝 Git 且網路可正常連線，或請手動下載原始碼放至：`n$targetDir"
    }

    Write-Host "  -> ✅ $RelPath 就緒完成！"
}

Ensure-Submodule "submodules\diff-gaussian-rasterization" "https://github.com/graphdeco-inria/diff-gaussian-rasterization.git" "" "dr_aa"
Ensure-Submodule "submodules\simple-knn" "https://gitlab.inria.fr/bkerbl/simple-knn.git" "https://github.com/camenduru/simple-knn.git"
Ensure-Submodule "submodules\fused-ssim" "https://github.com/rahul-goel/fused-ssim.git"

Write-Host "✅ 所有 Submodules 已全數就緒！"

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

# 檢查是否已成功編譯過 CUDA 模組 (避免重複耗時編譯)
$modulesAlreadyInstalled = $false
if (-not $Rebuild) {
    try {
        $checkInstalled = uv run python -c "import diff_gaussian_rasterization, simple_knn; print('OK')" 2>$null
        if ($checkInstalled -match "OK") {
            $modulesAlreadyInstalled = $true
        }
    } catch {}
}

if ($modulesAlreadyInstalled) {
    Write-Host "`n[步驟 4/5 & 5/5] 檢測到 CUDA 核心模組已安裝且可正常載入，略過重複編譯。" -ForegroundColor Green
    Write-Host "  (若需要強制重新編譯，請執行: .\install_cuda_modules.ps1 -Rebuild)"
} else {
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
    $versions = @(Get-ChildItem -Path $msvcPath -Directory | Select-Object -ExpandProperty Name | Sort-Object -Descending)

    # 優先選擇小於 14.50 的版本 (避免 NVCC 在過新 MSVC 上發生 0xC0000005 崩潰)
    $selectedVersion = $versions | Where-Object { [version]$_ -lt [version]"14.50" } | Select-Object -First 1

    if (-not $selectedVersion) {
        if ($versions.Count -gt 0) {
            $selectedVersion = $versions[0]
        }
        Write-Warning "⚠️  找到的 MSVC 版本為 $selectedVersion (>= 14.50)。"
        Write-Warning "   注意：MSVC 14.5x (VS 2026 最新版) 目前會使 NVIDIA NVCC (cudafe++) 發生 0xC0000005 記憶體崩潰！"
        Write-Warning "   解決方法：請開啟 Visual Studio Installer -> 修改 (Modify) -> 個別元件 (Individual Components)，"
        Write-Warning "   搜尋並勾選安裝「MSVC v14.44 (17.14) C++ x64/x86 建置工具」或「MSVC v143」，安裝後即可正常編譯。"
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
