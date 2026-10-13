#!/usr/bin/env bash
# Deploy hello-world-echo-service (Spring Boot 4, Java 17) on a Debian 13 (trixie) x86_64 VM.
#
# Source: https://github.com/Ashwinasokan/hello-world-echo-service
#
# Modes:
#   native (default)  Install Temurin 17 JDK, build the boot jar from source, run it under systemd.
#   docker            Install Docker from Debian, run the published GHCR image under systemd.
#
# Usage:
#   sudo ./deploy-debian13.sh [--mode native|docker] [--ref <branch|tag|sha>] [--port <port>]
#                             [--image-tag <tag>] [--java-opts "<opts>"] [--uninstall]
#
# Re-running the script is safe: it rebuilds/repulls and restarts the service (in-place upgrade).

set -Eeuo pipefail

APP_NAME="hello-world-echo-service"
REPO_URL="https://github.com/Ashwinasokan/hello-world-echo-service.git"
IMAGE_REPO="ghcr.io/ashwinasokan/hello-world-echo-service"

MODE="native"
GIT_REF="main"
PORT="8080"
IMAGE_TAG="latest"
JAVA_OPTS="-Xms128m -Xmx256m"
UNINSTALL=0

APP_USER="echo-svc"
INSTALL_DIR="/opt/${APP_NAME}"
SRC_DIR="${INSTALL_DIR}/src"
CONF_FILE="/etc/default/${APP_NAME}"
UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
GRADLE_HOME_DIR="/var/cache/${APP_NAME}/gradle"
JAVA_HOME_DIR="/usr/lib/jvm/temurin-17-jdk-amd64"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)       MODE="${2:?}"; shift 2 ;;
    --ref)        GIT_REF="${2:?}"; shift 2 ;;
    --port)       PORT="${2:?}"; shift 2 ;;
    --image-tag)  IMAGE_TAG="${2:?}"; shift 2 ;;
    --java-opts)  JAVA_OPTS="${2:?}"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            warn "unknown argument: $1"; usage 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"
  [[ "$MODE" == "native" || "$MODE" == "docker" ]] || die "--mode must be 'native' or 'docker'"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || die "invalid --port: $PORT"

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
    warn "expected Debian 13 (trixie), found ${PRETTY_NAME:-unknown}; continuing anyway"
  fi
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "this script targets x86_64 (amd64) only"
  command -v systemctl >/dev/null || die "systemd is required"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
  log "stopping and removing ${APP_NAME}"
  systemctl disable --now "${APP_NAME}.service" 2>/dev/null || true
  rm -f "$UNIT_FILE" "$CONF_FILE"
  systemctl daemon-reload
  if command -v docker >/dev/null; then
    docker rm -f "$APP_NAME" 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR" "/var/cache/${APP_NAME}"
  if id "$APP_USER" &>/dev/null; then userdel "$APP_USER" || true; fi
  log "uninstalled (Temurin/Docker packages left in place)"
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------
apt_base() {
  log "installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg git >/dev/null
}

ensure_user() {
  if ! id "$APP_USER" &>/dev/null; then
    log "creating system user ${APP_USER}"
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$INSTALL_DIR"
}

write_conf() {
  log "writing ${CONF_FILE}"
  cat >"$CONF_FILE" <<EOF
# Managed by deploy-debian13.sh. Edit and run: systemctl restart ${APP_NAME}
SERVER_PORT=${PORT}
JAVA_OPTS=${JAVA_OPTS}
EOF
  chmod 0644 "$CONF_FILE"
}

health_check() {
  local url="http://127.0.0.1:${PORT}/greeting?name=deploy-check"
  log "waiting for ${url}"
  for _ in $(seq 1 60); do
    if body="$(curl -fsS --max-time 2 "$url" 2>/dev/null)"; then
      log "healthy: ${body}"
      return 0
    fi
    sleep 2
  done
  journalctl -u "${APP_NAME}.service" -n 50 --no-pager >&2 || true
  die "service did not become healthy within 120s"
}

# ---------------------------------------------------------------------------
# Native mode: Temurin 17 + Gradle build + systemd
# ---------------------------------------------------------------------------
install_temurin17() {
  # Debian 13 ships OpenJDK 21/25 only; build.gradle pins a Java 17 toolchain, so use Adoptium's repo.
  if dpkg -s temurin-17-jdk &>/dev/null; then
    log "temurin-17-jdk already installed"
    return
  fi
  log "installing Eclipse Temurin 17 JDK from packages.adoptium.net"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb trixie main" \
    >/etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  apt-get install -y -qq temurin-17-jdk >/dev/null
}

