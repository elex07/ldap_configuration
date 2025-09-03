#!/bin/bash
set -e

# Variables
LDAP_DOMAIN="example.com"
LDAP_DC="dc=example,dc=com"
LDAP_URI="ldaps://ldap.example.com"
LDAP_BASE="$LDAP_DC"
LDAP_ADMIN_PASS="StrongAdminPass123"

# Update system
apt update && apt -y upgrade

# Install SSSD and LDAP tools
apt install -y sssd sssd-ldap sssd-tools libnss-sss libpam-sss ldap-utils

# Backup configs
cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak 2>/dev/null || true

# Create sssd.conf
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam
config_file_version = 2
domains = LDAP

[domain/LDAP]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = $LDAP_URI
ldap_search_base = $LDAP_BASE
ldap_tls_reqcert = allow
cache_credentials = true
enumerate = true
EOF

chmod 600 /etc/sssd/sssd.conf
systemctl enable sssd
systemctl restart sssd

# Configure NSS
sed -i 's/passwd:.*/passwd:         files sss/' /etc/nsswitch.conf
sed -i 's/group:.*/group:          files sss/' /etc/nsswitch.conf
sed -i 's/shadow:.*/shadow:         files sss/' /etc/nsswitch.conf

# Configure PAM for su
pam_su="/etc/pam.d/su"
if ! grep -q "pam_sss.so" "$pam_su"; then
  echo "auth       sufficient   pam_sss.so use_first_pass" >> $pam_su
  echo "account    sufficient   pam_sss.so" >> $pam_su
fi

# Test lookups
id user1 || echo "User1 not found yet. Check sssd logs."
id user2 || echo "User2 not found yet. Check sssd logs."

echo "LDAP client setup completed successfully! Try: su - user1 / su - user2"
