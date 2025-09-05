# Stop sssd
systemctl stop sssd

# Purge SSSD and LDAP client utilities
apt-get purge -y sssd libnss-sss libpam-sss ldap-utils

# Remove SSSD configuration and cache
rm -rf /etc/sssd /var/lib/sss /var/log/sssd

# Clean up PAM configs if modified
sed -i '/pam_sss.so/d' /etc/pam.d/common-auth
sed -i '/pam_sss.so/d' /etc/pam.d/common-account
sed -i '/pam_sss.so/d' /etc/pam.d/common-password
sed -i '/pam_sss.so/d' /etc/pam.d/common-session
sed -i '/pam_sss.so/d' /etc/pam.d/common-session-noninteractive

# Remove LDAP certificates
rm -f /etc/ssl/certs/ldap.example.com.crt
rm -f /etc/ssl/certs/ca-certificates.crt  # optional

# Reset NSS config if changed
sed -i 's/sss//g' /etc/nsswitch.conf

# Clean up packages
apt-get autoremove -y
apt-get autoclean

