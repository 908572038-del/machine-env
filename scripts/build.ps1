param(
    [string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $VsWhere)) {
    throw "vswhere.exe not found. Install Visual Studio with the C++ workload."
}

$VsRoot = & $VsWhere -latest -products '*' -property installationPath |
    Select-Object -First 1
if ($VsRoot) {
    $VsRoot = $VsRoot.Trim()
}
if (-not $VsRoot) {
    throw 'No Visual Studio or Build Tools installation found by vswhere.'
}

$VcVars = Join-Path $VsRoot 'VC\Auxiliary\Build\vcvars64.bat'
$Ninja = Join-Path $VsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
$CMake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not (Test-Path -LiteralPath $VcVars)) {
    throw "vcvars64.bat not found: $VcVars"
}
if (-not (Test-Path -LiteralPath $Ninja)) {
    throw "Visual Studio's Ninja executable was not found: $Ninja"
}
if (-not $CMake) {
    throw 'CMake was not found on PATH. Install CMake or Visual Studio CMake tools.'
}

$BuildDir = if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    Join-Path $Root 'build'
} else {
    [System.IO.Path]::GetFullPath($BuildDirectory)
}
$CacheFile = Join-Path $BuildDir 'CMakeCache.txt'
if (Test-Path -LiteralPath $CacheFile) {
    $CacheLine = Select-String -LiteralPath $CacheFile `
        -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=' | Select-Object -First 1
    $CachedSource = if ($CacheLine) { $CacheLine.Line.Split('=', 2)[1] } else { '' }
        $CachedSourcePath = $CachedSource.Replace('/', '\').TrimEnd('\')
        $CurrentSource = [System.IO.Path]::GetFullPath($Root).Replace('/', '\').TrimEnd('\')
    if ($CachedSource -and -not [string]::Equals(
            $CachedSourcePath, $CurrentSource,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Discarding CMake cache from '$CachedSource'" -ForegroundColor Yellow
        foreach ($GeneratedFile in @(
            'CMakeCache.txt', 'build.ninja', 'build.ninja.old',
            'cmake_install.cmake', '.ninja_deps', '.ninja_log'
        )) {
            Remove-Item -LiteralPath (Join-Path $BuildDir $GeneratedFile) `
                -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $BuildDir 'CMakeFiles') `
            -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$Output = Join-Path $BuildDir 'machine-env-cpp.exe'

$Command = 'call "' + $VcVars + '" >nul 2>&1 && "' + $CMake +
    '" -S "' + $Root + '" -B "' + $BuildDir +
    '" -G Ninja -DCMAKE_MAKE_PROGRAM="' + $Ninja +
    '" -DCMAKE_BUILD_TYPE=Release && "' + $CMake +
    '" --build "' + $BuildDir + '" --config Release'

Write-Host "Configuring CMake with Visual Studio at $VsRoot" -ForegroundColor Cyan
& $env:ComSpec /d /s /c $Command
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure/build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $Output)) {
    throw "CMake completed without producing $Output"
}

Write-Host "`nRunning native self-test" -ForegroundColor Cyan
& $Output --selftest
if ($LASTEXITCODE -ne 0) {
    throw "Native self-test failed with exit code $LASTEXITCODE"
}

Write-Host "`nBuilt: $Output" -ForegroundColor Green
