@echo off
rem ===========================================================================
rem Fable 2 launcher - picks the GPU backend and stages the matching
rem rexruntime.dll before launching fable_2.exe.
rem
rem   fable2.cmd            D3D12  (the SDK fork's D3D12 runtime + plugin)
rem   fable2.cmd vulkan     Vulkan (the SDK fork built with Vulkan enabled)
rem
rem Why a launcher? The runtime file name is fixed (rexruntime.dll). The
rem Vulkan plugin (rexgpu-xenos-vulkan.dll, from tools\build_sdk_vulkan.cmd)
rem imports Vulkan symbols that the normal D3D12-only runtime does not export,
rem so Vulkan needs the Vulkan-enabled runtime in place. This copies the right
rem runtime over rexruntime.dll, then launches. Both runtimes are built from
rem the same thirdparty\rexglue-sdk submodule.
rem
rem   d3d12  -> rexruntime.dll = rexruntime-d3d12.dll  (copy of the build's
rem                              own runtime, restores it after a Vulkan run)
rem             plugin         = rexgpu-xenos.dll      (--gpu_plugin=xenos)
rem   vulkan -> rexruntime.dll = rexruntime-vulkan.dll
rem             plugin         = rexgpu-xenos-vulkan.dll (--gpu_plugin=xenos-vulkan,
rem                              loaded by name; rexgpu-xenos.dll is untouched)
rem ===========================================================================
setlocal
cd /d "%~dp0"
set "MODE=d3d12"
if /i "%~1"=="vulkan" set "MODE=vulkan"

if /i "%MODE%"=="vulkan" (
    if not exist "rexruntime-vulkan.dll" (
        echo Error: rexruntime-vulkan.dll not found. Build the Vulkan SDK first: 1>&2
        echo   tools\build_sdk_vulkan.cmd 1>&2
        exit /b 1
    )
    if not exist "rexgpu-xenos-vulkan.dll" (
        echo Error: rexgpu-xenos-vulkan.dll not found next to fable_2.exe. 1>&2
        exit /b 1
    )
    copy /y "rexruntime-vulkan.dll" "rexruntime.dll" >nul
    "fable_2.exe" --gpu_plugin=xenos-vulkan
) else (
    if exist "rexruntime-d3d12.dll" copy /y "rexruntime-d3d12.dll" "rexruntime.dll" >nul
    "fable_2.exe" --gpu_plugin=xenos
)
endlocal
