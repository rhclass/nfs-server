#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run with sudo or as root." >&2
    exit 1
fi

echo "[+] Starting BIND DNS Server Installation and Configuration on RHEL 10..."

# 1. Variables - Customize these for your environment
DOMAIN="example.com"
REVERSE_NET="192.168.1"
SERVER_IP="192.168.1.10"
FORWARDER_1="8.8.8.8"
FORWARDER_2="8.8.4.4"

# Derived variables
REVERSE_ZONE="${REVERSE_NET}.in-addr.arpa"
LAST_OCTET=$(echo "$SERVER_IP" | awk -F. '{print $4}')

# 2. Install BIND Packages
echo "[+] Installing BIND packages via DNF..."
dnf install -y bind bind-utils

# 3. Configure /etc/named.conf
echo "[+] Configuring /etc/named.conf..."
cp /etc/named.conf /etc/named.conf.bak.$(date +%F_%T)

cat << EOF > /etc/named.conf
// Main BIND Configuration File for RHEL 10

options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { any; };
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file   "/var/named/data/named.secroots";
    recursing-file  "/var/named/data/named.recursing";
    
    // Access Control: Allow queries from local subnets
    allow-query     { localhost; ${REVERSE_NET}.0/24; };

    /* Upstream Forwarders: 
       Requests for zones this server doesn't own go here.
    */
    forwarders {
        $FORWARDER_1;
        $FORWARDER_2;
    };

    recursion yes;

    dnssec-validation yes;

    managed-keys-directory "/var/named/dynamic";
    geoip-directory "/usr/share/GeoIP";

    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";

    /* https://fedoraproject.org/wiki/Changes/CryptoPolicies */
    include "/etc/crypto-policies/back-ends/bind.config";
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

// Root hints
zone "." IN {
    type hint;
    file "named.ca";
};

// Forward Lookup Zone
zone "$DOMAIN" IN {
    type master;
    file "$DOMAIN.db";
    allow-update { none; };
};

// Reverse Lookup Zone
zone "$REVERSE_ZONE" IN {
    type master;
    file "$REVERSE_ZONE.db";
    allow-update { none; };
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

# 4. Create the Forward Zone File
echo "[+] Creating Forward Zone File for $DOMAIN..."
cat << EOF > /var/named/$DOMAIN.db
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
            2026060101  ; Serial (YYYYMMDDNN)
            3600        ; Refresh
            1800        ; Retry
            604800      ; Expire
            86400 )     ; Minimum TTL

; Name Server Records
@   IN  NS  ns1.$DOMAIN.

; A Records for Name Servers
ns1 IN  A   $SERVER_IP

; Host Records in the Zone
host1   IN  A   192.168.1.101
host2   IN  A   192.168.1.102
www     IN  CNAME   ns1.$DOMAIN.
EOF

# 5. Create the Reverse Zone File
echo "[+] Creating Reverse Zone File for $REVERSE_ZONE..."
cat << EOF > /var/named/$REVERSE_ZONE.db
\$TTL 86400
@   IN  SOA ns1.$DOMAIN. root.$DOMAIN. (
            2026060101  ; Serial (YYYYMMDDNN)
            3600        ; Refresh
            1800        ; Retry
            604800      ; Expire
            86400 )     ; Minimum TTL

; Name Server Records
@   IN  NS  ns1.$DOMAIN.

; PTR Records (IP to Name)
$LAST_OCTET IN  PTR ns1.$DOMAIN.
101         IN  PTR host1.$DOMAIN.
102         IN  PTR host2.$DOMAIN.
EOF

# 6. Permissions and SELinux Contexts
echo "[+] Setting correct ownership, permissions, and SELinux contexts..."
# Files created by root in /var/named need named group ownership
chown root:named /etc/named.conf
chown named:named /var/named/$DOMAIN.db
chown named:named /var/named/$REVERSE_ZONE.db

chmod 640 /etc/named.conf
chmod 640 /var/named/$DOMAIN.db
chmod 640 /var/named/$REVERSE_ZONE.db

# Ensure standard SELinux contexts for DNS are applied
restorecon -v /etc/named.conf
restorecon -Rv /var/named/

# 7. Validate BIND Configuration Syntaxes
echo "[+] Validating BIND configuration files..."
named-checkconf /etc/named.conf
if [ $? -ne 0 ]; then
    echo "[-] Error: Syntax errors detected in /etc/named.conf" >&2
    exit 1
fi

named-checkzone "$DOMAIN" /var/named/$DOMAIN.db
named-checkzone "$REVERSE_ZONE" /var/named/$REVERSE_ZONE.db

# 8. Configure Firewalld
echo "[+] Configuring Firewalld to allow DNS traffic..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=dns
    firewall-cmd --reload
    echo "    DNS port allowed in firewalld."
else
    echo "    Firewalld is not running. Skipping firewall rules."
fi

# 9. Start and Enable BIND Service
echo "[+] Starting and enabling named.service..."
systemctl daemon-reload
systemctl enable --now named.service

# 10. Verification Report
echo -e "\n========================================="
echo "[+] BIND Server Verification Status:"
echo "========================================="
systemctl status named.service --no-pager | grep -E "(Active:|Main PID:)"

echo -e "\n[+] Testing local loopback resolution:"
dig @localhost ns1.$DOMAIN +short
