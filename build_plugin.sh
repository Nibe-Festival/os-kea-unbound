#!/bin/sh

# 1. Define Variables
PLUGIN_NAME="os-kea-unbound"
VERSION="3.6.5"
BUILD_DIR="./${PLUGIN_NAME}_build"
STAGE_DIR="${BUILD_DIR}/stage"

echo ">>> Cleaning up old build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${STAGE_DIR}"

# Mandated directories
KEA_SCRIPT_DIR="${STAGE_DIR}/usr/local/share/kea/scripts"
UPDATE_HOOK_DIR="${STAGE_DIR}/usr/local/etc/rc.syshook.d/update"
BOOT_HOOK_DIR="${STAGE_DIR}/usr/local/etc/rc.syshook.d/early"
CRON_DIR="${STAGE_DIR}/usr/local/etc/cron.d"
LOG_ROT_DIR="${STAGE_DIR}/usr/local/etc/newsyslog.conf.d"

echo ">>> Creating directory structure..."
mkdir -p "${KEA_SCRIPT_DIR}" "${UPDATE_HOOK_DIR}" "${BOOT_HOOK_DIR}" "${CRON_DIR}" "${LOG_ROT_DIR}"
mkdir -p "${STAGE_DIR}/usr/local/etc/inc/plugins.inc.d"

echo ">>> Generating Plugin Files..."

# --- 1. The DNS Hook Script ---
cat << 'EOF' > "${KEA_SCRIPT_DIR}/kea-unbound-hook.sh"
#!/bin/sh
LOG_FILE="/var/log/kea-unbound.log"
UNBOUND_CONF="/var/unbound/unbound.conf"
# Serialize concurrent executions to prevent dual-stack race conditions
if [ -z "$_KEA_UNBOUND_LOCKED" ]; then
    export _KEA_UNBOUND_LOCKED=1
    exec lockf -k -t 10 /tmp/kea-unbound.lock "$0" "$@"
