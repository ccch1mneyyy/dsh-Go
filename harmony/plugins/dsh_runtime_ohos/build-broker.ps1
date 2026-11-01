param([Parameter(Mandatory=$true)][string]$NativeSdk, [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = Join-Path $OutputDirectory 'libdsh_broker.so'
& (Join-Path $NativeSdk 'llvm/bin/clang.exe') '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-DOHOS_API_VERSION=26' '-std=c11' '-fPIC' '-shared' '-O2' '-Wall' '-Wextra' '-Werror' '-Wno-deprecated-declarations' '-Wl,--no-undefined' (Join-Path $PSScriptRoot 'native/broker.c') '-lace_napi.z' '-o' $output
if ($LASTEXITCODE -ne 0) { throw '引擎宿主通道编译失败' }
Write-Output '引擎宿主通道编译通过'
