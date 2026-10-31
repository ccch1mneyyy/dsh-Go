param([Parameter(Mandatory = $true)][string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$metadata = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pinned-source.json') -Raw | ConvertFrom-Json
$sdkPath = (Resolve-Path -LiteralPath $SdkRoot).Path
$revision = & git -C $sdkPath rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $metadata.commit) {
  throw 'Flutter-OH提交不匹配；此补丁只适用于固定预览版本。'
}
$fieldHash = (Get-FileHash -LiteralPath (Join-Path $sdkPath $metadata.textFieldPath) -Algorithm SHA256).Hash
if ($fieldHash -notin @($metadata.textFieldPatchedSha256, $metadata.textFieldCanonicalPatchedSha256)) {
  throw '输入框源码未匹配已知CRLF或LF版本的补丁结果。'
}
$checks = @(
  @{ Path = (Join-Path $sdkPath $metadata.helperPath); Hash = $metadata.helperSha256 },
  @{ Path = (Join-Path $PSScriptRoot 'ohos_paste_toolbar.dart'); Hash = $metadata.helperSha256 },
  @{ Path = (Join-Path $PSScriptRoot 'flutter-ohos-secure-paste.patch'); Hash = $metadata.patchSha256 },
  @{ Path = (Join-Path $PSScriptRoot 'flutter-ohos-secure-paste-lf.patch'); Hash = $metadata.canonicalPatchSha256 }
)
foreach ($check in $checks) {
  if (!(Test-Path -LiteralPath $check.Path) -or
      (Get-FileHash -LiteralPath $check.Path -Algorithm SHA256).Hash -ne $check.Hash) {
    throw "文件校验失败：$($check.Path)"
  }
}
Write-Output '固定提交及安全粘贴源码/两种换行补丁校验通过；未运行构建或设备操作。'
