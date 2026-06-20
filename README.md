# Automated SSL/TLS Certificate Rotation

**Stack:** PowerShell · AWS S3 · IIS · Nginx · OpenSSL

---

## The problem

Certificate renewal across our web servers was a manual, error-prone chore. Each rotation meant
importing a new PFX by hand, hunting down every HTTPS binding in IIS, re-pointing each one, and
hoping nothing was missed. A single skipped binding meant a site serving an expired cert. On top of
that, an OpenSSL/Windows encryption mismatch caused private-key import failures that were easy to
misdiagnose as "wrong password."

## What I built

A PowerShell pipeline that handles the full rotation on Windows/IIS end to end: it pulls the PFX from
S3, imports it so the private key lands correctly, sets a friendly name, verifies the key linkage
*before* touching anything, re-points every HTTPS binding, prints the final state for verification,
and deletes the local PFX so the private key never lingers on disk. I documented a parallel runbook
for Nginx on Linux.

- **Secure by default** — the PFX password is prompted at runtime (no echo, never stored in the
  script or shell history) and cleared from memory right after use.
- **Verify before acting** — confirms `HasPrivateKey = True` before updating any binding, so a bad
  import fails safe instead of breaking live sites.
- **No secrets left behind** — the downloaded PFX is removed at the end of the run.
- **Idempotent binding updates** — every HTTPS binding is re-pointed to the new thumbprint in one pass.

## The tricky bit: the 0x80070520 key import failure

Newer OpenSSL defaults to AES-256 when exporting a PFX, which older Windows Server builds can't
decrypt — so the import fails and looks like a wrong password even when it's correct. The fix was to
export the PFX with OpenSSL's `-legacy` flag (older 3DES/SHA-1 algorithms the server understands),
then re-import with `certutil` so the private key lands in the LocalMachine context. That's what
cleared the orphaned-key error.

```bash
# Export a legacy-compatible PFX (run on Linux)
openssl pkcs12 -export -out cert-legacy.pfx \
  -inkey example.key \
  -in example_cert.cer \
  -certfile example_intermediate.cer \
  -legacy
```

## Core script (IIS)

> Sanitized — bucket names, thumbprints, and domains are placeholders.

```powershell
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
$securePw = Read-Host "Enter PFX password" -AsSecureString
$bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw)
$pfxPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# === Step 2: Download PFX from S3 ===
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
aws s3 cp $s3Uri $pfxPath --region $awsRegion
if (-not (Test-Path $pfxPath)) { throw "S3 download failed: $pfxPath" }

# === Step 3: Remove stale cert for a clean private-key linkage ===
$existing = Get-ChildItem "Cert:\LocalMachine\$store\$thumbprint" -ErrorAction SilentlyContinue
if ($existing) { $existing | Remove-Item }

# === Step 4: Import so the private key lands in LocalMachine ===
& certutil -f -p $pfxPassword -importpfx $store $pfxPath 2>&1 | ForEach-Object { Write-Host "  $_" }
$pfxPassword = $null; [GC]::Collect()
if ($LASTEXITCODE -ne 0) { throw "certutil import failed (exit $LASTEXITCODE)" }

# === Step 5: Set friendly name ===
$cert = Get-Item "Cert:\LocalMachine\$store\$thumbprint" -ErrorAction Stop
$cert.FriendlyName = $friendlyName

# === Step 6: Verify private key BEFORE touching bindings ===
if (-not $cert.HasPrivateKey) { throw "Imported cert missing private key. Aborting." }

# === Step 7: Re-point all HTTPS bindings ===
Get-WebBinding | Where-Object { $_.protocol -eq "https" } | ForEach-Object {
    try {
        $_.AddSslCertificate($thumbprint, $store)
        Write-Host "Updated: $($_.bindingInformation)" -ForegroundColor Green
    } catch {
        Write-Host "Failed: $($_.bindingInformation) - $_" -ForegroundColor Red
    }
}

# === Step 8: Clean up — no private key left on disk ===
Remove-Item $pfxPath -Force
Write-Host "Done." -ForegroundColor Green
```

## Linux / Nginx runbook

The equivalent flow for Nginx-hosted sites:

```bash
# 1. Find where the certs are referenced
sudo grep -rE "ssl_certificate|ssl_certificate_key" /etc/nginx/

# 2. Replace the .crt/.pem and .key files, then lock down the key
sudo chmod 600 /etc/nginx/ssl/example.key

# 3. Test config and reload
sudo nginx -t
sudo systemctl reload nginx
```

## Outcome

- Turned a manual, miss-prone rotation into a single repeatable run across all HTTPS bindings.
- Eliminated the recurring private-key import failure on older Windows servers.
- Kept private keys off disk and passwords out of history — a cleaner security posture.
