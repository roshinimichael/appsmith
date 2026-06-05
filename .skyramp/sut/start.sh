#!/usr/bin/env bash
# Builds all Appsmith components from PR source and starts the full SUT stack.
# Pattern B: called as targetSetupCommand after GHA pre-steps set up Java, Node.js, and DockerHub login.
set -euo pipefail

# The pom.xml targets Java 25 (maven.compiler.source/target=25). Ensure we use JDK 25.
# JAVA_HOME_25_X64 is exported by actions/setup-java; JAVA_HOME on ubuntu-latest defaults
# to a pre-installed Java 17, which cannot compile Java 25 source.
if [ -n "${JAVA_HOME_25_X64:-}" ]; then
  export JAVA_HOME="$JAVA_HOME_25_X64"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# app/client/package.json requires Node >=24. actions/setup-node installs it into
# the hostedtoolcache but the targetSetupCommand subshell may not inherit the updated
# PATH. Find and prepend the Node 24 bin dir if the current default is too old.
if ! node --version 2>/dev/null | grep -qE "^v2[4-9]\.|^v[3-9][0-9]\."; then
  NODE24_BIN="$(ls -d /opt/hostedtoolcache/node/24.*/x64/bin 2>/dev/null | sort -V | tail -1)"
  if [ -n "$NODE24_BIN" ]; then
    export PATH="$NODE24_BIN:$PATH"
    echo "Switched to Node $(node --version) from $NODE24_BIN"
  fi
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Remove any leftover containers from a previous failed attempt so docker run --name doesn't conflict.
docker rm -f appsmith cloud-services test-event-driver sut-redis sut-mongo 2>/dev/null || true

echo "=== [1/10] Build Java server (DskipTests) ==="
if ls "$ROOT"/app/server/dist/server-*.jar 1>/dev/null 2>&1; then
  echo "Pre-built server JAR found in dist/ — skipping Maven build"
else
  cd app/server
  ./build.sh -DskipTests
  cd "$ROOT"
fi

echo "=== [2/10] Build React client ==="
if [ -f "$ROOT/app/client/build/index.html" ]; then
  echo "Pre-built React app found in build/ — skipping yarn build"
else
  cd app/client
  yarn install --immutable
  yarn build
  cd "$ROOT"
fi

echo "=== [3/10] Build RTS ==="
if [ -d "$ROOT/app/client/packages/rts/dist" ] && [ -n "$(ls -A "$ROOT/app/client/packages/rts/dist" 2>/dev/null)" ]; then
  echo "Pre-built RTS found in packages/rts/dist/ — skipping RTS build"
else
  cd app/client/packages/rts
  corepack enable
  yarn install --immutable
  yarn build
  cd "$ROOT"
fi

echo "=== [4/10] Generate info.json and prepare server artifacts ==="
scripts/generate_info_json.sh
scripts/prepare_server_artifacts.sh

echo "=== [5/10] Build Docker image from PR source ==="
docker build -t cicontainer \
  --build-arg "BASE=appsmith/base-ce:release" \
  --build-arg "APPSMITH_CLOUD_SERVICES_BASE_URL=https://release-cs.appsmith.com" \
  .

echo "=== [6/10] Free port 22 for test-event-driver ==="
sudo systemctl stop ssh.socket 2>/dev/null || true
sudo systemctl disable ssh.socket 2>/dev/null || true
sudo /etc/init.d/ssh stop 2>/dev/null || true
sudo pkill -x sshd 2>/dev/null || true
# Wait briefly for the port to release
sleep 2

echo "=== [7/10] Start Redis and MongoDB ==="
docker run -d --name sut-redis -p 6379:6379 redis
docker run -d --name sut-mongo -p 27017:27017 mongo

echo "=== [8/10] Start test-event-driver ==="
mkdir -p ~/git-server/keys
docker run --name test-event-driver -d \
  -p 22:22 -p 5001:5001 -p 3306:3306 \
  -p 5433:5432 -p 28017:27017 -p 25:25 \
  -p 4200:4200 -p 5000:5000 -p 3001:3000 \
  -p 6001:6001 -p 8001:8000 \
  --privileged --pid=host --ipc=host \
  --volume /:/host \
  -v ~/git-server/keys:/git-server/keys \
  "appsmith/test-event-driver:latest"

