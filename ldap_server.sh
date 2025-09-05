#!/usr/bin/env bash
set -euo pipefail

##### >>> EDIT THESE IF YOU LIKE (defaults are fine for a quick lab) <<<
LDAP_DOMAIN="${LDAP_DOMAIN:-example.com}"
LDAP_ORG="${LDAP_ORG:-ExampleOrg}"
LDAP_HOSTNAME="${LDAP_HOSTNAME:-ldap.example.com}"     # CN & SAN must match this
LDAP_SERVER_IP="${LDAP_SERVER_IP:-10.0.2.17}"          # used to write /etc/hosts
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-StrongAdminPass123}"

# Read-only bind account for SSSD lookups (not for user logins)
READONLY_DN="${READONLY_DN:-cn=readonly,dc=example,dc=com}"
READONLY_PASSWORD="${READONLY_PASSWORD:-ReadOnlyPass123}"

# Demo users (primary groups: user1->group1, user2->group2)
USER1_PASSWORD="${USER1_PASSWORD:-User1Pass123}"
USER2_PASSWORD="${USER2_PASSWORD:-User2Pass123}"
##### <<< EDIT ABOVE IF NEEDED >>>

export DEBIAN_FRONTEND=noninteractive

# Helpers
to_dc() { # "example.com" -> "dc=example,dc=com"
  local d="${1}"; awk -F. '{print "dc="$1",dc="$2}' <<<"$d"
}
BASE_DN="$(to_dc "$LDAP_DOMAIN")"

echo "[SERVER] Using BASE_DN: $BASE_DN"
echo
echo "##################################################"
echo "[SERVER] /etc/hosts: ensure ${LDAP_SERVER_IP} ${LDAP_HOSTNAME}"
sleep 3
if ! grep -qE "[[:space:]]${LDAP_HOSTNAME}(\s|$)" /etc/hosts; then
  echo "${LDAP_SERVER_IP} ${LDAP_HOSTNAME}" >> /etc/hosts
fi
hostnamectl set-hostname "${LDAP_HOSTNAME}" || true
echo
echo "##################################################"
echo "[SERVER] Install OpenLDAP server & tools"
sleep 3
apt-get update -y
# Preseed slapd for non-interactive install
echo "slapd slapd/no_configuration boolean false" | debconf-set-selections
echo "slapd slapd/domain string ${LDAP_DOMAIN}" | debconf-set-selections
echo "slapd shared/organization string ${LDAP_ORG}" | debconf-set-selections
echo "slapd slapd/backend select MDB" | debconf-set-selections
echo "slapd slapd/purge_database boolean true" | debconf-set-selections
echo "slapd slapd/move_old_database boolean true" | debconf-set-selections
echo "slapd slapd/allow_ldap_v2 boolean false" | debconf-set-selections
echo "slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}" | debconf-set-selections
echo "slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}" | debconf-set-selections
apt-get install -y slapd ldap-utils ca-certificates openssl

systemctl enable slapd
echo
echo "##################################################"
echo "[SERVER] Generate CA and server cert with SAN=DNS:${LDAP_HOSTNAME}"
sleep 3
SSL_DIR="/etc/ssl/ldap"
mkdir -p "${SSL_DIR}"
chmod 750 "${SSL_DIR}"
pushd "${SSL_DIR}" >/dev/null

# CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/C=IN/ST=KA/L=BLR/O=${LDAP_ORG} CA/CN=${LDAP_HOSTNAME}-CA"

# Server key + CSR
openssl genrsa -out ldap.key 2048
openssl req -new -key ldap.key -out ldap.csr \
  -subj "/C=IN/ST=KA/L=BLR/O=${LDAP_ORG}/CN=${LDAP_HOSTNAME}"

# v3 extensions for SAN
cat > v3ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth
subjectAltName = DNS:${LDAP_HOSTNAME}
EOF

# Sign cert with our CA
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ldap.crt -days 825 -sha256 -extfile v3ext.cnf

chown -R openldap:openldap "${SSL_DIR}"
chmod 600 "${SSL_DIR}/ldap.key"
popd >/dev/null
echo
echo "##################################################"
echo "[SERVER] Configure slapd TLS (cn=config) to use ca.crt / ldap.crt / ldap.key"
sleep 3
cat > /tmp/olc_tls.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${SSL_DIR}/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${SSL_DIR}/ldap.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${SSL_DIR}/ldap.key
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
EOF

ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/olc_tls.ldif
echo
echo "##################################################"
echo "[SERVER] Enable ldaps:/// listener (port 636)"
sleep 3
if grep -q '^SLAPD_SERVICES=' /etc/default/slapd; then
  sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
else
  echo 'SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"' >> /etc/default/slapd
fi
echo
echo "##################################################"
echo "[SERVER] Basic hardening: disable anonymous binds; require TLS strength"
sleep 3
cat > /tmp/olc_hardening.ldif <<'EOF'
dn: cn=config
changetype: modify
replace: olcDisallows
olcDisallows: bind_anon
-
replace: olcSecurity
olcSecurity: ssf=128
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/olc_hardening.ldif || true
echo
echo "##################################################"
echo "[SERVER] Configure LDAP client defaults and trust CA"
sleep 3
# Copy CA to system trust store
cp /etc/ssl/ldap/ca.crt /usr/local/share/ca-certificates/ldap-ca.crt
update-ca-certificates

# Configure ldap.conf for client tools
cat >/etc/ldap/ldap.conf <<EOF
BASE    dc=example,dc=com
URI     ldaps://ldap.example.com

TLS_CACERT /etc/ssl/ldap/ca.crt
TLS_REQCERT demand
EOF
echo
echo "##################################################"
echo "[SERVER] Restart slapd"
sleep 3
systemctl restart slapd
sleep 1
echo
echo "##################################################"
echo "[SERVER] Verify listeners"
sleep 3
ss -tulnp | grep slapd || (echo "slapd not listening!" && exit 1)
echo
echo "##################################################"
echo "[SERVER] Create base OUs, groups, users, and readonly bind account"
sleep 3
U1_HASH=$(slappasswd -s "${USER1_PASSWORD}")
U2_HASH=$(slappasswd -s "${USER2_PASSWORD}")
RO_HASH=$(slappasswd -s "${READONLY_PASSWORD}")

cat > /tmp/bootstrap.ldif <<EOF
# OUs
dn: ou=users,${BASE_DN}
objectClass: organizationalUnit
ou: users

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups

# Groups
dn: cn=group1,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: group1
gidNumber: 10001
memberUid: user1

dn: cn=group2,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: group2
gidNumber: 10002
memberUid: user2

# Users
dn: uid=user1,ou=users,${BASE_DN}
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
userPassword: ${U1_HASH}

dn: uid=user2,ou=users,${BASE_DN}
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
userPassword: ${U2_HASH}

# Read-only bind account (for SSSD searches)
dn: ${READONLY_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: readonly
userPassword: ${RO_HASH}
description: Read-only bind user for SSSD
EOF

ldapadd -x -H ldaps://localhost:636   -D "cn=admin,dc=example,dc=com" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/bootstrap.ldif
echo
echo "##################################################"
echo "[SERVER] Quick LDAPS check"
sleep 3
ldapsearch -x -H "ldaps://${LDAP_HOSTNAME}" -b "${BASE_DN}" -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" "(objectClass=*)" >/dev/null

echo "[SERVER] All done ✅
- LDAPS hostname: ${LDAP_HOSTNAME}
- BASE_DN: ${BASE_DN}
- Admin DN: cn=admin,${BASE_DN}
- Readonly DN: ${READONLY_DN}
- Users: user1/user2 (passwords set)
"

