#!/bin/bash
set -euo pipefail

# ==========================================================
# DISCLAIMER
# ==========================================================
echo "=========================================================="
echo "PDFGuard is a simple PDF rendering tool for Tomcat."
echo "This script will install Tomcat and the PDFGuard application."
echo "=========================================================="
echo ""


# ==========================================================
# CONFIG
# ==========================================================
APP_NAME="pdfguard"
WAR_URL="https://onprempdf.com/war/pdfguard.war"
WAR_SHA256="40d25079826f39f01afc841f76dd0c40734163a9a3d0f8025bd779a141407db6"

TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"
TOMCAT_DIR="/opt/tomcat"
TOMCAT_VER="9.0.113"

TMP_DIR="/tmp/pdfguard-install"
WAR_LOCAL="${TMP_DIR}/${APP_NAME}.war"
TOMCAT_WEBAPPS="${TOMCAT_DIR}/webapps"
TOMCAT_CONF="${TOMCAT_DIR}/conf"

ADMIN_USER="pdfguard"

log() { echo "[pdfguard] $*"; }

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Bitte als root ausfuehren (sudo ./install.sh)"; exit 1; }
}

# ==========================================================
# START
# ==========================================================
require_root


if systemctl list-unit-files | grep -q '^tomcat9\.service'; then
  echo "[pdfguard] ❌ Tomcat9 service already exists. Aborting."
  exit 1
fi

if [ -d "/opt/tomcat" ]; then
  echo "[pdfguard] ❌ /opt/tomcat already exists. Aborting."
  exit 1
fi

# Optional: laufender Tomcat
if systemctl is-active --quiet tomcat9; then
  echo "[pdfguard] ❌ Tomcat9 is running. Aborting."
  exit 1
fi


log "Prepare temp dir"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# ==========================================================
# BASE PACKAGES
# ==========================================================
log "Install base packages"
apt update
apt install -y \
  openjdk-17-jre-headless \
  curl ca-certificates tar openssl \
  fontconfig

# ==========================================================
# Tomcat user
# ==========================================================
if ! id -u "$TOMCAT_USER" >/dev/null 2>&1; then
  log "Create Tomcat user"
  useradd -r -m -U -d "$TOMCAT_DIR" -s /usr/sbin/nologin "$TOMCAT_USER"
fi


# ==========================================================
# Tomcat install
# ==========================================================
log "Install Tomcat ${TOMCAT_VER}"
cd /tmp
TARBALL="apache-tomcat-${TOMCAT_VER}.tar.gz"
URL="https://dlcdn.apache.org/tomcat/tomcat-9/v${TOMCAT_VER}/bin/${TARBALL}"

systemctl stop tomcat9 2>/dev/null || true

curl -fL "$URL" -o "$TARBALL"

mkdir -p "$TOMCAT_DIR"
rm -rf "${TOMCAT_DIR:?}/"*
tar -xzf "$TARBALL" -C "$TOMCAT_DIR" --strip-components=1

chown -R "${TOMCAT_USER}:${TOMCAT_GROUP}" "$TOMCAT_DIR"
chmod +x "${TOMCAT_DIR}/bin/"*.sh

# Remove default Tomcat management webapps, ROOT and example folder (reduce attack surface)
rm -rf "${TOMCAT_WEBAPPS}/manager" \
       "${TOMCAT_WEBAPPS}/host-manager" \
       "${TOMCAT_WEBAPPS}/examples" \
       "${TOMCAT_WEBAPPS}/ROOT"


# ==========================================================
# Configure Tomcat connector limits
# ==========================================================

log "Backup original server.xml"
cp "${TOMCAT_CONF}/server.xml" "${TOMCAT_CONF}/server.xml.bak"

log "Configure Tomcat connector limits"

perl -0777 -i -pe 's|<Connector\s+port="8080"[\s\S]*?/>|<Connector
    port="8080"
    protocol="org.apache.coyote.http11.Http11NioProtocol"
    maxThreads="8"
    acceptCount="16"
    maxPostSize="200000"
    connectionTimeout="20000"
/>|g' "${TOMCAT_CONF}/server.xml"

# Ensure correct ownership and permissions
chown ${TOMCAT_USER}:${TOMCAT_GROUP} "${TOMCAT_CONF}/server.xml"
chmod 600 "${TOMCAT_CONF}/server.xml"




