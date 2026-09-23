# Forgejo on Dokploy

This repository is a production Compose stack for Forgejo 15 LTS. It runs
Git, OpenID Connect login, Actions, and the built-in package and container
registry. PostgreSQL and Valkey (Redis protocol) are in the stack. Mail and
S3 stay outside it.

Forgejo is the forge to run here. It matches Gitea on the features this
stack needs, and the 15.0 line is supported until July 15, 2027. Pick Gitea
only when you need the MIT license or a Gitea Ltd contract. The swap is the
image `docker.gitea.com/gitea:1.27.3-rootless`, the `GITEA__` environment
prefix, and `act_runner` in place of `forgejo-runner`.

## What you get

The web UI, HTTPS Git, packages, and the container registry share
`git.$HOST`. SSH clones use `ssh.$HOST` on port 22. The clone URL looks like
`ssh://git@ssh.example.com/org/repo.git`.

Anonymous visitors get the login page. Local self-signup is off. A local
admin account exists for break-glass access. Everyone else signs in through
your existing identity provider.

S3 stores attachments, LFS, avatars, repo archives, package blobs, Actions
logs, and Actions artifacts. Git repositories and the SSH host key stay on
the `forgejo-data` volume. Forgejo has no S3 backend for Git data.

## Before you deploy

Do these on the Dokploy server, from an SSH session you keep open until a
second session works.

1. Install `ufw-docker`. Docker publishes ports in iptables and skips UFW.
   Without that package, every published container port is public.
2. Move host OpenSSH off port 22. Add a second port first, or move the
   existing one. Use keys only, and disable root login. Confirm a new
   session before you close the old one. One public IP cannot serve host
   SSH and Forgejo SSH on port 22 at the same time. A second public IP is
   the other option: publish `"<git-ip>:22:2222"` and leave host SSH on the
   first address.
3. Allow public TCP 22, 80, and 443. Limit the admin SSH port to your IP
   when that IP is stable. Leave Dokploy's UI on its existing HTTPS domain.
4. Create DNS `A` and `AAAA` records for `git.$HOST` and `ssh.$HOST`. Leave
   `ssh.$HOST` unproxied. An HTTP proxy in front of SSH drops the
   connection.
5. Create the S3 bucket. Turn on versioning there. This stack does not run
   MinIO.
6. Create a confidential OIDC client. The redirect URI is
   `https://git.$HOST/user/oauth2/oidc/callback`. Grant `openid`, `email`,
   `profile`, and the provider's groups scope. Send a verified `email`,
   `preferred_username`, and a group list. Put humans who may use the forge
   in a group such as `forgejo-users`, and admins in `forgejo-admins`.
7. Keep NTP on. Expired or not-yet-valid tokens fail when the clock drifts.

## Configure

Deploy this repository as a Dokploy Compose application. Pasting
`docker-compose.yml` alone leaves `./config` and `./scripts` missing.

Dokploy writes the Environment tab to `.env` next to the Compose file. It
does not inject those variables unless the file references them. Fill every
key from `.env.example`.

Generate the four Forgejo secrets once, and store them with the rest of the
environment. Restoring a database with a different `SECRET_KEY` loses
encrypted columns, including two-factor secrets.

```bash
docker run --rm codeberg.org/forgejo/forgejo:15-rootless \
  forgejo generate secret SECRET_KEY
```

Run the same command for `INTERNAL_TOKEN`, `LFS_JWT_SECRET`, and
`JWT_SECRET`. Put the JWT value in `OAUTH2_JWT_SECRET`.

Create the runner secret with `openssl rand -hex 20`. A token copied from
the Forgejo UI is a different credential and does not work here.

Passwords that land in a Redis URL (`POSTGRES_PASSWORD` is not one of them;
`REDIS_PASSWORD` is) must match `[A-Za-z0-9]`.

Set `S3_CHECKSUM_ALGORITHM=default` for AWS, MinIO, and Garage. Set it to
`md5` for Cloudflare R2 and Backblaze B2.

Set `TRUSTED_PROXIES` to loopback plus the `dokploy-network` subnet:

```bash
docker network inspect dokploy-network \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

In the Dokploy Domains tab, add `git.$HOST` on service `server`, container
port `3000`, with HTTPS on. Do not add a domain for the registry or for
`ssh.$HOST`. The registry is `https://git.$HOST/v2/` on the same process.
SSH is the host port mapping `22:2222`.

If Codeberg is unreachable from the server, change the Forgejo image to
`data.forgejo.org/forgejo/forgejo:15-rootless`.

## What each service does

| Service | Role |
| --- | --- |
| `server` | Forgejo. HTTP on 3000, SSH on 2222 inside the container. |
| `postgres` | PostgreSQL 17. No published port. |
| `redis` | Valkey 8, using the Redis protocol. No published port. |
| `bootstrap` | Creates the admin, the OIDC source, and the runner record. Exits. |
| `docker` | Docker-in-Docker with TLS, for Actions jobs. Privileged. |
| `runner` | Forgejo Runner 13. Polls `https://git.$HOST/`. |
| `runner-init` | Gives the runner volume to uid 1001. |

`postgres` and `redis` sit on an internal network. The runner and DinD
cannot resolve them. The runner does not mount the host Docker socket.

