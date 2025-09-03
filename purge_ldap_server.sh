# Stop slapd
systemctl stop slapd

# Purge OpenLDAP packages
apt-get purge -y slapd ldap-utils

# Remove OpenLDAP configuration and database directories
rm -rf /etc/ldap /var/lib/ldap

# Remove SSL certificates related to LDAP
rm -f /etc/ssl/certs/ldap.example.com.crt
rm -f /etc/ssl/private/ldap.example.com.key
rm -f /etc/ssl/certs/ca-certificates.crt  # optional, only if you want to reset completely

# Clean up any residual dependencies
apt-get autoremove -y
apt-get autoclean
