param([Parameter(Mandatory=$true)][string]$NativeSdk, [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = Join-Path $OutputDirectory 'libdsh_control.so'
& (Join-Path $NativeSdk 'llvm/bin/clang.exe') '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-DOHOS_API_VERSION=26' '-fPIC' '-shared' '-O2' '-Wall' '-Wextra' '-Werror' '-Wno-deprecated-declarations' '-Wl,--no-undefined' (Join-Path $PSScriptRoot 'native/control.c') '-lace_napi.z' '-lchild_process' '-o' $output
if ($LASTEXITCODE -ne 0) { throw '控制桥编译失败' }
Write-Output '控制桥编译通过'
