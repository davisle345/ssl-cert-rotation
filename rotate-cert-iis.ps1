<#
.SYNOPSIS
    Rotates the SSL/TLS certificate for all HTTPS bindings in IIS.

.DESCRIPTION
    Downloads a PFX from S3, imports it so the private key lands in the LocalMachine
    context, verifies the key linkage, then re-points every HTTPS binding to the new
    thumbprint. Cleans up the local PFX afterward so no private key is left on disk.

    All values in the config block are placeholders — replace them with your own.

.NOTES
    Requires: Windows Server + IIS (WebAdministration module), AWS CLI configured.
#>

Import-Module WebAdministration

# === Config (replace with your values) ===
$s3Uri        = "s3://your-cert-backup-bucket/cert/cert.pfx"
$workDir      = "C:\certs\work"
$pfxPath      = Join-Path $workDir "cert.pfx"
$thumbprint   = "YOUR_NEW_THUMBPRINT_HERE"
$friendlyName = "wildcard-2026"
$store        = "WebHosting"
$awsRegion    = "us-east-1"

# === Step 1: Prompt for PFX password (kept out of script & history) ===
$securePw    = Read-Host "Enter PFX password" -AsSecureString
$bstr        = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw)
$pfxPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# === Step 2: Download PFX from S3 ===
Write-Host "`n=== Downloading PFX from S3 ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
aws s3 cp $s3Uri $pfxPath --region $awsRegion
if (-not (Test-Path $pfxPath)) { throw "S3 download failed. File not found at $pfxPath" }

# === Step 3: Remove stale cert for a clean private-key linkage ===
$existing = Get-ChildItem "Cert:\LocalMachine\$store\$thumbprint" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing cert from $store store" -ForegroundColor Yellow
    $existing | Remove-Item
}

# === Step 4: Import so the private key lands in LocalMachine ===
Write-Host "`n=== Importing PFX ===" -ForegroundColor Cyan
& certutil -f -p $pfxPassword -importpfx $store $pfxPath 2>&1 | ForEach-Object { Write-Host "  $_" }

# Clear the password from memory ASAP
$pfxPassword = $null
[GC]::Collect()

if ($LASTEXITCODE -ne 0) { throw "certutil import failed (exit $LASTEXITCODE). Aborting." }

# === Step 5: Set friendly name ===
$cert = Get-Item "Cert:\LocalMachine\$store\$thumbprint" -ErrorAction Stop
$cert.FriendlyName = $friendlyName
Write-Host "Friendly name set to '$friendlyName'" -ForegroundColor Green

# === Step 6: Verify private key BEFORE touching bindings ===
$cert = Get-Item "Cert:\LocalMachine\$store\$thumbprint"
Write-Host "`nCert state:" -ForegroundColor Cyan
Write-Host "  Subject:        $($cert.Subject)"
Write-Host "  NotAfter:       $($cert.NotAfter)"
Write-Host "  HasPrivateKey:  $($cert.HasPrivateKey)"
if (-not $cert.HasPrivateKey) { throw "Imported cert is missing its private key. Aborting." }

# === Step 7: Re-point all HTTPS bindings ===
Write-Host "`n=== Updating HTTPS bindings ===" -ForegroundColor Yellow
Get-WebBinding | Where-Object { $_.protocol -eq "https" } | ForEach-Object {
    $binding = $_
    Write-Host "Updating: $($binding.bindingInformation)"
    try {
        $binding.AddSslCertificate($thumbprint, $store)
        Write-Host "  Done" -ForegroundColor Green
    } catch {
        Write-Host "  Failed: $_" -ForegroundColor Red
    }
}

# === Step 8: Verify final binding state ===
Write-Host "`n=== Final binding state ===" -ForegroundColor Cyan
Get-WebBinding | Where-Object { $_.protocol -eq "https" } |
    Select-Object @{n='Binding';e={$_.bindingInformation}},
                  @{n='Thumbprint';e={$_.certificateHash}},
                  @{n='Store';e={$_.certificateStoreName}} |
    Format-Table -AutoSize

# === Step 9: Clean up — no private key left on disk ===
Write-Host "`n=== Cleaning up ===" -ForegroundColor Cyan
Remove-Item $pfxPath -Force
Write-Host "Removed $pfxPath" -ForegroundColor Green

Write-Host "`nDone." -ForegroundColor Green