fetch_source() {
  if [[ -d "${SRC_DIR}/.git" ]]; then
    log "updating source to ${GIT_REF}"
    runuser -u "$APP_USER" -- git -C "$SRC_DIR" fetch --quiet --tags --force origin
  else
    log "cloning ${REPO_URL}"
    runuser -u "$APP_USER" -- git clone --quiet "$REPO_URL" "$SRC_DIR"
  fi
  # Resolve branch names against origin so re-runs pick up new commits.
  local target="$GIT_REF"
  if runuser -u "$APP_USER" -- git -C "$SRC_DIR" rev-parse --verify --quiet "origin/${GIT_REF}" >/dev/null; then
    target="origin/${GIT_REF}"
  fi
  runuser -u "$APP_USER" -- git -C "$SRC_DIR" checkout --quiet --force --detach "$target"
  log "at commit $(runuser -u "$APP_USER" -- git -C "$SRC_DIR" rev-parse --short HEAD)"
}

build_jar() {
  log "building boot jar (first run downloads Gradle and dependencies; takes a few minutes)"
  install -d -o "$APP_USER" -g "$APP_USER" "$GRADLE_HOME_DIR"
  chmod +x "${SRC_DIR}/gradlew"
  runuser -u "$APP_USER" -- env \
    JAVA_HOME="$JAVA_HOME_DIR" GRADLE_USER_HOME="$GRADLE_HOME_DIR" \
    bash -c "cd '$SRC_DIR' && ./gradlew --no-daemon --quiet clean bootJar"

  local jar
  jar="$(find "${SRC_DIR}/build/libs" -maxdepth 1 -name '*.jar' ! -name '*-plain.jar' | head -n1)"
  [[ -n "$jar" ]] || die "bootJar produced no jar"
  install -o root -g root -m 0644 "$jar" "${INSTALL_DIR}/app.jar"
  log "installed ${INSTALL_DIR}/app.jar"
}

write_unit_native() {
  log "writing ${UNIT_FILE}"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Hello World Echo Service (Spring Boot)
Documentation=https://github.com/Ashwinasokan/hello-world-echo-service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONF_FILE}
# \$JAVA_OPTS (unbraced) is word-split by systemd into separate JVM arguments.
ExecStart=${JAVA_HOME_DIR}/bin/java \$JAVA_OPTS -jar ${INSTALL_DIR}/app.jar
SuccessExitStatus=143
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${INSTALL_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

deploy_native() {
  apt_base
  install_temurin17
  ensure_user
  fetch_source
  build_jar
  write_conf
  write_unit_native
}

# ---------------------------------------------------------------------------
# Docker mode: Debian docker.io + GHCR image + systemd
# ---------------------------------------------------------------------------
deploy_docker() {
  apt_base
  if ! command -v docker >/dev/null; then
    log "installing docker.io from Debian"
    apt-get install -y -qq docker.io >/dev/null
  fi
  systemctl enable --now docker >/dev/null

  log "pulling ${IMAGE_REPO}:${IMAGE_TAG}"
  docker pull --platform linux/amd64 "${IMAGE_REPO}:${IMAGE_TAG}"

  write_conf
  log "writing ${UNIT_FILE}"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Hello World Echo Service (container)
Documentation=https://github.com/Ashwinasokan/hello-world-echo-service
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
EnvironmentFile=${CONF_FILE}
ExecStartPre=-/usr/bin/docker rm -f ${APP_NAME}
ExecStart=/usr/bin/docker run --rm --name ${APP_NAME} -p \${SERVER_PORT}:8080 \\
  -e "JAVA_TOOL_OPTIONS=\${JAVA_OPTS}" ${IMAGE_REPO}:${IMAGE_TAG}
ExecStop=/usr/bin/docker stop -t 20 ${APP_NAME}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight

if (( UNINSTALL )); then
  uninstall
  exit 0
fi

log "mode=${MODE} port=${PORT} $( [[ $MODE == native ]] && echo "ref=${GIT_REF}" || echo "image=${IMAGE_REPO}:${IMAGE_TAG}" )"
"deploy_${MODE}"

systemctl daemon-reload
systemctl enable "${APP_NAME}.service" >/dev/null
systemctl restart "${APP_NAME}.service"
health_check

log "done. Try: curl 'http://<vm-ip>:${PORT}/greeting?name=you'"
log "logs:   journalctl -u ${APP_NAME} -f"
log "config: ${CONF_FILE} (then systemctl restart ${APP_NAME})"
