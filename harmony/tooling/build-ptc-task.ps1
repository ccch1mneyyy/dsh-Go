param(
 [Parameter(Mandatory=$true)][string]$NativeSdk,
 [Parameter(Mandatory=$true)][string]$NodeSource,
 [Parameter(Mandatory=$true)][string]$NodeLibrary,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$NodeBuildConfig,
 [string[]]$V8AbiDefines=@('-DV8_COMPRESS_POINTERS','-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE','-DV8_31BIT_SMIS_ON_64BIT_ARCH','-DV8_EXTERNAL_CODE_SPACE','-DNODE_SHARED_MODE','-DNODE_USE_V8_PLATFORM=1')
)
$ErrorActionPreference='Stop'
# 此脚本只对应已验证的共享cage压缩ABI，拒绝默默使用默认非压缩头布局。
$config = Get-Content -LiteralPath $NodeBuildConfig -Raw
foreach ($key in @('v8_enable_pointer_compression','v8_enable_pointer_compression_shared_cage','v8_enable_31bit_smis_on_64bit_arch','v8_enable_external_code_space','v8_enable_webassembly')) {
 if ($config -notmatch ("'" + $key + "'\s*:\s*1(?:,|\s)")) { throw "Node构建配置不支持本脚本要求的压缩ABI：$key" }
}
if ($config -notmatch "'node_shared'\s*:\s*'true'") { throw '必须使用共享Node运行库' }
$requiredDefines=@('-DV8_COMPRESS_POINTERS','-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE','-DV8_31BIT_SMIS_ON_64BIT_ARCH','-DV8_EXTERNAL_CODE_SPACE','-DNODE_SHARED_MODE','-DNODE_USE_V8_PLATFORM=1')
if (@(Compare-Object ($requiredDefines | Sort-Object) ($V8AbiDefines | Sort-Object)).Count -ne 0) { throw 'V8宏必须与固定压缩ABI一致' }
foreach ($header in @('src/node.h','deps/v8/include/v8.h','deps/uv/include/uv.h')) {
 if (-not (Test-Path -LiteralPath (Join-Path $NodeSource $header))) { throw "缺少Node公开头：$header" }
}
if (-not (Test-Path -LiteralPath $NodeLibrary)) { throw 'Node库不存在' }

