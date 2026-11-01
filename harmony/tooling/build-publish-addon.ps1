param(
  [Parameter(Mandatory=$true)][string]$NativeSdk,
  [Parameter(Mandatory=$true)][string]$NodeSource,
  [Parameter(Mandatory=$true)][string]$NodeLibrary,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/native/publish.c'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output=Join-Path $OutputDirectory 'libdsh_publish.so'
& "$NativeSdk/llvm/bin/clang.exe" '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-std=c11' '-shared' '-fPIC' '-O2' '-Wall' '-Wextra' '-Werror' '-DNAPI_VERSION=8' '-DNODE_GYP_MODULE_NAME=dsh_publish' '-I' "$NodeSource/src" '-I' "$NodeSource/deps/uv/include" $source $NodeLibrary '-Wl,--no-undefined' '-Wl,-soname,libdsh_publish.so' '-o' $output
if($LASTEXITCODE -ne 0){throw '发布插件交叉编译失败'}
$elf=& "$NativeSdk/llvm/bin/llvm-readelf.exe" '-h' '-d' '--dyn-syms' $output
if($LASTEXITCODE -ne 0){throw '发布插件ELF检查失败'}
$elf | Set-Content -LiteralPath (Join-Path $OutputDirectory 'elf-report.txt') -Encoding utf8
if(-not ($elf -match 'Shared library: \[libnode.so\]') -or ($elf -match 'libace_napi')){throw '发布插件必须显式依赖libnode，不能链接ArkTS NAPI'}
$helper=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/assets/persistence-publish.mjs'
@{version=1;helperSha256=(Get-FileHash $helper -Algorithm SHA256).Hash.ToLower();source='harmony/plugins/dsh_runtime_ohos/native/publish.c';sourceSha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();target='aarch64-linux-ohos';napiVersion=8;nodeLibrarySha256=(Get-FileHash $NodeLibrary -Algorithm SHA256).Hash.ToLower();file='libdsh_publish.so';sha256=(Get-FileHash $output -Algorithm SHA256).Hash.ToLower();deviceTested=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-result.json') -Encoding utf8
