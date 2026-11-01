param(
  [Parameter(Mandatory=$true)][string]$NativeSdk,
  [Parameter(Mandatory=$true)][string]$NodeSource,
  [Parameter(Mandatory=$true)][string]$NodeLibrary,
  [Parameter(Mandatory=$true)][string]$RequireBuiltinSource,
  [Parameter(Mandatory=$true)][string]$NodeAddonApi,
  [Parameter(Mandatory=$true)][string]$SystemAddonSource,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$commit = (& git -C $RequireBuiltinSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -ne 'a58d3599a2e551d7d706d1ff796c9fd4bbaff63c') { throw 'require-builtin来源提交不符' }
$dirty = & git -C $RequireBuiltinSource status --porcelain -- packages/native
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'require-builtin原生源码必须干净' }
if ((Get-Content (Join-Path $NodeAddonApi 'package.json') -Raw | ConvertFrom-Json).version -ne '8.9.0') { throw 'node-addon-api版本不符' }
if ((Get-Content (Join-Path $SystemAddonSource 'package.json') -Raw | ConvertFrom-Json).version -ne '0.1.2') { throw 'system addon版本不符' }
$flock = Join-Path $SystemAddonSource 'src/flock.c'
if ((Get-FileHash $flock).Hash.ToLowerInvariant() -ne 'c1aa773c7a62b03ce3973156b928f41773fef9407afd79d71b2f625b5616421f') { throw 'flock源码摘要不符' }
$headers = Join-Path $OutputDirectory 'public-headers'
New-Item -ItemType Directory -Force -Path $OutputDirectory,$headers | Out-Null
foreach ($name in @('node_api.h','node_api_types.h','js_native_api.h','js_native_api_types.h','node_version.h')) {
  Copy-Item -LiteralPath (Join-Path $NodeSource "src/$name") -Destination (Join-Path $headers $name)
}
$gyp = Get-Content (Join-Path $RequireBuiltinSource 'packages/native/binding.gyp') -Raw | ConvertFrom-Json
$units = @($gyp.targets[0].sources) + @('src/runtime_context/embedder_data.cc','src/runtime_context/runtime_profile.cc','src/runtime_context/runtime_profile_napi.cc','src/runtime_compat_napi.cc')
$sources = @($units | ForEach-Object { Join-Path $RequireBuiltinSource "packages/native/$_" })
$builtin = Join-Path $OutputDirectory 'libdsh_require_builtin.so'
& "$NativeSdk/llvm/bin/clang++.exe" '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-std=c++17' '-shared' '-fPIC' '-O2' '-fno-exceptions' '-fvisibility=hidden' '-DNAPI_VERSION=9' '-DNARB_BACKEND=1' '-DNARB_PRODUCT=1' '-DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS' '-I' $headers '-I' $NodeAddonApi @sources $NodeLibrary '-Wl,--no-undefined' '-ldl' '-o' $builtin
if ($LASTEXITCODE -ne 0) { throw 'require-builtin编译失败' }
$system = Join-Path $OutputDirectory 'libdsh_flock.so'
& "$NativeSdk/llvm/bin/clang.exe" '--target=aarch64-linux-ohos' "--sysroot=$NativeSdk/sysroot" '-std=c11' '-shared' '-fPIC' '-O2' '-DNAPI_VERSION=8' '-I' $headers $flock $NodeLibrary '-Wl,--no-undefined' '-o' $system
if ($LASTEXITCODE -ne 0) { throw 'flock编译失败' }
# 保持历史验收命令，不额外引入SONAME；检查实际Node依赖。
$outputs = @()
foreach ($library in @($builtin,$system)) {
  $elf = & "$NativeSdk/llvm/bin/llvm-readelf.exe" '-h' '-d' '--dyn-syms' $library
  if ($LASTEXITCODE -ne 0 -or ($elf -join "`n") -notmatch 'AArch64' -or ($elf -join "`n") -notmatch 'Shared library: \[libnode.so\]' -or ($elf -join "`n") -match 'libace_napi') { throw 'addon ELF依赖检查失败' }
  $name = [IO.Path]::GetFileName($library)
  $elf | Set-Content (Join-Path $OutputDirectory "$name.elf.txt") -Encoding utf8
  $outputs += @{ file=$name; sha256=(Get-FileHash $library).Hash.ToLowerInvariant() }
}
Copy-Item (Join-Path $RequireBuiltinSource 'LICENSE') (Join-Path $OutputDirectory 'REQUIRE-BUILTIN-LICENSE')
Copy-Item (Join-Path $SystemAddonSource 'LICENSE') (Join-Path $OutputDirectory 'SYSTEM-ADDON-LICENSE')
Copy-Item (Join-Path $NodeAddonApi 'LICENSE.md') (Join-Path $OutputDirectory 'NODE-ADDON-API-LICENSE.md')
Copy-Item (Join-Path $NodeSource 'LICENSE') (Join-Path $OutputDirectory 'NODE-LICENSE')
@{ requireBuiltinCommit=$commit; nodeAddonApiVersion='8.9.0'; flockVersion='0.1.2'; flockSourceSha256=(Get-FileHash $flock).Hash.ToLowerInvariant(); nodeLibrarySha256=(Get-FileHash $NodeLibrary).Hash.ToLowerInvariant(); outputs=$outputs; verifiedOnDevice=$false } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'build-provenance.json') -Encoding utf8
