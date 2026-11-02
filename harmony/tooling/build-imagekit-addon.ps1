param(
  [Parameter(Mandatory=$true)][string]$NativeSdk,
  [Parameter(Mandatory=$true)][string]$NodeSource,
  [Parameter(Mandatory=$true)][string]$NodeLibrary,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$source=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/native/imagekit.c'
$output=Join-Path $OutputDirectory 'libdsh_imagekit_candidate.so'
& "$NativeSdk/llvm/bin/clang.exe" '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-std=c11' '-shared' '-fPIC' '-O2' '-Wall' '-Wextra' '-Werror' '-DNAPI_VERSION=8' '-DNODE_GYP_MODULE_NAME=dsh_imagekit_candidate' '-I' "$NodeSource/src" $source $NodeLibrary '-limage_source' '-limage_packer' '-lpixelmap' '-lnative_color_space_manager' '-Wl,--no-undefined' '-Wl,-soname,libdsh_imagekit_candidate.so' '-o' $output
if($LASTEXITCODE -ne 0){throw 'ImageKit候选交叉编译失败'}
$elf=& "$NativeSdk/llvm/bin/llvm-readelf.exe" '-h' '-d' '--dyn-syms' $output
if($LASTEXITCODE -ne 0){throw '候选ELF检查失败'}
if(-not ($elf -match 'Machine:\s+AArch64') -or -not ($elf -match 'Library soname: \[libdsh_imagekit_candidate.so\]')){throw 'ImageKit目标架构或SONAME不匹配'}
if(-not ($elf -match 'Shared library: \[libnode.so\]') -or ($elf -match 'libace_napi')){throw '候选必须使用Node NAPI，不能依赖ArkTS NAPI'}
$elf | Set-Content -LiteralPath (Join-Path $OutputDirectory 'elf-report.txt') -Encoding utf8
@{version=1;source='harmony/plugins/dsh_runtime_ohos/native/imagekit.c';target='aarch64-linux-ohos';napiVersion=8;deviceTested=$false;productionIntegrated=$false;sourceSha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();file='libdsh_imagekit_candidate.so';sha256=(Get-FileHash $output -Algorithm SHA256).Hash.ToLower();nodeLibrarySha256=(Get-FileHash $NodeLibrary -Algorithm SHA256).Hash.ToLower();transformVersion='request-image-imagekit-candidate-v2'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-result.json') -Encoding utf8
