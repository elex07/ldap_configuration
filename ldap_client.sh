#!/usr/bin/env bash
set -euo pipefail

##### >>> EDIT THESE IF YOU LIKE <<<
LDAP_DOMAIN="${LDAP_DOMAIN:-example.com}"
LDAP_HOSTNAME="${LDAP_HOSTNAME:-ldap.example.com}"    # must match server cert CN/SAN
LDAP_SERVER_IP="${LDAP_SERVER_IP:-10.0.2.17}"         # used to write /etc/hosts

# Must match what server created:
READONLY_DN="${READONLY_DN:-cn=readonly,dc=example,dc=com}"
READONLY_PASSWORD="${READONLY_PASSWORD:-ReadOnlyPass123}"
##### <<< EDIT ABOVE IF NEEDED >>>

export DEBIAN_FRONTEND=noninteractive

to_dc() { local d="${1}"; awk -F. '{print "dc="$1",dc="$2}' <<<"$d"; }
BASE_DN="$(to_dc "$LDAP_DOMAIN")"

echo "[CLIENT] /etc/hosts: ensure ${LDAP_SERVER_IP} ${LDAP_HOSTNAME}"
if ! grep -qE "[[:space:]]${LDAP_HOSTNAME}(\s|$)" /etc/hosts; then
  echo "${LDAP_SERVER_IP} ${LDAP_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[CLIENT] Install SSSD + tools"
apt-get update -y
apt-get install -y sssd sssd-ldap libnss-sss libpam-sss ldap-utils ca-certificates openssl sssd-tools

echo "[CLIENT] Trust the server's certificate (grab from 636)"
CERT_DST="/usr/local/share/ca-certificates/ldap-${LDAP_HOSTNAME}.crt"
# Grab the server's leaf cert and store as local CA (sufficient for trust in this lab)
openssl s_client -connect "${LDAP_HOSTNAME}:636" -servername "${LDAP_HOSTNAME}" -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/{flag=1} /END CERTIFICATE/{print; exit} flag{print}' > "${CERT_DST}"
update-ca-certificates

echo "[CLIENT] Create /etc/sssd/sssd.conf"
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam
config_file_version = 2
domains = LDAP

[domain/LDAP]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

# LDAPS only
ldap_uri = ldaps://${LDAP_HOSTNAME}
ldap_tls_reqcert = demand
ldap_tls_cacert = /etc/ssl/certs/ca-certificates.crt

# Bind account for directory searches (anonymous disabled on server)
ldap_default_bind_dn = ${READONLY_DN}
ldap_default_authtok = ${READONLY_PASSWORD}

# Search bases
ldap_search_base = ${BASE_DN}
ldap_user_search_base = ou=users,${BASE_DN}
ldap_group_search_base = ou=groups,${BASE_DN}

# Map username attribute
ldap_user_name = uid

# Behaviors
enumerate = true
cache_credentials = true
EOF

chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf

echo "[CLIENT] Wire NSS to SSSD"
# Ensure 'sss' is present for passwd/group/shadow
for key in passwd group shadow; do
  if grep -q "^${key}:" /etc/nsswitch.conf; then
    sed -i "s|^${key}:.*|${key}:         files sss|" /etc/nsswitch.conf
  else
    echo "${key}:         files sss" >> /etc/nsswitch.conf
  fi
done

echo "[CLIENT] Enable home auto-creation at first login"
if ! grep -q "pam_mkhomedir.so" /etc/pam.d/common-session; then
  echo "session required pam_mkhomedir.so skel=/etc/skel umask=0077" >> /etc/pam.d/common-session
fi

echo "[CLIENT] Restart SSSD and clear cache"
systemctl enable sssd
systemctl restart sssd
sss_cache -E || true
sleep 1

echo "[CLIENT] Quick LDAPS checks"
set +e
ldapsearch -x -H "ldaps://${LDAP_HOSTNAME}" \
  -D "${READONLY_DN}" -w "${READONLY_PASSWORD}" \
  -b "${BASE_DN}" "(objectClass=*)" >/dev/null
LDAP_RC=$?
set -e
if [ "$LDAP_RC" -ne 0 ]; then
  echo "[CLIENT][ERROR] Cannot query LDAP over LDAPS. Check cert trust / network."
  exit 1
fi

echo "[CLIENT] Verify users/groups via SSSD"
getent passwd user1 || (echo "[ERROR] user1 not found via getent" && exit 1)
getent passwd user2 || (echo "[ERROR] user2 not found via getent" && exit 1)
getent group group1 || (echo "[ERROR] group1 not found via getent" && exit 1)
getent group group2 || (echo "[ERROR] group2 not found via getent" && exit 1)

id user1 || (echo "[ERROR] id user1 failed" && exit 1)
id user2 || (echo "[ERROR] id user2 failed" && exit 1)

echo "[CLIENT] Pre-create homes (optional) so root 'su -' is clean"
command -v mkhomedir_helper >/dev/null 2>&1 && {
  mkhomedir_helper user1 || true
  mkhomedir_helper user2 || true
}
# As root, switch once to trigger pam_mkhomedir if helper isn't present
su -l -c "true" user1 || true
su -l -c "true" user2 || true

echo "[CLIENT] All done ✅
- Server: ldaps://${LDAP_HOSTNAME}
- Users visible via 'id' and 'getent'
- Root can 'su - user1' and 'su - user2' (homes created on first use)
"

