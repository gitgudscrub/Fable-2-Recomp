@echo off
rem One-time setup for tools\reimagine_textures.py: a Python 3.12 venv with
rem PyTorch (CUDA 12.8) and diffusers under out\tooling\reimagine\venv.
rem Needs the Python install manager (py) from python.org. About 6 GB.
setlocal
set "ROOT=%~dp0.."
set "VENV=%ROOT%\out\tooling\reimagine\venv"
py -3.12 --version >nul 2>&1 || py install 3.12 || exit /b 1
if not exist "%VENV%\Scripts\python.exe" py -3.12 -m venv "%VENV%" || exit /b 1
"%VENV%\Scripts\python.exe" -m pip install --upgrade pip
"%VENV%\Scripts\python.exe" -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128 || exit /b 1
"%VENV%\Scripts\python.exe" -m pip install diffusers transformers accelerate safetensors huggingface_hub numpy pillow || exit /b 1
"%VENV%\Scripts\python.exe" -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"
echo.
echo Run:  "%VENV%\Scripts\python.exe" tools\reimagine_textures.py out\build\win-amd64-release\textures --classify-only
