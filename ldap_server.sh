#!/bin/bash
set -e

# Variables
LDAP_DOMAIN="example.com"
LDAP_DC="dc=example,dc=com"
LDAP_ORG="ExampleOrg"
LDAP_ADMIN_PASS="StrongAdminPass123"
SSL_DIR="/etc/ssl/ldap"

# Update system
apt update && apt -y upgrade

# Install slapd and ldap utilities
DEBIAN_FRONTEND=noninteractive apt install -y slapd ldap-utils gnutls-bin

# Reconfigure slapd non-interactively
echo "slapd slapd/internal/generated_adminpw password $LDAP_ADMIN_PASS" | debconf-set-selections
echo "slapd slapd/internal/adminpw password $LDAP_ADMIN_PASS" | debconf-set-selections
echo "slapd slapd/password2 password $LDAP_ADMIN_PASS" | debconf-set-selections
echo "slapd slapd/password1 password $LDAP_ADMIN_PASS" | debconf-set-selections
echo "slapd slapd/domain string $LDAP_DOMAIN" | debconf-set-selections
echo "slapd shared/organization string $LDAP_ORG" | debconf-set-selections
echo "slapd slapd/backend string MDB" | debconf-set-selections
echo "slapd slapd/purge_database boolean true" | debconf-set-selections
echo "slapd slapd/move_old_database boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive slapd

# Create self-signed SSL certificates
mkdir -p $SSL_DIR
openssl req -new -x509 -days 365 -nodes -out $SSL_DIR/ldap.crt -keyout $SSL_DIR/ldap.key -subj "/C=IN/ST=KA/L=BLR/O=$LDAP_ORG/CN=$LDAP_DOMAIN"
chown openldap:openldap $SSL_DIR/ldap.*

# Configure TLS
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=config
add: olcTLSCertificateFile
olcTLSCertificateFile: $SSL_DIR/ldap.crt
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $SSL_DIR/ldap.key
EOF

# Create base structure LDIF
cat > base.ldif <<EOF
dn: ou=users,$LDAP_DC
objectClass: organizationalUnit
ou: users

dn: ou=groups,$LDAP_DC
objectClass: organizationalUnit
ou: groups

dn: cn=group1,ou=groups,$LDAP_DC
objectClass: posixGroup
cn: group1
gidNumber: 10001

dn: cn=group2,ou=groups,$LDAP_DC
objectClass: posixGroup
cn: group2
gidNumber: 10002

dn: uid=user1,ou=users,$LDAP_DC
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: user1
sn: user1
uid: user1
uidNumber: 20001
gidNumber: 10001
homeDirectory: /home/user1
loginShell: /bin/bash
userPassword: $(slappasswd -s user1pass)

dn: uid=user2,ou=users,$LDAP_DC
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: user2
sn: user2
uid: user2
uidNumber: 20002
gidNumber: 10002
homeDirectory: /home/user2
loginShell: /bin/bash
userPassword: $(slappasswd -s user2pass)
EOF

ldapadd -x -D cn=admin,$LDAP_DC -w $LDAP_ADMIN_PASS -f base.ldif

systemctl restart slapd
echo "LDAP server setup completed successfully!"