fi
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }
normalize_hostname() { echo "$1" | tr 'A-Z' 'a-z' | sed 's/\..*//' | sed 's/[^a-z0-9-]//g'; }
get_domain() { D=$(hostname -d 2>/dev/null); [ -z "$D" ] && echo "home.arpa" || echo "$D"; }
reverse_ipv4() { echo "$1" | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa"}'; }
reverse_ipv6() {
    local result
    result=$(/usr/local/bin/python3 -c "import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]).reverse_pointer)" "$1" 2>/dev/null)
    if [ -z "$result" ]; then
        log error "Failed to compute IPv6 reverse pointer for $1"
        return 1
    fi
    echo "$result"
}
get_ptr_name() { [ "$1" = "4" ] && reverse_ipv4 "$2" || reverse_ipv6 "$2"; }
lookup_ips() {
    drill -Q -t "$2" "$1" @127.0.0.1 2>/dev/null | grep -v "^;" | grep -v "^$" | awk '{print $NF}'
}
remove_ptrs_for_ips() {
    local VER="$1"
    while IFS= read -r OLD_IP; do
        [ -z "$OLD_IP" ] && continue
        local OLD_PTR=$(get_ptr_name "$VER" "$OLD_IP")
        [ -n "$OLD_PTR" ] && unbound-control -c "$UNBOUND_CONF" local_data_remove "$OLD_PTR" >/dev/null 2>&1
    done
}
update_dns_entry() {
    local ACTION="$1" IP="$2" HOST="$3" IP_VER="$4"
    [ -z "$IP" ] && return
    HOST=$(normalize_hostname "$HOST"); [ -z "$HOST" ] && return
    local FQDN="$HOST.$(get_domain)"
    local THIS_TYPE="A"; local OTHER_TYPE="AAAA"; local OTHER_VER="6"
    [ "$IP_VER" = "6" ] && THIS_TYPE="AAAA" && OTHER_TYPE="A" && OTHER_VER="4"
    local PTR_NAME=$(get_ptr_name "$IP_VER" "$IP")
    if [ "$ACTION" = "add" ]; then
        local PRESERVED_IP=$(lookup_ips "$FQDN" "$OTHER_TYPE" | head -n 1)
        lookup_ips "$FQDN" "$THIS_TYPE" | remove_ptrs_for_ips "$IP_VER"
        lookup_ips "$FQDN" "$OTHER_TYPE" | sed '1d' | remove_ptrs_for_ips "$OTHER_VER"
        unbound-control -c "$UNBOUND_CONF" local_data_remove "$FQDN" >/dev/null 2>&1
        [ -n "$PTR_NAME" ] && unbound-control -c "$UNBOUND_CONF" local_data_remove "$PTR_NAME" >/dev/null 2>&1
        unbound-control -c "$UNBOUND_CONF" local_data "$FQDN IN $THIS_TYPE $IP" >/dev/null 2>&1
        [ -n "$PTR_NAME" ] && unbound-control -c "$UNBOUND_CONF" local_data "$PTR_NAME PTR $FQDN" >/dev/null 2>&1
        log info "Added $THIS_TYPE for $FQDN ($IP) [PTR: ${PTR_NAME:-FAILED}]"
        if [ -n "$PRESERVED_IP" ]; then
            local PRES_PTR=$(get_ptr_name "$OTHER_VER" "$PRESERVED_IP")
            unbound-control -c "$UNBOUND_CONF" local_data "$FQDN IN $OTHER_TYPE $PRESERVED_IP" >/dev/null 2>&1
            [ -n "$PRES_PTR" ] && unbound-control -c "$UNBOUND_CONF" local_data "$PRES_PTR PTR $FQDN" >/dev/null 2>&1
        fi
    else
        unbound-control -c "$UNBOUND_CONF" local_data_remove "$FQDN IN $THIS_TYPE $IP" >/dev/null 2>&1
        [ -n "$PTR_NAME" ] && unbound-control -c "$UNBOUND_CONF" local_data_remove "$PTR_NAME" >/dev/null 2>&1
        log info "Removed $THIS_TYPE for $FQDN ($IP) [PTR: ${PTR_NAME:-FAILED}]"
    fi
}
if [ -n "$LEASE4_ADDRESS" ]; then
    HOST="$LEASE4_HOSTNAME"; [ -z "$HOST" ] && HOST="device-$(echo "$LEASE4_HWADDR" | tr ':' '-')"
    case "$1" in leases4_committed|lease4_renew) update_dns_entry "add" "$LEASE4_ADDRESS" "$HOST" "4" ;;
    lease4_release|lease4_expire|lease4_decline) update_dns_entry "remove" "$LEASE4_ADDRESS" "$HOST" "4" ;; esac
elif [ -n "$LEASE6_ADDRESS" ]; then
    HOST="$LEASE6_HOSTNAME"; [ -z "$HOST" ] && HOST="device-$(echo "$LEASE6_DUID" | tr ':' '-')"
    case "$1" in leases6_committed|lease6_renew) update_dns_entry "add" "$LEASE6_ADDRESS" "$HOST" "6" ;;
    lease6_release|lease6_expire|lease6_decline) update_dns_entry "remove" "$LEASE6_ADDRESS" "$HOST" "6" ;; esac
fi
EOF
chmod 755 "${KEA_SCRIPT_DIR}/kea-unbound-hook.sh"

cat << 'EOF' > "${KEA_SCRIPT_DIR}/kea-unbound-sync.sh"
#!/bin/sh
LOG_FILE="/var/log/kea-unbound.log"
UNBOUND_CONF="/var/unbound/unbound.conf"
STATE_FILE="/var/db/kea-unbound-sync.state"
KEA_CTRL_URL="${KEA_CTRL_URL:-http://127.0.0.1:8000/}"
TMP_DIR=$(mktemp -d /tmp/kea-unbound-sync.XXXXXX) || exit 1

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if [ -z "$_KEA_UNBOUND_SYNC_LOCKED" ]; then
    export _KEA_UNBOUND_SYNC_LOCKED=1
    exec lockf -k -t 60 /tmp/kea-unbound-sync.lock "$0" "$@"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }
