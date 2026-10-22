# Disable and remove the local CCTV uploader scheduled task.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string]$TaskName = 'CctvVideoUploader'
)

$ErrorActionPreference = 'Stop'
$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $Task) {
    Write-Host "La tarea '$TaskName' no existe; no hay cambios."
    exit 0
}

if ($PSCmdlet.ShouldProcess($TaskName, 'Deshabilitar y eliminar la tarea programada')) {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "OK: tarea '$TaskName' eliminada."
    Write-Host 'La access key debe deshabilitarse o eliminarse por separado en IAM.'
}