echo "=== [9/10] Start cloud-services (best-effort — private image may be unavailable) ==="
CLOUD_SERVICES_SIGNATURE_URL=http://host.docker.internal:5001
if docker pull appsmith/cloud-services:release 2>/dev/null; then
  docker run --name cloud-services -d \
    -p 8000:80 -p 8090:8090 \
    --privileged --pid=host --ipc=host \
    --add-host=host.docker.internal:host-gateway \
    -e APPSMITH_CLOUD_SERVICES_MONGODB_URI=mongodb://host.docker.internal:27017 \
    -e APPSMITH_CLOUD_SERVICES_MONGODB_DATABASE=cs \
    -e APPSMITH_CLOUD_SERVICES_MONGODB_AUTH_DATABASE=admin \
    -e APPSMITH_REDIS_URL=redis://host.docker.internal:6379/ \
    -e APPSMITH_APPS_API_KEY=dummy-api-key \
    -e APPSMITH_REMOTE_API_KEY=dummy-api-key \
    -e APPSMITH_GITHUB_API_KEY=dummy-appsmith-gh-api-key \
    -e APPSMITH_JWT_SECRET=appsmith-cloud-services-jwt-secret-dummy-key \
    -e APPSMITH_ENCRYPTION_SALT=encryption-salt \
    -e APPSMITH_ENCRYPTION_PASSWORD=encryption-password \
    -e APPSMITH_CUSTOMER_PORTAL_URL=https://dev.appsmith.com \
    -e APPSMITH_CLOUD_SERVICES_BASE_URL=https://cs-dev.appsmith.com \
    -e AUTH0_ISSUER_URL=https://login.release-customer.appsmith.com/ \
    -e AUTH0_CLIENT_ID=dummy-client-id \
    -e AUTH0_CLIENT_SECRET=dummy-secret-id \
    -e AUTH0_AUDIENCE_URL=https://login.local-customer.appsmith.com/ \
    -e CLOUDSERVICES_URL=cs-dev.appsmith.com \
    -e CUSTOMER_URL=dev.appsmith.com \
    -e ENTERPRISE_USER_NAME=ent-user@appsmith.com \
    -e ENTERPRISE_USER_PASSWORD=ent_user_password \
    -e ENTERPRISE_ADMIN_NAME=ent-admin@appsmith.com \
    -e ENTERPRISE_ADMIN_PASSWORD=ent_admin_password \
    ${LAUNCHDARKLY_BUSINESS_FLAGS_SERVER_KEY:+-e "LAUNCHDARKLY_BUSINESS_FLAGS_SERVER_KEY=${LAUNCHDARKLY_BUSINESS_FLAGS_SERVER_KEY}"} \
    appsmith/cloud-services:release
  CLOUD_SERVICES_SIGNATURE_URL=http://host.docker.internal:8090
  echo "cloud-services started; signature URL: $CLOUD_SERVICES_SIGNATURE_URL"
else
  echo "WARNING: appsmith/cloud-services:release unavailable (private image). Falling back to test-event-driver for signature URL."
fi

echo "=== [10/10] Start Appsmith container ==="
mkdir -p /tmp/appsmith-stacks/configuration
docker run -d --name appsmith \
  -p 80:80 \
  -v /tmp/appsmith-stacks:/appsmith-stacks \
  -e APPSMITH_DISABLE_TELEMETRY=true \
  -e APPSMITH_PYLON_APP_ID=DUMMY_VALUE \
  -e APPSMITH_CLOUD_SERVICES_BASE_URL=http://host.docker.internal:5001 \
  -e APPSMITH_CLOUD_SERVICES_SIGNATURE_BASE_URL="$CLOUD_SERVICES_SIGNATURE_URL" \
  -e APPSMITH_RATE_LIMIT=1000 \
  -e APPSMITH_BASE_URL=http://localhost \
  --add-host=host.docker.internal:host-gateway \
  --add-host=api.segment.io:host-gateway \
  --add-host=t.appsmith.com:host-gateway \
  cicontainer

echo "=== All containers launched; Testbot will poll /api/v1/health ==="
docker ps