$native=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/native'
$loader=Join-Path $PSScriptRoot '../plugins/dsh_runtime_ohos/assets/ptc-loader.cjs'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$literal=ConvertTo-Json -InputObject (Get-Content -LiteralPath $loader -Raw -Encoding utf8) -Compress
[IO.File]::WriteAllText((Join-Path $native 'ptc_loader.h'), "/* 固定引导器生成，不含本机路径。 */`nstatic const char DSH_PTC_LOADER[] = $literal;`n", [Text.UTF8Encoding]::new($false))
$base=@('--target=aarch64-linux-ohos',"--sysroot=$NativeSdk/sysroot",'-shared','-fPIC','-O2','-Wall','-Wextra','-Werror','-Wl,--no-undefined')
& "$NativeSdk/llvm/bin/clang.exe" @base '-std=c11' '-DOHOS_API_VERSION=26' '-Wno-deprecated-declarations' "$native/ptc_task.c" '-lace_napi.z' '-lchild_process' '-Wl,-soname,libdsh_ptc_task.so' '-o' "$OutputDirectory/libdsh_ptc_task.so"
if($LASTEXITCODE -ne 0){throw 'PTC宿主构建失败'}
& "$NativeSdk/llvm/bin/clang.exe" @base '-std=c11' '-DOHOS_API_VERSION=26' "$native/ptc_child.c" '-ldl' '-Wl,-soname,libdsh_ptc_child.so' '-o' "$OutputDirectory/libdsh_ptc_child.so"
if($LASTEXITCODE -ne 0){throw 'PTC子入口构建失败'}
& "$NativeSdk/llvm/bin/clang.exe" @base '-std=c11' '-DNAPI_VERSION=8' '-DNODE_GYP_MODULE_NAME=dsh_ptc_shutdown' '-I' "$NodeSource/src" "$native/ptc_shutdown.c" $NodeLibrary '-Wl,-soname,libdsh_ptc_shutdown.so' '-o' "$OutputDirectory/libdsh_ptc_shutdown.so"
if($LASTEXITCODE -ne 0){throw 'PTC关闭桥构建失败'}
& "$NativeSdk/llvm/bin/clang++.exe" @base @V8AbiDefines '-std=c++20' '-Wno-cast-function-type' '-DNODE_GYP_MODULE_NAME=dsh_ptc_exit' '-isystem' "$NodeSource/src" '-isystem' "$NodeSource/deps/v8/include" '-isystem' "$NodeSource/deps/uv/include" "$native/ptc_exit.cc" $NodeLibrary '-ldl' '-Wl,-soname,libdsh_ptc_exit.so' '-o' "$OutputDirectory/libdsh_ptc_exit.so"
if($LASTEXITCODE -ne 0){throw 'PTC原生退出观察构建失败'}
& "$NativeSdk/llvm/bin/clang++.exe" @base @V8AbiDefines '-std=c++20' '-Wno-cast-function-type' '-isystem' "$NodeSource/src" '-isystem' "$NodeSource/deps/v8/include" '-isystem' "$NodeSource/deps/uv/include" "$native/ptc_embed.cc" $NodeLibrary '-Wl,-soname,libdsh_ptc_embed.so' '-o' "$OutputDirectory/libdsh_ptc_embed.so"
if($LASTEXITCODE -ne 0){throw 'PTC嵌入入口构建失败'}
$libraryHashes=@{}
foreach($name in @('task','child','shutdown','exit','embed')){
 $file=Join-Path $OutputDirectory "libdsh_ptc_$name.so"
 $elf=& "$NativeSdk/llvm/bin/llvm-readelf.exe" '-h' '-d' '-Ws' $file
 if($LASTEXITCODE -ne 0){throw 'ELF检查失败'}
 $elf | Set-Content -Encoding utf8 (Join-Path $OutputDirectory "elf-$name.txt")
 if (-not ($elf -match 'Machine:\s+AArch64') -or -not ($elf -match ('Library soname: \[libdsh_ptc_' + $name + '\.so\]'))) { throw "ELF架构或SONAME不匹配：$name" }
 if ($name -in @('shutdown','exit','embed')) {
  if (-not ($elf -match 'Shared library: \[libnode.so\]') -or ($elf -match 'Shared library: \[libace_napi')) { throw "Node桥链接目标错误：$name" }
 }
 $libraryHashes["libdsh_ptc_$name.so"]=(Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
 Get-FileHash -Algorithm SHA256 $file
}

$sourceHashes=@{}
foreach($name in @('ptc_task.c','ptc_child.c','ptc_loader.h','ptc_shutdown.c','ptc_exit.cc','ptc_embed.cc')) { $sourceHashes[$name]=(Get-FileHash (Join-Path $native $name) -Algorithm SHA256).Hash.ToLower() }
$headerHashes=@{}
foreach($name in @('src/node.h','src/node_api.h','deps/v8/include/v8.h','deps/v8/include/v8config.h','deps/uv/include/uv.h')) { $headerHashes[$name]=(Get-FileHash (Join-Path $NodeSource $name) -Algorithm SHA256).Hash.ToLower() }
@{version=1;target='aarch64-linux-ohos';api=26;defines=$V8AbiDefines;sources=$sourceHashes;headers=$headerHashes;loaderSha256=(Get-FileHash $loader -Algorithm SHA256).Hash.ToLower();nodeSha256=(Get-FileHash $NodeLibrary -Algorithm SHA256).Hash.ToLower();configSha256=(Get-FileHash $NodeBuildConfig -Algorithm SHA256).Hash.ToLower();libraries=$libraryHashes;verifiedOnDevice=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-provenance.json') -Encoding utf8
