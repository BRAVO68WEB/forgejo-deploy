#!/bin/sh
# Idempotent first-boot tasks. Safe to run on every deploy.
# The image entrypoint applies FORGEJO__* to app.ini, then execs this script.

set -eu

FORGEJO="${FORGEJO_BIN:-forgejo}"
CONFIG="${GITEA_APP_INI:-/var/lib/gitea/custom/conf/app.ini}"

if [ ! -f "$CONFIG" ]; then
  echo "bootstrap: missing $CONFIG. The server container has not written app.ini yet." >&2
  exit 1
fi

case "${RUNNER_SECRET:-}" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ;;
  *)
    echo "bootstrap: RUNNER_SECRET must be 40 hex characters (openssl rand -hex 20)." >&2
    exit 1
    ;;
esac

for name in \
  BOOTSTRAP_ADMIN_USER BOOTSTRAP_ADMIN_PASSWORD BOOTSTRAP_ADMIN_EMAIL \
  OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DISCOVERY_URL \
  OIDC_REQUIRED_CLAIM OIDC_REQUIRED_VALUE OIDC_ADMIN_GROUP
do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "bootstrap: $name is empty." >&2
    exit 1
  fi
done

if ! "$FORGEJO" admin user list --config "$CONFIG" | awk 'NR>1 {print $2}' | grep -qx "$BOOTSTRAP_ADMIN_USER"; then
  "$FORGEJO" admin user create \
    --config "$CONFIG" \
    --admin \
    --username "$BOOTSTRAP_ADMIN_USER" \
    --password "$BOOTSTRAP_ADMIN_PASSWORD" \
    --email "$BOOTSTRAP_ADMIN_EMAIL" \
    --must-change-password=false
  echo "bootstrap: created admin $BOOTSTRAP_ADMIN_USER"
else
  echo "bootstrap: admin $BOOTSTRAP_ADMIN_USER already exists"
fi

if "$FORGEJO" admin auth list --config "$CONFIG" | awk 'NR>1 {print $2}' | grep -qx oidc; then
  echo "bootstrap: OIDC source oidc already exists"
else
  set -- \
    --config "$CONFIG" \
    --name oidc \
    --provider openidConnect \
    --key "$OIDC_CLIENT_ID" \
    --secret "$OIDC_CLIENT_SECRET" \
    --auto-discover-url "$OIDC_DISCOVERY_URL" \
    --scopes openid \
    --scopes email \
    --scopes profile \
    --group-claim-name groups \
    --required-claim-name "$OIDC_REQUIRED_CLAIM" \
    --required-claim-value "$OIDC_REQUIRED_VALUE" \
    --admin-group "$OIDC_ADMIN_GROUP"
  if [ -n "${OIDC_GROUPS_SCOPE:-}" ]; then
    set -- "$@" --scopes "$OIDC_GROUPS_SCOPE"
  fi
  "$FORGEJO" admin auth add-oauth "$@"
  echo "bootstrap: added OIDC source oidc"
fi

# Passing --labels again sets the same label. --keep-labels cannot be
# combined with --labels, and omitting --labels clears them.
"$FORGEJO" forgejo-cli actions register \
  --config "$CONFIG" \
  --secret "$RUNNER_SECRET" \
  --name ci \
  --labels docker
echo "bootstrap: runner ci registered"
