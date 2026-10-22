# Parse every project PowerShell script and fail on syntax errors.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Path = (Join-Path $PSScriptRoot '..\uploader\iam-user')
)

$ErrorActionPreference = 'Stop'
$Scripts = @(Get-ChildItem -Path $Path -Filter '*.ps1' -File)
if ($Scripts.Count -eq 0) {
    throw "No se encontraron scripts PowerShell en $Path."
}

$Failed = $false
foreach ($Script in $Scripts) {
    $Tokens = $null
    $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Script.FullName,
        [ref]$Tokens,
        [ref]$Errors
    ) | Out-Null

    if ($Errors.Count -gt 0) {
        $Failed = $true
        Write-Error ("{0}: {1}" -f $Script.Name, ($Errors | Out-String))
    }
    else {
        Write-Host ("PARSE_OK {0}" -f $Script.Name)
    }
}

if ($Failed) { exit 1 }
Write-Host "PowerShell syntax validation passed: $($Scripts.Count) script(s)."
