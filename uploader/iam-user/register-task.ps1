#Requires -RunAsAdministrator
# Register the CCTV uploader as a recurring Windows Scheduled Task.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$VideoBucketName,

    [Parameter(Mandatory = $false)]
    [string]$IngestPrefix = 'videos',

    [Parameter(Mandatory = $false)]
    [string]$Profile = 'cctv-uploader',

    [Parameter(Mandatory = $false)]
    [string]$Region = 'us-east-1',

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 1440)]
    [int]$EveryMinutes = 15,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1440)]
    [int]$MinimumFileAgeMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$TaskName = 'CctvVideoUploader',

    [Parameter(Mandatory = $false)]
    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME",

    [Parameter(Mandatory = $false)]
    [string]$InstallDirectory = "$env:ProgramData\CctvUploader\bin",

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "$env:ProgramData\CctvUploader\logs",

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$CurrentWindowsUser = (& whoami.exe).Trim()
if ($CurrentWindowsUser -ine $RunAsUser) {
    throw "Ejecute este script como '$RunAsUser'. Los perfiles AWS pertenecen al usuario Windows que los configuró; usuario actual=$CurrentWindowsUser."
}

& aws sts get-caller-identity --profile $Profile --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "El perfil '$Profile' no funciona para $CurrentWindowsUser. Ejecute configure-profile.ps1 con esta misma cuenta."
}

$SourceUploadScript = (Resolve-Path (Join-Path $PSScriptRoot 'upload-videos.ps1')).Path
$SourceDirectory = (Resolve-Path $SourceDirectory).Path

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$UploadScript = Join-Path $InstallDirectory 'upload-videos.ps1'
Copy-Item -Path $SourceUploadScript -Destination $UploadScript -Force

& icacls.exe $InstallDirectory /inheritance:r /grant:r `
    "${RunAsUser}:(OI)(CI)(RX)" 'SYSTEM:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No se pudo proteger $InstallDirectory." }
& icacls.exe $LogDirectory /inheritance:r /grant:r `
    "${RunAsUser}:(OI)(CI)(M)" 'SYSTEM:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No se pudo proteger $LogDirectory." }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    if (-not $Force) {
        throw "La tarea '$TaskName' ya existe. Use -Force únicamente para reemplazarla conscientemente."
    }
}

$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ActionArguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-File', "`"$UploadScript`"",
    '-SourceDirectory', "`"$SourceDirectory`"",
    '-VideoBucketName', "`"$VideoBucketName`"",
    '-IngestPrefix', "`"$IngestPrefix`"",
    '-Profile', "`"$Profile`"",
    '-Region', "`"$Region`"",
    '-MinimumFileAgeMinutes', $MinimumFileAgeMinutes,
    '-LogDirectory', "`"$LogDirectory`""
) -join ' '

$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $ActionArguments
$Trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$Settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Write-Host "La tarea se ejecutará como $RunAsUser."
Write-Host 'Ingrese la contraseña de esa cuenta en el diálogo seguro de PowerShell.'
$Credential = Get-Credential -UserName $RunAsUser -Message 'Credencial de la cuenta que ejecutará el uploader'

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description 'Synchronize completed CCTV AVI recordings to private Amazon S3.' `
    -User $Credential.UserName `
    -Password $Credential.GetNetworkCredential().Password `
    -RunLevel Limited `
    -Force:$Force | Out-Null

$Task = Get-ScheduledTask -TaskName $TaskName
Write-Host "OK: tarea '$TaskName' registrada; estado=$($Task.State); intervalo=$EveryMinutes minutos."
Write-Host "Prueba manual: Start-ScheduledTask -TaskName '$TaskName'"
