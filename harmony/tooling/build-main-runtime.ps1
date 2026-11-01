param(
 [Parameter(Mandatory=$true)][string]$NativeSdk,
 [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$native=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/native'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output=Join-Path $OutputDirectory 'libdsh_runtime.so'
& "$NativeSdk/llvm/bin/clang.exe" '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-DOHOS_API_VERSION=26' '-std=c11' '-shared' '-fPIC' '-O2' '-Wall' '-Wextra' '-Werror' '-Wl,--no-undefined' '-Wl,-soname,libdsh_runtime.so' "$native/runtime_process.c" '-ldl' '-o' $output
if($LASTEXITCODE -ne 0){throw '主引擎入口构建失败'}
$elf=& "$NativeSdk/llvm/bin/llvm-readelf.exe" '-h' '-d' '-Ws' $output
if($LASTEXITCODE -ne 0){throw '主引擎ELF检查失败'}
$elf | Set-Content -LiteralPath (Join-Path $OutputDirectory 'elf-runtime.txt') -Encoding utf8
if(-not ($elf -match 'Machine:\s+AArch64') -or -not ($elf -match 'Library soname: \[libdsh_runtime.so\]') -or -not ($elf -match '\bGLOBAL\b.*\bProbeDsh\b')){throw '主引擎ELF架构/SONAME/入口导出错误'}
$hashes=@{}
foreach($name in @('runtime_process.c','argument_storage.h')){$hashes[$name]=(Get-FileHash (Join-Path $native $name) -Algorithm SHA256).Hash.ToLower()}
@{version=1;target='aarch64-linux-ohos';api=26;sources=$hashes;file='libdsh_runtime.so';sha256=(Get-FileHash $output -Algorithm SHA256).Hash.ToLower();verifiedOnDevice=$false} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-provenance.json') -Encoding utf8
Get-FileHash $output -Algorithm SHA256
