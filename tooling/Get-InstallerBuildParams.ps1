#Requires -Version 5.1
<#
.SYNOPSIS
  Extract installer build parameters from a mirrored OpenShift release image.

.DESCRIPTION
  Runs oc image extract against the mirrored release image (no quay.io).
  Reads release-manifests and writes installer-build-params.json for vw-build.sh.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseImageMirror,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath = "installer-build-params.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ReleaseMetadataValue {
    param([string]$Content, [string]$Key)
    if ($Content -match "(?m)^$Key=(.+)$") {
        return $Matches[1].Trim()
    }
    return $null
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("ocp-release-" + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    & oc image extract $ReleaseImageMirror --path "$tempDir`:/" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "oc image extract failed for $ReleaseImageMirror"
    }

    $metaPath = Join-Path $tempDir "release-manifests/release-metadata"
    $refsPath = Join-Path $tempDir "release-manifests/image-references"
    if (-not (Test-Path $metaPath)) { throw "missing release-metadata in extracted image" }
    if (-not (Test-Path $refsPath)) { throw "missing image-references in extracted image" }

    $meta = Get-Content -Raw $metaPath
    $version = Get-ReleaseMetadataValue -Content $meta -Key "version"
    if (-not $version) { throw "could not read version from release-metadata" }

    $refsYaml = Get-Content -Raw $refsPath
    $installerLine = ($refsYaml -split "`n") | Where-Object { $_ -match '^\s*name:\s*installer\s*$' } | Select-Object -First 1
    if (-not $installerLine) { throw "installer entry not found in image-references" }

    # Parse following lines for reference (simple YAML scan)
    $lines = $refsYaml -split "`n"
    $installerRef = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*name:\s*installer\s*$') {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 8, $lines.Count); $j++) {
                if ($lines[$j] -match '^\s*reference:\s*(.+)$') {
                    $installerRef = $Matches[1].Trim()
                    break
                }
            }
            break
        }
    }
    if (-not $installerRef) { throw "installer reference not found" }

    # release-metadata commit fields (installer source)
    $installerCommit = Get-ReleaseMetadataValue -Content $meta -Key "Metadata:installer.git.commit"
    if (-not $installerCommit) {
        $installerCommit = Get-ReleaseMetadataValue -Content $meta -Key "Metadata:installer-commit"
    }
    if (-not $installerCommit -or $installerCommit.Length -ne 40) {
        throw "could not read 40-char installer git commit from release-metadata"
    }

    $releaseSource = Get-ReleaseMetadataValue -Content $meta -Key "release.image"
    if (-not $releaseSource) { $releaseSource = $ReleaseImageMirror }

    # Mirror paths — caller must set if different from defaults embedded in pull specs
    $installerMirror = $installerRef
    if ($installerMirror -notmatch '@sha256:') {
        Write-Warning "installer reference is not digest-pinned: $installerMirror"
    }

    $payload = [ordered]@{
        schemaVersion        = 1
        ocpVersion           = $version
        releaseImageSource   = $releaseSource
        releaseImageMirror   = $ReleaseImageMirror
        installerSourceRepo  = "https://github.com/openshift/installer"
        installerCommit      = $installerCommit
        installerImageSource = $installerRef
        installerImageMirror = $installerMirror
    }

    $json = $payload | ConvertTo-Json -Depth 4
    Set-Content -Path $OutputPath -Value $json -Encoding UTF8
    Write-Host "Wrote $OutputPath for OpenShift $version (installer commit $installerCommit)"
}
finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}
