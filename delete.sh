sudo bash -c '
set -e


echo "[cleanup] This will completely remove PDFGuard, Tomcat and the Java runtime installed by this script."
echo "[cleanup] Do not run on systems where Java is required by other applications."

echo "[cleanup] Stop Tomcat"

systemctl stop tomcat9 2>/dev/null || true
systemctl disable tomcat9 2>/dev/null || true

echo "[cleanup] Delete systemd Service"
rm -f /etc/systemd/system/tomcat9.service
systemctl daemon-reload
systemctl reset-failed

echo "[cleanup] Delete Tomcat"
rm -rf /opt/tomcat

echo "[cleanup] Delete PDFGuard Data"
rm -rf /var/lib/pdfguard

echo "[cleanup] Delete Temp Dateien"
rm -rf /tmp/pdfguard-install
rm -f /tmp/apache-tomcat-*.tar.gz

echo "[cleanup] Delete Tomcat User & Group"
userdel -r tomcat 2>/dev/null || true
groupdel tomcat 2>/dev/null || true

echo "[cleanup] Delete Java"
apt purge -y openjdk-17-jre-headless || true
apt autoremove -y || true

echo "[cleanup] (inkl. Java)"
'
