@echo off
rem build-vision-cpu.bat - builds Strata's image encoder (strata-vision.exe) on Windows for the CPU.
rem
rem Why this exists: the ready-made AMD/HIP engine zip for Windows ships without an image encoder
rem (engine\BUILD.json says "vision": "none"), and setup.py refuses --vision on AMD + Windows
rem (hip_vision() returns "none" there).  The engine itself does understand --vision, and the
rem mmproj file is already downloaded, so the only missing piece is this encoder binary.
rem Community reports (issue #2442) confirm the CPU encoder works beside the HIP engine on Windows.
rem
rem Needs: Visual Studio 2022 (or 2019) with the "Desktop development with C++" workload, and the
rem repo's own .venv, which carries cmake and ninja.
rem
rem   build-vision-cpu.bat            native build for this CPU (what setup.py does on the PC it runs on)
rem   build-vision-cpu.bat portable   AVX2 baseline build (the release default; runs on any PC)
rem
rem After it finishes, the exe is copied to engine\strata-vision.exe and engine\BUILD.json is stamped.

setlocal
set ROOT=%~dp0
set BDIR=%ROOT%build-vision
set VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat
if not exist "%VCVARS%" set VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat
if not exist "%VCVARS%" (
  echo Visual Studio's vcvars64.bat was not found. Install Visual Studio 2022 with the
  echo "Desktop development with C++" workload, or point VCVARS at your own copy.
  exit /b 2
)

set PORTABLE=OFF
if /i "%~1"=="portable" set PORTABLE=ON

call "%VCVARS%" >nul || exit /b 2
"%ROOT%.venv\Scripts\cmake.exe" -G Ninja -DCMAKE_MAKE_PROGRAM="%ROOT%.venv\Scripts\ninja.exe" -S "%ROOT%tools\vision" -B "%BDIR%" -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR="%ROOT%third_party\llama.cpp" -DSTRATA_VISION_CUDA=OFF -DSTRATA_PORTABLE=%PORTABLE% || exit /b 1
"%ROOT%.venv\Scripts\cmake.exe" --build "%BDIR%" --target strata-vision -j 16 || exit /b 1

if not exist "%BDIR%\bin\strata-vision.exe" (
  echo The build finished but %BDIR%\bin\strata-vision.exe is not there - look above for the exe's path.
  exit /b 1
)
copy /y "%BDIR%\bin\strata-vision.exe" "%ROOT%engine\strata-vision.exe" >nul || exit /b 1
echo.
echo Built and installed: %ROOT%engine\strata-vision.exe
endlocal