Actions jobs use `runs-on: docker`. One job runs at a time
(`capacity: 1`). Fork pull requests stay on Forgejo's default approval
rule. DinD is privileged, so treat workflow code as trusted.

## Sign-in

The login button appears only after `bootstrap` creates the `oidc`
authentication source. The first login for a person in `forgejo-users`
creates their account. A person outside that group is rejected.
`forgejo-admins` becomes a Forgejo admin. The account name comes from the
`preferred_username` claim. Forgejo 15 selects that claim with the
`nickname` setting.

The local password form stays available for `BOOTSTRAP_ADMIN_USER`. After
an OIDC admin has signed in, you can set
`FORGEJO__service__ENABLE_INTERNAL_SIGNIN=false` and redeploy. Set it back
to `true` from the Dokploy environment if the identity provider is down.

Session cookies use `SameSite=lax`. `strict` breaks the OIDC redirect.

## Registries

Container images:

```text
docker login git.example.com
docker push git.example.com/OWNER/IMAGE:TAG
```

Replace the host with `GIT_DOMAIN`. Package metadata is in PostgreSQL. The
blobs are in the S3 bucket under `packages/`.

A tag push that publishes an image:

```yaml
on:
  push:
    tags: ["v*"]
jobs:
  publish:
    runs-on: docker
    permissions:
      contents: read
      packages: write
    steps:
      - uses: https://data.forgejo.org/actions/checkout@v4
      - uses: https://data.forgejo.org/docker/login-action@v3
        with:
          registry: git.example.com
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: https://data.forgejo.org/docker/build-push-action@v6
        with:
          push: true
          tags: git.example.com/OWNER/IMAGE:latest
```

`secrets.GITHUB_TOKEN` is the token Forgejo Actions injects. Workflows live
in `.forgejo/workflows/` inside each repository.

Other packages use the same host:

| Ecosystem | Registry URL |
| --- | --- |
| npm | `https://git.example.com/api/packages/OWNER/npm/` |
| PyPI | `https://git.example.com/api/packages/OWNER/pypi` |
| Maven | `https://git.example.com/api/packages/OWNER/maven` |
| NuGet | `https://git.example.com/api/packages/OWNER/nuget/index.json` |
| Helm | `https://git.example.com/api/packages/OWNER/helm` |
| Cargo | `https://git.example.com/api/packages/OWNER/cargo` |
| Composer | `https://git.example.com/api/packages/OWNER/composer` |

Create a personal access token with package read or write for clients
outside Actions. LFS objects land in the bucket under `lfs/`.

## Backups

Keep three copies.

1. Dokploy Volume Backups of `postgres-data`, `forgejo-data`, and
   `runner-data`, sent to a bucket that is not the Forgejo object bucket.
2. A logical dump. A volume snapshot of a live PostgreSQL directory can
   restore as a corrupt cluster. Schedule this against the `data` network:

   ```bash
   docker compose exec -T postgres \
     pg_dump -U forgejo -Fc forgejo > forgejo.dump
   ```

3. Versioning and a lifecycle rule on the object bucket. That bucket is the
   only copy of LFS objects and package blobs.

Restore `postgres-data` and `forgejo-data` from the same window, and reuse
the same `SECRET_KEY`, `INTERNAL_TOKEN`, `LFS_JWT_SECRET`, and
`OAUTH2_JWT_SECRET`. The SSH host key is inside `forgejo-data`. Restoring
it avoids a `known_hosts` change.

Practice the restore on empty volumes: load the dump, start the stack,
clone a repository, and pull an image.

## Check the deploy

Run these against the Dokploy host after the first deploy.

1. Open `https://git.$HOST`. Anonymous visitors land on the login page, and
   the certificate is valid.
2. Sign in with OIDC as an admin-group user and as a user who lacks
   `forgejo-users`. The second login is rejected.
3. Sign in as the local admin.
4. Confirm the registration form is gone.
5. Run `ssh -T git@ssh.$HOST`. The reply is Forgejo's greeting, not a host
   shell.
6. Clone and push over SSH and over HTTPS with a personal access token.
   Push an LFS object and confirm it is in the bucket under `lfs/`.
7. Push a container image to `git.$HOST/OWNER/IMAGE:TAG` and pull it back.
   Upload one npm or PyPI package and install it.
8. Run the publish workflow. The job uses the `docker` label, and the new
   image pulls.
9. Confirm `postgres` and `redis` have no host port.
10. Watch a repository and confirm the notification mail arrives.
11. Restart the stack. The SSH host key is unchanged, and the runner is
    online without a new secret.

A 4 vCPU, 8 GB server is the starting size when CI builds images on this
box. Use 2 vCPU and 4 GB when builds run somewhere else.

## Operations notes

`bootstrap` is idempotent. A later deploy skips the admin user and the OIDC
source when they already exist, and refreshes the runner registration
without wiping its labels.

`environment-to-ini` writes variables into `app.ini` on each start. It
cannot delete a key that is already in the file. Changing a value in
Dokploy and redeploying updates it. Removing a variable does not.

Keep `SECRET_KEY` stable for the life of the instance.

Logs go to the console, capped at 10 MB times five files, so Dokploy's log
view stays the place you read them.

Group-to-team mapping is left unset until the first organization exists.
Add it on the `oidc` source with `--group-team-map` when you want it.
