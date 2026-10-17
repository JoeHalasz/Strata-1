# build-vision-cpu.ps1 - builds Strata's image encoder (strata-vision.exe) on Windows, CPU build.
#
# Why: the ready-made AMD/HIP engine zip for Windows ships without an image encoder - engine\BUILD.json
# says "vision": "none" - and setup.py turns images off for AMD on Windows (hip_vision() returns "none"
# there, docs\AMD_HIP.md line 85: "no images yet (the CPU image encoder is Linux-only for now)").  The
# engine binary itself already understands --vision, and the mmproj file is already downloaded, so the
# only missing piece is this encoder.  Community reports (issue #2442) run the CPU encoder beside the
# HIP engine on Windows the same way.
#
#   .venv\Scripts\python.exe -c "print(1)"   # (the venv is only needed for cmake/ninja, both in .venv\Scripts)
#   powershell -ExecutionPolicy Bypass -File build-vision-cpu.ps1              # native build for this CPU
#   powershell -ExecutionPolicy Bypass -File build-vision-cpu.ps1 -Portable    # AVX2 baseline (release default)
#
# Needs Visual Studio 2022 (or 2019) with the "Desktop development with C++" workload.

param([switch]$Portable, [switch]$ConfigureOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bdir = Join-Path $root 'build-vision'

# The .venv\Scripts\cmake.exe shim carries the python path from the venv's creation, so it breaks when the
# folder moves (here: "Fatal error in launcher: Unable to create process using 'C:\Program Files (x86)\Strata\
# .venv\Scripts\python.exe'").  The pip cmake/ninja wheels ship their real binaries; use those.
function Find-BuildTool([string[]]$candidates) {
    foreach ($c in $candidates) {
        if (-not (Test-Path $c)) { continue }
        & $c --version *> $null
        if ($LASTEXITCODE -eq 0) { return (Resolve-Path $c).Path }
    }
    throw ("not found or not runnable: " + ($candidates -join ', ') + " - run: .venv\Scripts\python.exe -m pip install cmake ninja")
}
$cmake = Find-BuildTool @('.venv\Lib\site-packages\cmake\data\bin\cmake.exe', '.venv\Scripts\cmake.exe' |
                          ForEach-Object { Join-Path $root $_ })
$ninja = Find-BuildTool @('.venv\Scripts\ninja.exe', '.venv\Lib\site-packages\ninja\data\ninja.exe' |
                          ForEach-Object { Join-Path $root $_ })
Write-Output "cmake: $cmake"
Write-Output "ninja: $ninja"

$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    $vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
}
if (-not (Test-Path $vcvars)) {
    throw 'vcvars64.bat was not found - install Visual Studio 2022 with the "Desktop development with C++" workload'
}
Write-Output "MSVC environment: $vcvars"

# Import the MSVC environment (PATH, INCLUDE, LIB, ...) into this PowerShell session
$dump = & "$env:ComSpec" /c "`"$vcvars`" >nul 2>&1 && set"
foreach ($line in $dump) {
    if ($line -match '^(.*?)=(.*)$') { Set-Item -Path ("Env:" + $matches[1]) -Value $matches[2] }
}

& $cmake -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" -S (Join-Path $root 'tools\vision') -B $bdir `
    '-DCMAKE_BUILD_TYPE=Release' "-DLLAMA_DIR=$(Join-Path $root 'third_party\llama.cpp')" `
    '-DSTRATA_VISION_CUDA=OFF' ("-DSTRATA_PORTABLE=" + ($(if ($Portable) { 'ON' } else { 'OFF' })))
if ($LASTEXITCODE -ne 0) { throw "cmake configure stopped with code $LASTEXITCODE" }
if ($ConfigureOnly) { Write-Output 'configured'; exit 0 }

& $cmake --build $bdir --target strata-vision -j 16
if ($LASTEXITCODE -ne 0) { throw "cmake build stopped with code $LASTEXITCODE" }

$exe = Join-Path $bdir 'bin\strata-vision.exe'
if (-not (Test-Path $exe)) { throw "the build finished but $exe is missing" }
Copy-Item $exe (Join-Path $root 'engine\strata-vision.exe') -Force
Write-Output "installed: $(Join-Path $root 'engine\strata-vision.exe')"
