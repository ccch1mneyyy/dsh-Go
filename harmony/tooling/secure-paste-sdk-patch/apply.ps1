param(
  [Parameter(Mandatory = $true)][string]$SdkRoot,
  [Parameter(Mandatory = $true)][string]$BackupRoot
)
$ErrorActionPreference = 'Stop'
$metadata = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pinned-source.json') -Raw | ConvertFrom-Json
$sdkPath = (Resolve-Path -LiteralPath $SdkRoot).Path
$backupPath = [IO.Path]::GetFullPath($BackupRoot)
$revision = & git -C $sdkPath rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $metadata.commit) {
  throw 'Flutter-OH提交不匹配，停止以免覆盖其他工具链。'
}
$field = Join-Path $sdkPath $metadata.textFieldPath
$helper = Join-Path $sdkPath $metadata.helperPath
$patch = Join-Path $PSScriptRoot 'flutter-ohos-secure-paste.patch'
$canonicalPatch = Join-Path $PSScriptRoot 'flutter-ohos-secure-paste-lf.patch'
$helperSource = Join-Path $PSScriptRoot 'ohos_paste_toolbar.dart'
if ((Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash -ne $metadata.patchSha256 -or
    (Get-FileHash -LiteralPath $canonicalPatch -Algorithm SHA256).Hash -ne $metadata.canonicalPatchSha256 -or
    (Get-FileHash -LiteralPath $helperSource -Algorithm SHA256).Hash -ne $metadata.helperSha256) {
  throw '交付补丁或helper源码校验失败。'
}
$fieldHash = (Get-FileHash -LiteralPath $field -Algorithm SHA256).Hash
$helperHash = if (Test-Path -LiteralPath $helper) { (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash } else { $null }
$alreadyPatched = $fieldHash -in @($metadata.textFieldPatchedSha256, $metadata.textFieldCanonicalPatchedSha256)
if ($alreadyPatched -and $helperHash -eq $metadata.helperSha256) {
  & (Join-Path $PSScriptRoot 'verify.ps1') -SdkRoot $sdkPath
  return
}
$clean = $fieldHash -in @($metadata.textFieldOriginalSha256, $metadata.textFieldCanonicalOriginalSha256) -and $null -eq $helperHash
$upgrade = $alreadyPatched -and
  ($null -eq $helperHash -or $helperHash -eq $metadata.previousHelperSha256)
if (!$clean -and !$upgrade) {
  throw '目标源码含未知改动，停止；请使用固定提交的独立工具副本。'
}
if ($clean) {
  if ($fieldHash -eq $metadata.textFieldCanonicalOriginalSha256) { $patch = $canonicalPatch }
  & git -C $sdkPath -c core.autocrlf=false apply --check $patch
  if ($LASTEXITCODE -ne 0) { throw '补丁预检查失败，尚未修改SDK。' }
}
$backup = Join-Path $backupPath ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $field -Destination (Join-Path $backup 'text_field.dart')
if ($null -ne $helperHash) {
  Copy-Item -LiteralPath $helper -Destination (Join-Path $backup 'ohos_paste_toolbar.dart')
}
if ($clean) {
  & git -C $sdkPath -c core.autocrlf=false apply $patch
  if ($LASTEXITCODE -ne 0) { throw "补丁应用失败，原文件备份：$backup" }
} else {
  Copy-Item -LiteralPath $helperSource -Destination $helper -Force
}
& (Join-Path $PSScriptRoot 'verify.ps1') -SdkRoot $sdkPath
Write-Output "已应用已知版本补丁；原文件备份：$backup"
