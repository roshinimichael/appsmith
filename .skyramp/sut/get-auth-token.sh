#!/usr/bin/env bash
# Creates the initial Appsmith admin user (idempotent) and returns the session cookie
# for use as an auth credential in Skyramp Testbot API tests.
set -euo pipefail

APPSMITH_URL="http://localhost"
ADMIN_EMAIL="appsmith@appsmith.com"
ADMIN_PASSWORD="admin123"
COOKIE_JAR="$(mktemp /tmp/appsmith-cookies.XXXXXX.txt)"

# Create the first admin user (succeeds on first boot, returns 400/409 on re-run — both are fine)
curl -sf -X POST "${APPSMITH_URL}/api/v1/users/super" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"Admin\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"allowCollectingAnonymousData\":false,\"signupForNewsletter\":false}" \
  > /dev/null 2>&1 || true

# Log in and capture the SESSION cookie
curl -sf -c "${COOKIE_JAR}" -X POST "${APPSMITH_URL}/api/v1/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_EMAIL}&password=${ADMIN_PASSWORD}" \
  > /dev/null

# Print the SESSION cookie value (Testbot injects this via the Cookie header per workspace.yml authType=cookie)
SESSION_VALUE=$(grep -i SESSION "${COOKIE_JAR}" | awk '{print $NF}' | head -1)
rm -f "${COOKIE_JAR}"

if [[ -z "${SESSION_VALUE}" ]]; then
  echo "ERROR: Could not retrieve SESSION cookie from Appsmith" >&2
  exit 1
fi

echo "SESSION=${SESSION_VALUE}"
