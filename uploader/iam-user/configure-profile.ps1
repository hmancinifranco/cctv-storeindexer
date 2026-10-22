# Configure AWS CLI profiles for the simplified PoC uploader.
# The source IAM user's access key is entered interactively and receives only
# sts:AssumeRole permission. Uploads run through the temporary-role profile.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^arn:aws[a-zA-Z-]*:iam::\d{12}:role/.+$')]
    [string]$RoleArn,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$VideoBucketName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9!_.*''()/-]+$')]
    [string]$IngestPrefix = 'videos',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[a-z]{2}(-gov)?-[a-z]+-\d$')]
    [string]$Region = 'us-east-1',

    [Parameter(Mandatory = $false)]
    [string]$SourceProfile = 'cctv-uploader-source',

    [Parameter(Mandatory = $false)]
    [string]$UploaderProfile = 'cctv-uploader'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'AWS CLI v2 no está instalado o no está en PATH.'
}

Write-Host "Configurando access key del usuario técnico en '$SourceProfile'."
Write-Host 'AWS CLI solicitará Access Key ID y Secret Access Key de forma interactiva.'
& aws configure --profile $SourceProfile
if ($LASTEXITCODE -ne 0) { throw 'aws configure falló.' }

& aws configure set role_arn $RoleArn --profile $UploaderProfile
& aws configure set source_profile $SourceProfile --profile $UploaderProfile
& aws configure set role_session_name cctv-windows-uploader --profile $UploaderProfile
& aws configure set region $Region --profile $UploaderProfile
& aws configure set output json --profile $UploaderProfile
if ($LASTEXITCODE -ne 0) { throw 'No se pudo configurar el perfil del role.' }

$CredentialsPath = Join-Path $HOME '.aws\credentials'
if (Test-Path $CredentialsPath) {
    $WindowsPrincipal = (& whoami.exe).Trim()
    if (-not $WindowsPrincipal) { throw 'No se pudo resolver la identidad Windows actual.' }
    & icacls.exe $CredentialsPath /inheritance:r /grant:r "${WindowsPrincipal}:(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudieron restringir las ACL de $CredentialsPath."
    }
}

Write-Host 'Verificando que el perfil final obtiene una sesión temporal...'
& aws sts get-caller-identity --profile $UploaderProfile --region $Region
if ($LASTEXITCODE -ne 0) { throw 'El usuario técnico no pudo asumir el uploader role.' }

Write-Host 'Verificando que el perfil source no tenga acceso directo a S3...'
& aws s3api list-objects-v2 --bucket $VideoBucketName --prefix "$IngestPrefix/" --max-keys 1 --profile $SourceProfile --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    throw 'El usuario técnico tiene acceso S3 directo. Retire esas políticas antes de continuar.'
}

Write-Host 'Verificando listado acotado mediante el role temporal...'
& aws s3api list-objects-v2 --bucket $VideoBucketName --prefix "$IngestPrefix/" --max-keys 1 --profile $UploaderProfile --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'El uploader role no puede listar el prefijo aprobado.' }

Write-Host "OK: use --profile $UploaderProfile para aws s3 sync."
Write-Host "OK: $SourceProfile no tiene acceso S3 directo."
Write-Host "No use --profile $SourceProfile para transferencias."
