# SSL/TLS Certificate Rotation Automation

Automates SSL/TLS certificate **deployment** on IIS with PowerShell — pulls a PFX from S3, imports it
correctly on Windows with secure key handling, re-points every HTTPS binding in one pass, and cleans
up so no private key is left on disk. Includes a manual runbook for the equivalent steps on Nginx/Linux.

> All bucket names, thumbprints, domains, and paths in this repo are placeholders.

## Why

Certificate renewal across web servers was a manual, error-prone chore — import the PFX by hand,
find every HTTPS binding in IIS, re-point each one, and hope nothing was missed. A single skipped
binding meant a site serving an expired cert. This script automates that deployment step and removes
the common failure modes.

**Scope:** this automates the *deployment* stage of certificate renewal — importing the new cert and
re-pointing all HTTPS bindings. The earlier stages (CSR generation, issuance through a commercial CA
such as Sectigo or DigiCert, and DNS-based domain validation via the registrar or Route 53) are done
separately; this picks up once the issued PFX is in S3.

## What it does (IIS)

1. **Prompts for the PFX password** at runtime — no echo, never stored in the script or shell history.
2. **Downloads the PFX from S3** to a working directory.
3. **Removes any stale cert** with the same thumbprint for a clean private-key linkage.
4. **Imports via `certutil`** so the private key lands in the LocalMachine context.
5. **Sets a friendly name** for easy identification in the cert store.
6. **Verifies `HasPrivateKey = True`** *before* touching any binding — bad imports fail safe.
7. **Re-points every HTTPS binding** to the new thumbprint in a single pass.
8. **Deletes the local PFX** so the private key never lingers on disk.

## The tricky bit: `0x80070520` on import

Newer OpenSSL defaults to AES-256 when exporting a PFX, which older Windows Server builds can't
decrypt — the import fails and looks like a wrong password even when it's correct. Export with the
`-legacy` flag (older 3DES/SHA-1 algorithms the server understands), then re-import with `certutil`:

```bash
openssl pkcs12 -export -out cert-legacy.pfx \
  -inkey example.key \
  -in example_cert.cer \
  -certfile example_intermediate.cer \
  -legacy
```

## Usage

```powershell
# Edit the config block at the top of the script first
.\rotate-cert-iis.ps1
```

You'll be prompted for the PFX password. The script prints the final binding state so you can verify
the rotation succeeded.

## Files

| File | Purpose |
|------|---------|
| `rotate-cert-iis.ps1` | Main IIS rotation script |
| `list-iis-sites.ps1`  | Helper: list IIS sites and their status |
| `docs/nginx-runbook.md` | Equivalent rotation steps for Nginx on Linux |

## Requirements

- Windows Server with IIS and the `WebAdministration` PowerShell module
- AWS CLI configured with read access to the cert bucket
- OpenSSL (for generating a legacy-compatible PFX)

## Security notes

- The PFX password is prompted at runtime and cleared from memory after use.
- The downloaded PFX is deleted at the end of the run.
- Never commit a real `.pfx`, `.key`, `.cer`, or thumbprint — see `.gitignore`.

## License

MIT — see [LICENSE](LICENSE).
