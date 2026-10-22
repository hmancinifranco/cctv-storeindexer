# Synchronize completed AVI recordings to the private S3 ingest prefix.
# Requires the cctv-uploader role profile created by configure-profile.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$VideoBucketName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9!_.*''()/-]+$')]
    [string]$IngestPrefix = 'videos',

    [Parameter(Mandatory = $false)]
    [string]$Profile = 'cctv-uploader',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[a-z]{2}(-gov)?-[a-z]+-\d$')]
    [string]$Region = 'us-east-1',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1440)]
    [int]$MinimumFileAgeMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = "$env:ProgramData\CctvUploader\logs",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$SourceDirectory = (Resolve-Path $SourceDirectory).Path
$IngestPrefix = $IngestPrefix.Trim('/')
$Destination = "s3://$VideoBucketName/$IngestPrefix/"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'AWS CLI v2 no está instalado o no está en PATH.'
}

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogPath = Join-Path $LogDirectory ("upload-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
$LockPath = Join-Path $LogDirectory 'upload.lock'

function Write-UploadLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][hashtable]$Data
    )
    $Record = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        event = $Event
    }
    foreach ($Key in $Data.Keys) { $Record[$Key] = $Data[$Key] }
    ($Record | ConvertTo-Json -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

function Test-RecordingReady {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    if (((Get-Date) - $File.LastWriteTime).TotalMinutes -lt $MinimumFileAgeMinutes) {
        return $false
    }

    try {
        $Stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        $Stream.Dispose()
        return $true
    }
    catch [System.IO.IOException] {
        return $false
    }
}

$LockStream = $null
try {
    try {
        $LockStream = [System.IO.File]::Open(
            $LockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        Write-Output 'Ya existe otra sincronización en ejecución; esta corrida se omite.'
        exit 0
    }

    Get-ChildItem -Path $LogDirectory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force

    $Files = @(Get-ChildItem -Path $SourceDirectory -Filter '*.avi' -File -Recurse)
    $TotalBytes = [int64](($Files | Measure-Object -Property Length -Sum).Sum)
    $NotReady = @($Files | Where-Object { -not (Test-RecordingReady -File $_) })

    if ($Files.Count -eq 0) {
        Write-UploadLog -Level 'INFO' -Event 'NO_FILES' -Data @{
            sourceDirectory = $SourceDirectory
        }
        Write-Output 'No hay archivos AVI para sincronizar.'
        exit 0
    }

    if ($NotReady.Count -gt 0) {
        Write-UploadLog -Level 'WARN' -Event 'DEFERRED_INCOMPLETE_FILES' -Data @{
            totalFiles = $Files.Count
            notReadyFiles = $NotReady.Count
            minimumFileAgeMinutes = $MinimumFileAgeMinutes
        }
        Write-Warning "$($NotReady.Count) archivo(s) están abiertos o son demasiado recientes. No se subió ningún archivo; la próxima corrida reintentará."
        exit 0
    }

    $env:AWS_RETRY_MODE = 'standard'
    $env:AWS_MAX_ATTEMPTS = '5'
    $Arguments = @(
        's3', 'sync', $SourceDirectory, $Destination,
        '--profile', $Profile,
        '--region', $Region,
        '--exclude', '*',
        '--include', '*.avi',
        '--no-follow-symlinks',
        '--no-progress'
    )
    if ($DryRun) { $Arguments += '--dryrun' }

    Write-UploadLog -Level 'INFO' -Event 'SYNC_STARTED' -Data @{
        sourceDirectory = $SourceDirectory
        destination = $Destination
        eligibleFiles = $Files.Count
        eligibleBytes = $TotalBytes
        dryRun = [bool]$DryRun
    }

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $AwsOutput = @(& aws @Arguments 2>&1)
    $AwsExitCode = $LASTEXITCODE
    $Stopwatch.Stop()

    foreach ($Line in $AwsOutput) { Write-Output $Line }
    $UploadOperations = @($AwsOutput | Where-Object { "$_" -match '^upload:' }).Count
    $Level = if ($AwsExitCode -eq 0) { 'INFO' } else { 'ERROR' }
    $Event = if ($AwsExitCode -eq 0) { 'SYNC_COMPLETED' } else { 'SYNC_FAILED' }
    Write-UploadLog -Level $Level -Event $Event -Data @{
        awsExitCode = $AwsExitCode
        elapsedSeconds = [Math]::Round($Stopwatch.Elapsed.TotalSeconds, 3)
        eligibleFiles = $Files.Count
        eligibleBytes = $TotalBytes
        uploadOperations = $UploadOperations
        dryRun = [bool]$DryRun
    }

    if ($AwsExitCode -ne 0) {
        throw "aws s3 sync falló con código $AwsExitCode. La próxima ejecución reintentará el backlog."
    }

    Write-Output "Sincronización completada. Operaciones upload: $UploadOperations."
}
finally {
    if ($null -ne $LockStream) { $LockStream.Dispose() }
}