# ==========================================================
# 
# ==========================================================

PDFGUARD_DATA="/var/lib/pdfguard"
PDFGUARD_AUDITS="/var/lib/pdfguard/audits"

log "Create PDFGuard data directories"

mkdir -p "$PDFGUARD_AUDITS"

chown -R "${TOMCAT_USER}:${TOMCAT_GROUP}" "$PDFGUARD_DATA"
chmod 750 "$PDFGUARD_DATA"
chmod 750 "$PDFGUARD_AUDITS"

# Lite mode = no license file present

# ==========================================================
# Download WAR + deploy
# ==========================================================



# ==========================================================
# systemd service
# ==========================================================
log "Create systemd service for Tomcat"
cat > /etc/systemd/system/tomcat9.service <<EOF
[Unit]
Description=Apache Tomcat 9 (PDFGuard)
After=network.target

[Service]
Type=forking
User=${TOMCAT_USER}
Group=${TOMCAT_GROUP}
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="CATALINA_HOME=${TOMCAT_DIR}"
Environment="CATALINA_BASE=${TOMCAT_DIR}"
Environment="CATALINA_PID=${TOMCAT_DIR}/temp/tomcat.pid"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ==========================================================
# Generate admin password
# ==========================================================
log "Generate admin credentials"
ADMIN_PASS="$(openssl rand -base64 24)"

# ==========================================================
# Configure Tomcat Basic Auth
# ==========================================================
log "Configure Tomcat users"

cat > "${TOMCAT_CONF}/tomcat-users.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<tomcat-users xmlns="http://tomcat.apache.org/xml"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://tomcat.apache.org/xml tomcat-users.xsd"
              version="1.0">
  <role rolename="pdfguard-admin"/>
  <user username="${ADMIN_USER}" password="${ADMIN_PASS}" roles="pdfguard-admin"/>
</tomcat-users>
EOF

chown ${TOMCAT_USER}:${TOMCAT_GROUP} "${TOMCAT_CONF}/tomcat-users.xml"
chmod 600 "${TOMCAT_CONF}/tomcat-users.xml"

# ==========================================================
# Download WAR + deploy
# ==========================================================
log "Download WAR"
curl -fL "$WAR_URL" -o "$WAR_LOCAL"

log "Verify WAR checksum"
DOWNLOADED_SHA256="$(sha256sum "$WAR_LOCAL" | awk '{print $1}')"

if [ "$DOWNLOADED_SHA256" != "$WAR_SHA256" ]; then
  echo "ERROR: SHA256 mismatch!"
  echo "Expected: $WAR_SHA256"
  echo "Got:      $DOWNLOADED_SHA256"
  exit 1
fi

log "WAR checksum OK"

systemctl stop tomcat9 || true
rm -rf "${TOMCAT_WEBAPPS:?}/${APP_NAME}"*
cp "$WAR_LOCAL" "${TOMCAT_WEBAPPS}/${APP_NAME}.war"
chown "${TOMCAT_USER}:${TOMCAT_GROUP}" "${TOMCAT_WEBAPPS}/${APP_NAME}.war"

# ==========================================================
# Enable & start Tomcat
# ==========================================================
log "Enable services"
systemctl enable tomcat9
systemctl start tomcat9

# ==========================================================
# Done
# ==========================================================
IP="$(hostname -I | awk '{print $1}')"
echo ""
echo "=========================================================="
echo "Installation completed!"
echo ""
echo "----------------------------------------------------------"
echo "Security notice:"
echo "Tomcat is listening on port 8080 for internal access."
echo "Ensure this port is not exposed to public networks."
echo "Restrict access via firewall or network configuration."
echo "----------------------------------------------------------"
echo ""
echo "PDFGuard API:"
echo "http://${IP}:8080/pdfguard/api/v1/render"
echo ""
echo "Administration interface:"
echo "http://${IP}:8080/pdfguard/"
echo ""
echo "Admin login:"
echo "Username: ${ADMIN_USER}"
echo "Password: ${ADMIN_PASS}"
echo ""
echo "The password was generated randomly during installation."
echo ""
echo "Credentials are stored locally in:"
echo "/opt/tomcat/conf/tomcat-users.xml (permissions: 600, readable only by the tomcat user)"
echo ""
echo "Please store this password securely."
echo "=========================================================="