get_domain() { D=$(hostname -d 2>/dev/null); [ -z "$D" ] && echo "home.arpa" || echo "$D"; }
find_bin() {
    for CANDIDATE in "$@"; do
        if [ -x "$CANDIDATE" ]; then
            echo "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

PYTHON3_BIN=$(find_bin /usr/local/bin/python3 /usr/bin/python3)
UNBOUND_CONTROL_BIN=$(find_bin /usr/local/sbin/unbound-control /usr/sbin/unbound-control /usr/local/bin/unbound-control /usr/bin/unbound-control)

[ -z "$PYTHON3_BIN" ] && log error "Sync skipped: required binary missing (python3)" && exit 1
[ -z "$UNBOUND_CONTROL_BIN" ] && log error "Sync skipped: required binary missing (unbound-control)" && exit 1

DOMAIN=$(get_domain)
V4_JSON="$TMP_DIR/lease4.json"
V6_JSON="$TMP_DIR/lease6.json"
DESIRED="$TMP_DIR/desired.tsv"
DESIRED_FQDNS="$TMP_DIR/desired_fqdns"
PREV_FQDNS="$TMP_DIR/prev_fqdns"
PREV_PTRS="$TMP_DIR/prev_ptrs"
CURRENT_PTRS="$TMP_DIR/current_ptrs"

"$PYTHON3_BIN" - "$DOMAIN" "$KEA_CTRL_URL" "$V4_JSON" "$V6_JSON" > "$DESIRED" <<'PY'
import ipaddress
import json
import sys
import urllib.error
import urllib.request

domain, ctrl_url, v4_path, v6_path = sys.argv[1:]

class ServiceOffline(RuntimeError):
    pass

def normalize_hostname(value):
    value = (value or "").lower().split(".", 1)[0]
    return "".join(ch for ch in value if ch.isalnum() or ch == "-")

def fetch_command(command, service, arguments=None):
    payload = json.dumps({
        "command": command,
        "service": [service],
        "arguments": arguments or {}
    }).encode("utf-8")
    try:
        req = urllib.request.Request(
            ctrl_url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"control agent HTTP error for {command}: {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"control agent request failed for {command}: {exc}") from exc
    try:
        payload = json.loads(raw.strip() or "{}")
    except Exception as exc:
        raise RuntimeError(f"invalid JSON from control agent for {command}: {exc}") from exc
    if isinstance(payload, list):
        payload = payload[0] if payload else {}
    result = payload.get("result")
    if result not in (0, 3, None):
        text = payload.get("text", "unknown error")
        if "likely to be offline" in text.lower() or "no such file or directory" in text.lower():
            raise ServiceOffline(text)
        raise RuntimeError(f"Kea rejected lease query for {command}: {text}")
    return payload

def collect_subnet_ids(node, family_key):
    ids = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == family_key and isinstance(value, list):
                for item in value:
                    if isinstance(item, dict) and "id" in item:
                        ids.append(item["id"])
                    ids.extend(collect_subnet_ids(item, family_key))
            else:
                ids.extend(collect_subnet_ids(value, family_key))
    elif isinstance(node, list):
        for item in node:
            ids.extend(collect_subnet_ids(item, family_key))
    return ids

def write_payload(path, payload):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)

def parse_payload(payload):
    return payload.get("arguments", {}).get("leases", [])

def emit(ip, hostname, fallback, record_type, cltt, bucket):
    host = normalize_hostname(hostname) or fallback
    host = normalize_hostname(host)
    if not host:
        return
    fqdn = f"{host}.{domain}"
    existing = bucket.get((fqdn, record_type))
    # Keep only the newest lease per host and address family.
    # If timestamps tie or are missing, newest seen lease wins.
    if existing is None or cltt >= existing[0]:
        bucket[(fqdn, record_type)] = (cltt, ip)

dhcp4_config = fetch_command("config-get", "dhcp4")
try:
    dhcp6_config = fetch_command("config-get", "dhcp6")
except ServiceOffline:
    dhcp6_config = {"arguments": {}}

v4_subnets = sorted(set(collect_subnet_ids(dhcp4_config.get("arguments", {}), "subnet4")))
v6_subnets = sorted(set(collect_subnet_ids(dhcp6_config.get("arguments", {}), "subnet6")))

v4_payload = fetch_command("lease4-get-all", "dhcp4", {"subnets": v4_subnets})
try:
    v6_payload = fetch_command("lease6-get-all", "dhcp6", {"subnets": v6_subnets})
except ServiceOffline:
    v6_payload = {"arguments": {"leases": []}}
write_payload(v4_path, v4_payload)
write_payload(v6_path, v6_payload)

selected = {}

for lease in parse_payload(v4_payload):
    ip = lease.get("ip-address")
    if not ip:
        continue
    hw = (lease.get("hw-address") or "").replace(":", "-")
    cltt = int(lease.get("cltt") or lease.get("expire") or 0)
    emit(ip, lease.get("hostname"), f"device-{hw}", "A", cltt, selected)

for lease in parse_payload(v6_payload):
    ip = lease.get("ip-address")
    if not ip:
        continue
    duid = (lease.get("duid") or "").replace(":", "-")
    cltt = int(lease.get("cltt") or lease.get("expire") or 0)
    emit(ip, lease.get("hostname"), f"device-{duid}", "AAAA", cltt, selected)

for (fqdn, record_type), (_, ip) in sorted(selected.items()):
    ptr = ipaddress.ip_address(ip).reverse_pointer
    print(f"{fqdn}\t{record_type}\t{ip}\t{ptr}")
PY

if [ $? -ne 0 ]; then
    log error "Sync aborted: failed to read leases from Kea Control Agent"
    exit 1
fi

sort -u "$DESIRED" -o "$DESIRED"

if [ -f "$STATE_FILE" ]; then
    awk -F '\t' 'NF >= 4 {print $1 "\t" $2 "\t" $3}' "$STATE_FILE" | sort -u > "$PREV_FQDNS"
    awk -F '\t' 'NF >= 4 {print $4}' "$STATE_FILE" | sort -u > "$PREV_PTRS"
else
    : > "$PREV_FQDNS"
    : > "$PREV_PTRS"
fi

while IFS="$(printf '\t')" read -r FQDN TYPE IP; do
    [ -z "$FQDN" ] && continue
    [ -z "$TYPE" ] && continue
    [ -z "$IP" ] && continue
    "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data_remove "$FQDN IN $TYPE $IP" >/dev/null 2>&1
done < "$PREV_FQDNS"

while IFS= read -r PTR; do
    [ -n "$PTR" ] && "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data_remove "$PTR" >/dev/null 2>&1
done < "$PREV_PTRS"

awk -F '\t' 'NF >= 4 {print $1}' "$DESIRED" | sort -u > "$DESIRED_FQDNS"
: > "$CURRENT_PTRS"
while IFS= read -r FQDN; do
    [ -z "$FQDN" ] && continue
    "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" list_local_data 2>/dev/null | awk -v fqdn="$FQDN" '
        ($2 == "PTR" && $3 == fqdn) {print $1}
        ($3 == "PTR" && $4 == fqdn) {print $1}
    ' >> "$CURRENT_PTRS"
    "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data_remove "$FQDN" >/dev/null 2>&1
done < "$DESIRED_FQDNS"

sort -u "$CURRENT_PTRS" -o "$CURRENT_PTRS"
while IFS= read -r PTR; do
    [ -n "$PTR" ] && "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data_remove "$PTR" >/dev/null 2>&1
done < "$CURRENT_PTRS"

while IFS="$(printf '\t')" read -r FQDN TYPE IP PTR; do
    [ -z "$FQDN" ] && continue
    "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data "$FQDN IN $TYPE $IP" >/dev/null 2>&1
    [ -n "$PTR" ] && "$UNBOUND_CONTROL_BIN" -c "$UNBOUND_CONF" local_data "$PTR PTR $FQDN" >/dev/null 2>&1
done < "$DESIRED"

mkdir -p "$(dirname "$STATE_FILE")"
cp "$DESIRED" "$STATE_FILE"
COUNT=$(wc -l < "$DESIRED" | tr -d ' ')
log info "Synchronized $COUNT lease-backed DNS record(s) from Kea Control Agent"
EOF
chmod 755 "${KEA_SCRIPT_DIR}/kea-unbound-sync.sh"

# --- 2. The Python Patcher Logic ---
PATCH_CMD='import os, shutil
files = [
    {"ctrl": "/usr/local/opnsense/mvc/app/controllers/OPNsense/Kea/forms/generalSettings4.xml", "model": "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.xml", "php": "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php", "anchor": "dhcpv4.general.dhcp_socket_type", "prefix": "dhcpv4", "key": "Dhcp4"},
    {"ctrl": "/usr/local/opnsense/mvc/app/controllers/OPNsense/Kea/forms/generalSettings6.xml", "model": "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.xml", "php": "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php", "anchor": "dhcpv6.general.fwrules", "prefix": "dhcpv6", "key": "Dhcp6"}
]
for fset in files:
    if not os.path.exists(fset["ctrl"]): continue
    for fpath in [fset["ctrl"], fset["model"], fset["php"]]:
        if not os.path.exists(fpath + ".bak"): shutil.copy2(fpath, fpath + ".bak")
    
    with open(fset["ctrl"], "r") as f: content = f.read()
    if "registerDynamicLeases" not in content:
        field = "    <field>\n        <id>" + fset["prefix"] + ".general.registerDynamicLeases</id>\n"
        field += "        <label>Register Leases in Unbound (via os-kea-unbound)</label>\n"
        field += "        <type>checkbox</type>\n        <help>Enable DNS registration (Plugin Feature).</help>\n    </field>\n"
        content = content.replace("<field>\n        <id>" + fset["anchor"], field + "    <field>\n        <id>" + fset["anchor"])
        with open(fset["ctrl"], "w") as f: f.write(content)

    with open(fset["model"], "r") as f: content = f.read()
    if "registerDynamicLeases" not in content:
        m_node = "            <registerDynamicLeases type=\"BooleanField\">\n                <default>0</default>\n            </registerDynamicLeases>\n"
        content = content.replace("</general>", m_node + "        </general>")
        with open(fset["model"], "w") as f: f.write(content)

    with open(fset["php"], "r") as f: content = f.read()
    if "kea-unbound-hook.sh" not in content:
        p_code = "        if ((string)$this->general->registerDynamicLeases === \"1\") {\n"
        p_code += "            if (!isset($cnf[\"" + fset["key"] + "\"][\"hooks-libraries\"])) $cnf[\"" + fset["key"] + "\"][\"hooks-libraries\"] = [];\n"
        p_code += "            $cnf[\"" + fset["key"] + "\"][\"hooks-libraries\"][] = [\"library\" => \"/usr/local/lib/kea/hooks/libdhcp_run_script.so\", \"parameters\" => [\"name\" => \"/usr/local/share/kea/scripts/kea-unbound-hook.sh\", \"sync\" => false]];\n"
        p_code += "        }\n"
        content = content.replace("File::file_put_contents", p_code + "        File::file_put_contents")
        with open(fset["php"], "w") as f: f.write(content)'

# --- 3. Persistence Hooks & Log Rotation ---
HOOK_CONTENT="#!/bin/sh
# Kea-Unbound repair hook
/usr/local/bin/python3 -c '$PATCH_CMD'
rm -rf /var/cache/opnsense/volt/*
/usr/sbin/service configd restart"

echo "$HOOK_CONTENT" > "${UPDATE_HOOK_DIR}/50-keaunbound-repair"
echo "$HOOK_CONTENT" > "${BOOT_HOOK_DIR}/50-keaunbound-repair"
chmod 755 "${UPDATE_HOOK_DIR}/50-keaunbound-repair" "${BOOT_HOOK_DIR}/50-keaunbound-repair"

cat << EOF > "${LOG_ROT_DIR}/keaunbound.conf"
/var/log/kea-unbound.log                644  7     500  * J
EOF

cat << 'EOF' > "${CRON_DIR}/keaunbound"
* * * * * root /usr/local/share/kea/scripts/kea-unbound-sync.sh >/dev/null 2>&1
EOF

# --- 4. Registration ---
echo "<?php function keaunbound_configure() { return; }" > "${STAGE_DIR}/usr/local/etc/inc/plugins.inc.d/keaunbound.inc"

# --- 5. Installation Scripts ---
cat << EOF > "${BUILD_DIR}/+POST_INSTALL"
#!/bin/sh
mkdir -p /usr/local/share/kea/scripts
chmod 755 /usr/local/share/kea /usr/local/share/kea/scripts
touch /var/log/kea-unbound.log
chmod 644 /var/log/kea-unbound.log
/usr/local/bin/python3 -c '$PATCH_CMD'
rm -rf /var/cache/opnsense/volt/*
/usr/sbin/service configd restart
/usr/local/share/kea/scripts/kea-unbound-sync.sh >/dev/null 2>&1 || true
echo "Plugin installed. Please go to Services > Kea DHCP > Settings."
EOF

cat << 'EOF' > "${BUILD_DIR}/+PRE_DEINSTALL"
#!/bin/sh
restore() { [ -f "$1.bak" ] && mv "$1.bak" "$1"; }
restore "/usr/local/opnsense/mvc/app/controllers/OPNsense/Kea/forms/generalSettings4.xml"
restore "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.xml"
restore "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php"
restore "/usr/local/opnsense/mvc/app/controllers/OPNsense/Kea/forms/generalSettings6.xml"
restore "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.xml"
restore "/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php"
/usr/sbin/service configd restart
EOF
chmod +x "${BUILD_DIR}/+POST_INSTALL" "${BUILD_DIR}/+PRE_DEINSTALL"

# --- 6. Manifest & Packing List ---
cat << EOF > "${BUILD_DIR}/+MANIFEST"
name: ${PLUGIN_NAME}
version: "${VERSION}"
origin: opnsense/${PLUGIN_NAME}
comment: Kea DHCP to Unbound DNS dynamic registration
desc: Integrates Kea DHCPv4/v6 with Unbound DNS (Robust & Persistent)
maintainer: james@jmuk.net
www: https://github.com/JameZUK/os-kea-unbound
prefix: /
categories: [sysutils]
licenselogic: single
licenses: [BSD2CLAUSE]
EOF

cat << EOF > "${BUILD_DIR}/plist"
/usr/local/share/kea/scripts/kea-unbound-hook.sh
/usr/local/share/kea/scripts/kea-unbound-sync.sh
/usr/local/etc/inc/plugins.inc.d/keaunbound.inc
/usr/local/etc/rc.syshook.d/update/50-keaunbound-repair
/usr/local/etc/rc.syshook.d/early/50-keaunbound-repair
/usr/local/etc/cron.d/keaunbound
/usr/local/etc/newsyslog.conf.d/keaunbound.conf
EOF

echo ">>> Building Package..."
pkg create -m "${BUILD_DIR}" -r "${STAGE_DIR}" -p "${BUILD_DIR}/plist" -o .

echo "--------------------------------------------------------"
echo " Build Complete!"
echo " 1. REMOVE OLD: pkg delete os-kea-unbound"
echo " 2. INSTALL:    pkg add ./${PLUGIN_NAME}-${VERSION}.pkg"
echo " 3. LOGS:       tail -f /var/log/kea-unbound.log"
echo "--------------------------------------------------------"
