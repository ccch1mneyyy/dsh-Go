param(
  [Parameter(Mandatory = $true)][string]$CltRoot,
  [Parameter(Mandatory = $true)][string]$BackupRoot
)
$ErrorActionPreference = 'Stop'
$originalHash = '07C834FC20406E85757142118B87AAFF8DFA59EB52D103E6CAB69C71BAF285F1'
$patchedHash = '654EB7B99EEC3D7B489EE86F06F819791024169CAF3EADC6153F6D1B02729393'
$launcher = Join-Path (Resolve-Path -LiteralPath $CltRoot).Path 'ohpm\bin\ohpm.bat'
$replacement = Join-Path $PSScriptRoot 'ohpm.bat'
if ((Get-FileHash -LiteralPath $replacement -Algorithm SHA256).Hash -ne $patchedHash) {
  throw '修复文件校验失败，未修改工具链。'
}
$currentHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
if ($currentHash -eq $patchedHash) {
  Write-Output '启动器已修复，校验通过。'
  return
}
if ($currentHash -ne $originalHash) {
  throw '启动器不匹配已验证的 CLT 26.0.0.851，拒绝覆盖未知修改。'
}
# 先保存精确原始字节，再替换；备份目录由调用者显式指定。
$backupDirectory = Join-Path $BackupRoot ('ohpm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupDirectory -ErrorAction Stop | Out-Null
$backup = Join-Path $backupDirectory 'ohpm.original.bat'
Copy-Item -LiteralPath $launcher -Destination $backup -ErrorAction Stop
if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $originalHash) {
  throw '备份校验失败，未修改工具链。'
}
Copy-Item -LiteralPath $replacement -Destination $launcher -ErrorAction Stop
if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -ne $patchedHash) {
  throw "写入后校验失败，可从备份恢复：$backup"
}
Write-Output "启动器修复完成，原始文件备份：$backup"
