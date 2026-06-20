# Nginx Certificate Rotation Runbook (Linux)

The equivalent rotation flow for Nginx-hosted sites.

## 1. Find where the certs are referenced

```bash
sudo grep -rE "ssl_certificate|ssl_certificate_key" /etc/nginx/
```

This shows every config block pointing at a cert or key, so you know exactly what to replace.

## 2. Get the new cert onto the server

Any of these work, depending on the server's access:

- **From S3** (if the instance has an IAM role): `aws s3 cp s3://your-cert-backup-bucket/cert/cert.pem /etc/nginx/ssl/`
- **SCP** with a key pair: `scp -i key.pem cert.pem user@server:/etc/nginx/ssl/`
- Manual copy/paste into the file on the server

## 3. Replace the cert and key, then lock down the key

Replace the `.crt`/`.pem` and `.key` files, then restrict permissions on the private key:

```bash
sudo chmod 600 /etc/nginx/ssl/example.key
```

## 4. Test the config before applying

```bash
sudo nginx -t
```

Never reload without this — a bad config can take the server down.

## 5. Reload to apply

```bash
sudo systemctl reload nginx
```

`reload` applies the new certs without dropping active connections (unlike `restart`).

## Quick checklist

- [ ] Located all cert references with `grep`
- [ ] New cert + key in place
- [ ] Private key permissions set to `600`
- [ ] `nginx -t` passes
- [ ] `systemctl reload nginx`
- [ ] Verified the new cert is being served (`openssl s_client -connect host:443`)
