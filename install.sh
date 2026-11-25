#!/usr/bin/env bash
# loxsicmp installer/manager. Original implementation; Debian/Ubuntu + systemd.
set -Eeuo pipefail
umask 077
REPOSITORY="${LOXSICMP_REPO:-roxasblessed403-design/loxsicmp}"
REFERENCE="${LOXSICMP_REF:-main}"
PREFIX=/opt/loxsicmp
CONFIG=/etc/loxsicmp/config.json
STATE=/var/lib/loxsicmp
GO_VERSION=1.27.3
MANAGER_VERSION=0.5.3
INSTALL_MODE="${LOXSICMP_INSTALL_MODE:-auto}"
workdir=""
trap '[[ -z "$workdir" ]] || rm -rf -- "$workdir"' EXIT

say(){ printf '%s\n' "$*"; }
ask(){ local _ask_target=$1 _ask_prompt=$2 _ask_default=${3:-} _ask_value; read -r -p "$_ask_prompt ${_ask_default:+[$_ask_default] }" _ask_value </dev/tty; printf -v "$_ask_target" '%s' "${_ask_value:-$_ask_default}"; }
yesno(){ local answer; ask answer "$1 [y/N]:" "n"; [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; }
require_root(){ [[ $EUID -eq 0 ]] || { say 'Run as root: sudo bash install.sh'; exit 1; }; [[ -r /dev/tty ]] || { say 'An interactive terminal is required.'; exit 1; }; command -v systemctl >/dev/null || { say 'systemd is required.'; exit 1; }; }
require_installed(){ [[ -x $PREFIX/loxsicmp && -f $CONFIG ]] || { say 'Install loxsicmp first.'; return 1; }; }
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
get_port(){ local answer; while :;do ask answer 'Web panel port:' '8443';if valid_port "$answer";then printf -v "$1" '%s' "$((10#$answer))";return;fi;say 'Enter a port from 1 to 65535.';done; }
packages(){
 command -v apt-get >/dev/null || { say 'This installer supports Debian/Ubuntu. See README for manual Linux installation.'; return 1; }
 local missing=() package
 for package in ca-certificates curl tar python3 openssl iproute2 procps;do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed';then missing+=("$package");fi
 done
 if (( ${#missing[@]} ));then apt-get update;apt-get install -y --no-install-recommends "${missing[@]}";fi
}
download(){ curl --fail --location --show-error --connect-timeout 15 --max-time 180 --retry 2 --proto '=https' --tlsv1.2 "$1" -o "$2"; }
validate_source(){
 [[ $REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { say 'Invalid GitHub repository.';return 1; }
 [[ $REFERENCE =~ ^[A-Za-z0-9_.-]+$ ]] || { say 'Invalid source ref.';return 1; }
}

temporary(){ [[ -n $workdir ]] || workdir=$(mktemp -d /tmp/loxsicmp-install.XXXXXXXX); }
source_tree(){
 local local_dir="";if [[ -f ${BASH_SOURCE[0]} ]];then local_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd);fi
 if [[ -n $local_dir && -f $local_dir/go.mod && -d $local_dir/cmd/loxsicmp ]];then printf -v "$1" '%s' "$local_dir";return;fi
 validate_source || return
 temporary;download "https://codeload.github.com/$REPOSITORY/tar.gz/$REFERENCE" "$workdir/source.tar.gz"
 local source_path;source_path=$(mktemp -d "$workdir/source.XXXXXXXX");tar -xzf "$workdir/source.tar.gz" -C "$source_path" --strip-components=1
 [[ -f $source_path/go.mod && -f $source_path/install.sh ]] || { say 'Source archive is not loxsicmp.';return 1; };printf -v "$1" '%s' "$source_path"
}
go_binary(){
 local current="";if command -v go >/dev/null;then current=$(go env GOVERSION);fi
 if [[ $current =~ ^go1\.([0-9]+) ]] && (( ${BASH_REMATCH[1]} >= 26 ));then printf -v "$1" '%s' "$(command -v go)";return;fi
 if [[ -x $workdir/go/bin/go ]];then printf -v "$1" '%s' "$workdir/go/bin/go";return;fi
 local arch checksum;case $(uname -m) in
 x86_64)arch=amd64;checksum=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40;;
 aarch64|arm64)arch=arm64;checksum=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49;;
 *)say 'Unsupported architecture. Linux amd64 and arm64 are supported.';return 1;;esac
 temporary;download "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" "$workdir/go.tar.gz" || return
 printf '%s  %s\n' "$checksum" "$workdir/go.tar.gz" | sha256sum -c - || return
 tar -xzf "$workdir/go.tar.gz" -C "$workdir" || return;printf -v "$1" '%s' "$workdir/go/bin/go"
}
credentials(){
 while :;do ask admin_username 'Panel username:' 'admin';if (( ${#admin_username} >= 1 && ${#admin_username} <= 64 ));then break;fi;say 'Use 1–64 characters for the username.';done
 while :;do read -r -s -p 'Panel password (12+ characters; blank generates one): ' admin_password </dev/tty;printf '\n';if [[ -z $admin_password ]];then admin_password=$(openssl rand -base64 24);say "Generated password: $admin_password";break;fi;if (( ${#admin_password} >= 12 && ${#admin_password} <= 256 ));then break;fi;say 'Use 12–256 characters.';done
}
credentials_json(){ printf '%s\0%s' "$admin_username" "$admin_password" | python3 -c 'import sys,json;u,p=sys.stdin.buffer.read().decode().split("\0",1);print(json.dumps({"username":u,"password":p}))'; }
edit_config(){ python3 - "$CONFIG" "$@" <<'PY'
import json,sys,os,tempfile
p=sys.argv[1];d=json.load(open(p))
for key,value in zip(sys.argv[2::2],sys.argv[3::2]): d[key]=value
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p));os.fchmod(fd,0o640)
with os.fdopen(fd,'w') as f: json.dump(d,f,indent=2);f.flush();os.fsync(f.fileno())
os.chown(tmp,0,__import__('grp').getgrnam('loxsicmp').gr_gid);os.replace(tmp,p)
PY
}
install_service(){
 cat > /etc/systemd/system/loxsicmp.service <<'UNIT'
[Unit]
Description=loxsicmp web management panel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
User=loxsicmp
Group=loxsicmp
WorkingDirectory=/opt/loxsicmp
ExecStart=/opt/loxsicmp/loxsicmp serve --config /etc/loxsicmp/config.json
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
RuntimeDirectory=loxsicmp
RuntimeDirectoryMode=0700
AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_PACKET AF_NETLINK
ReadWritePaths=/var/lib/loxsicmp /run/loxsicmp
UMask=0077
LimitNOFILE=65536
MemoryMax=768M
TasksMax=2048
[Install]
WantedBy=multi-user.target
UNIT
 systemctl daemon-reload
}
echo_suppression(){
 if [[ ! -f /etc/loxsicmp/icmp-echo.previous ]];then cat /proc/sys/net/ipv4/icmp_echo_ignore_all > /etc/loxsicmp/icmp-echo.previous;fi
 say 'Disabling ordinary kernel echo replies to prevent duplicate tunnel replies.'
 printf 'net.ipv4.icmp_echo_ignore_all = 1\n' >/etc/sysctl.d/90-loxsicmp.conf
 sysctl -w net.ipv4.icmp_echo_ignore_all=1
}
network_tuning(){
 require_installed
 if [[ ! -f $PREFIX/network_tuning.py ]];then say 'Network helper is missing; update loxsicmp first.';return 1;fi
 python3 "$PREFIX/network_tuning.py" "${1:-apply}"
}
certificate(){
 local domain email panel_port;require_installed
 panel_port=$(python3 -c 'import json;print(json.load(open("/etc/loxsicmp/config.json"))["panel_listen"].rsplit(":",1)[1])')
 [[ $panel_port != 80 ]] || { say 'Move the panel away from port 80 before using standalone Certbot.';return 1; }
 ask domain 'Domain pointing to this server (e.g. panel.example.com):'
 [[ $domain =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || { say 'Enter a domain, not an IP or URL.';return 1; }
 ask email 'Email for certificate expiry notices:'
 [[ $email == *@*.* && $email != -* ]] || { say 'Invalid email.';return 1; }
 if [[ -n $(ss -H -ltn 'sport = :80') ]];then say 'Port 80 is already occupied. Free it before requesting a certificate.';return 1;fi
 if ! command -v certbot >/dev/null;then
  apt-get update || return 1
  apt-get install -y --no-install-recommends certbot || return 1
 fi
 say 'The domain must resolve to this server, with incoming TCP port 80 reachable.'
 certbot certonly --standalone --non-interactive --agree-tos --email "$email" --cert-name loxsicmp -d "$domain" || return 1
 install -d -m 0750 -o root -g loxsicmp /etc/loxsicmp/tls
 install -m 0640 -o root -g loxsicmp /etc/letsencrypt/live/loxsicmp/fullchain.pem /etc/loxsicmp/tls/fullchain.pem || return 1
 install -m 0640 -o root -g loxsicmp /etc/letsencrypt/live/loxsicmp/privkey.pem /etc/loxsicmp/tls/privkey.pem || return 1
 edit_config tls_cert /etc/loxsicmp/tls/fullchain.pem tls_key /etc/loxsicmp/tls/privkey.pem panel_listen "0.0.0.0:$panel_port" || return 1
 install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
 cat >/etc/letsencrypt/renewal-hooks/deploy/loxsicmp <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${RENEWED_LINEAGE:-} == /etc/letsencrypt/live/loxsicmp ]] || exit 0
install -m 0640 -o root -g loxsicmp "$RENEWED_LINEAGE/fullchain.pem" /etc/loxsicmp/tls/fullchain.pem
install -m 0640 -o root -g loxsicmp "$RENEWED_LINEAGE/privkey.pem" /etc/loxsicmp/tls/privkey.pem
systemctl kill --kill-whom=main --signal=HUP loxsicmp.service
HOOK
 chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/loxsicmp
 cat >/etc/systemd/system/loxsicmp-renew.service <<'UNIT'
[Unit]
Description=Renew loxsicmp TLS certificate
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --cert-name loxsicmp --quiet
UNIT
 cat >/etc/systemd/system/loxsicmp-renew.timer <<'UNIT'
[Unit]
Description=Automatic loxsicmp certificate renewal
[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
 systemctl daemon-reload || return 1
 systemctl enable --now loxsicmp-renew.timer || return 1
 systemctl restart loxsicmp.service || return 1
 wait_healthy || { say 'Service failed its health check; inspect Recent logs.';return 1; }
 say "HTTPS enabled: https://$domain:$panel_port . Renewals reload TLS without restarting the ICMP core."
}
install_loxsicmp(){
 local restoring=n
 if [[ -f $CONFIG ]];then
  if [[ -x $PREFIX/loxsicmp ]];then say 'Already installed. Select Update (2) to install this version while preserving users and settings.';return;fi
  restoring=y;say 'Reinstalling with retained configuration and users.'
 fi
 packages
 local source_dir panel_port public_host bind_address use_ssl=n endpoint_family=ipv4 packet_reader=raw_ip detected="" choice
 source_tree source_dir
 if [[ $restoring == n ]];then
 get_port panel_port
 if [[ -n $(ss -H -ltn "sport = :$panel_port") ]];then say "TCP port $panel_port is already occupied. Choose a free panel port.";return 1;fi
 while :;do ask choice 'Connection address family: 1) IPv4  2) IPv6' '1';case $choice in 1|4|ipv4)endpoint_family=ipv4;break;;2|6|ipv6)endpoint_family=ipv6;break;;*)say 'Choose IPv4 or IPv6.';;esac;done
 detected=$(python3 "$source_dir/scripts/detect_addresses.py" "$endpoint_family")
 say "Detected $endpoint_family: ${detected:-not detected; use an explicit IP/domain or configure detection later}"
 ask public_host 'Connection IP or domain (blank uses automatic detection):' "$detected"
 say 'RAW IP is the default. AF_PACKET is advanced local capture, not an upstream blocking bypass. NEW is a firewall state.'
 while :;do ask choice 'Packet reader: 1) Raw IP socket  2) Raw packet capture (Linux)' '1';case $choice in 1)packet_reader=raw_ip;break;;2)packet_reader=raw_packet;break;;*)say 'Choose 1 or 2.';;esac;done
 if yesno 'Obtain SSL for the web panel with Certbot?';then use_ssl=y;[[ $panel_port != 80 ]] || { say 'Choose a panel port other than 80 for SSL.';return 1; };fi
 bind_address=0.0.0.0
 if [[ $endpoint_family == ipv6 ]];then bind_address='[::]';fi
 if [[ $use_ssl == n ]] && yesno 'Access HTTP only through localhost + SSH tunnel?';then bind_address=127.0.0.1;fi
 credentials
 else
  panel_port=$(python3 -c 'import json;print(json.load(open("/etc/loxsicmp/config.json"))["panel_listen"].rsplit(":",1)[1])')
  bind_address=$(python3 -c 'import json;print(json.load(open("/etc/loxsicmp/config.json"))["panel_listen"].rsplit(":",1)[0])')
  public_host=$(python3 -c 'import json;print(json.load(open("/etc/loxsicmp/config.json"))["public_host"])')
 fi
 build_candidate "$source_dir"
 getent group loxsicmp >/dev/null || groupadd --system loxsicmp
 id -u loxsicmp >/dev/null 2>&1 || useradd --system --gid loxsicmp --home-dir "$STATE" --shell /usr/sbin/nologin loxsicmp
 install -d -m 0755 "$PREFIX";install -m 0755 "$workdir/loxsicmp" "$PREFIX/loxsicmp"
 install -m 0755 "$source_dir/install.sh" "$PREFIX/manager.sh"
 install -m 0644 "$source_dir/scripts/network_tuning.py" "$PREFIX/network_tuning.py"
 cat >/usr/local/bin/loxsicmp <<'WRAPPER'
#!/usr/bin/env bash
exec bash /opt/loxsicmp/manager.sh "$@"
WRAPPER
 chmod 0755 /usr/local/bin/loxsicmp
 install -d -m 0750 -o root -g loxsicmp /etc/loxsicmp
 install -d -m 0700 -o loxsicmp -g loxsicmp "$STATE"
 if [[ $restoring == n ]];then credentials_json | "$PREFIX/loxsicmp" init --config "$CONFIG" --state "$STATE/state.json" --listen "$bind_address:$panel_port" --public-host "$public_host" --family "$endpoint_family" --packet-reader "$packet_reader";unset admin_password;fi
 chown -R loxsicmp:loxsicmp "$STATE";chown root:loxsicmp "$CONFIG";chmod 0640 "$CONFIG"
 remember_source
 install_service;echo_suppression
 network_tuning apply || say 'Some network settings could not be applied; installation continues. Review the warning above.'
 systemctl enable loxsicmp.service
 if [[ $use_ssl == y ]];then if ! certificate;then systemctl stop loxsicmp.service || true;say 'SSL setup failed; the panel stays stopped. Correct DNS/port 80 and retry menu option 8.';return 1;fi
 else
  systemctl start loxsicmp.service
  wait_healthy || { say 'Service failed its health check; inspect Recent logs.';return 1; }
  if [[ $restoring == y ]];then say 'Retained configuration restored; check Status for the configured HTTP/HTTPS address.'
  elif [[ $bind_address == 127.0.0.1 ]];then say "SSH tunnel: ssh -N -L $panel_port:127.0.0.1:$panel_port root@$public_host";say "Open http://127.0.0.1:$panel_port"
  else local url_host=${public_host:-SERVER_IP};[[ $url_host != *:* || $url_host == \[*\] ]] || url_host="[$url_host]";say "Panel: http://$url_host:$panel_port";fi
 fi
 say 'Allow the panel TCP port and ICMPv4/ICMPv6 in host/provider firewalls. Do not block ICMPv6 neighbor discovery or Packet Too Big. Run loxsicmp to reopen this menu.'
}
remember_source(){
  python3 - "$REPOSITORY" "$REFERENCE" <<'PY'
import json,sys,os
with open('/etc/loxsicmp/source.json','w') as f: json.dump({'repository':sys.argv[1],'reference':sys.argv[2]},f)
os.chmod('/etc/loxsicmp/source.json',0o600)
PY
}
release_candidate(){
 local arch asset base checksum
 case $(uname -m) in x86_64)arch=amd64;;aarch64|arm64)arch=arm64;;*)say 'Unsupported architecture.';return 1;;esac
 asset="loxsicmp-linux-$arch.tar.gz"
 base="https://github.com/$REPOSITORY/releases/download/v$MANAGER_VERSION"
 temporary
 # Return 2 only for unavailable downloads; integrity failures must never fall back.
 download "$base/SHA256SUMS" "$workdir/SHA256SUMS" || return 2
 download "$base/$asset" "$workdir/$asset" || return 2
 checksum=$(awk -v file="$asset" '$2==file {print $1}' "$workdir/SHA256SUMS")
 [[ $checksum =~ ^[a-f0-9]{64}$ ]] || { say 'Missing or invalid release checksum.';return 1; }
 printf '%s  %s\n' "$checksum" "$workdir/$asset" | sha256sum -c - || return 1
 # Extract only the executable, never archive paths or arbitrary release files.
 tar -xzf "$workdir/$asset" -C "$workdir" --no-same-owner loxsicmp || return 1
 chmod 0755 "$workdir/loxsicmp" || return 1
 [[ $("$workdir/loxsicmp" version) == "$MANAGER_VERSION" ]] || { say 'Release version mismatch.';return 1; }
 say "Verified prebuilt release $MANAGER_VERSION ($arch). No Go installation needed."
}
build_candidate(){
 local source_dir=$1 go_cmd result=0 local_dir="" source_version
 validate_source || return
 # Resolve the release from the selected source, so an installed old manager
 # can update to the current main version rather than reinstalling itself.
 source_version=$(sed -n 's/^const version = "\(.*\)"$/\1/p' "$source_dir/cmd/loxsicmp/main.go")
 [[ $source_version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || { say 'Invalid source version.';return 1; }
 MANAGER_VERSION=$source_version
 case $INSTALL_MODE in auto|binary|source);;*)say 'LOXSICMP_INSTALL_MODE must be auto, binary or source.';return 1;;esac
 if [[ -f ${BASH_SOURCE[0]} ]];then local_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd);fi
 # Local checkouts and custom refs build their own code. Never silently replace it with a release.
 if [[ $INSTALL_MODE == binary || $INSTALL_MODE == auto && $REFERENCE == main && ! -f $local_dir/go.mod ]];then
  if release_candidate;then return;else result=$?;fi
  if [[ $INSTALL_MODE == binary || $result != 2 ]];then return "$result";fi
  say 'Prebuilt release unavailable; falling back to a source build (slower).'
 fi
 temporary;go_binary go_cmd || return
 say "Building loxsicmp $MANAGER_VERSION from source. Existing tunnels keep running."
 (cd "$source_dir" || exit; if [[ ${LOXSICMP_RUN_TESTS:-0} == 1 ]];then GOTOOLCHAIN=local "$go_cmd" test ./... || exit;fi;CGO_ENABLED=0 GOTOOLCHAIN=local "$go_cmd" build -buildvcs=false -trimpath -ldflags='-s -w' -o "$workdir/loxsicmp" ./cmd/loxsicmp)
}

wait_healthy(){
 local attempt
 for attempt in {1..30};do
  if "$PREFIX/loxsicmp" diagnostics >/dev/null 2>&1;then return;fi
  sleep 0.2
 done
 return 1
}
update_loxsicmp(){
 require_installed
 local source_dir was_running=n backup_dir state_file
 source_tree source_dir;build_candidate "$source_dir"
 systemctl is-active --quiet loxsicmp.service && was_running=y
 install -d -m 0700 "$STATE/backups"
 backup_dir=$(mktemp -d "$STATE/backups/$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX")
 say 'Applying update. Active tunnels will reconnect once.'
 state_file=$(python3 - "$CONFIG" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['state_path'])
PY
)
 cp -p -- "$CONFIG" "$backup_dir/config.json"
 cp -p -- "$PREFIX/loxsicmp" "$backup_dir/loxsicmp.previous"
 # Copy before stopping: a full disk must not interrupt the running version.
 install -m 0755 "$workdir/loxsicmp" "$PREFIX/loxsicmp.next"
 # Refresh the address-family allowlist before downtime, also for stopped services.
 install_service
 systemctl stop loxsicmp.service
 if ! cp -p -- "$state_file" "$backup_dir/state.json";then
  rm -f -- "$PREFIX/loxsicmp.next"
  [[ $was_running != y ]] || systemctl start loxsicmp.service
  say 'Unable to create state backup; update aborted before replacing the binary.';return 1
 fi
 if ! mv -f -- "$PREFIX/loxsicmp.next" "$PREFIX/loxsicmp";then
  [[ $was_running != y ]] || systemctl start loxsicmp.service
  say 'Unable to replace executable; previous version retained.';return 1
 fi
 if [[ $was_running == y ]];then
  local healthy=n
  if systemctl start loxsicmp.service;then
   if wait_healthy;then healthy=y;fi
  fi
  if [[ $healthy != y ]];then
   systemctl stop loxsicmp.service || true
   install -m 0755 "$backup_dir/loxsicmp.previous" "$PREFIX/loxsicmp.rollback"
   mv -f -- "$PREFIX/loxsicmp.rollback" "$PREFIX/loxsicmp"
   systemctl start loxsicmp.service || true
   say "Update failed health validation. Previous binary restored; user state kept. Backup: $backup_dir"
   return 1
  fi
 fi
 install -m 0755 "$source_dir/install.sh" "$PREFIX/manager.sh"
 install -m 0644 "$source_dir/scripts/network_tuning.py" "$PREFIX/network_tuning.py"
 network_tuning apply || say 'Network tuning could not be completed; the updated service is kept running.'
 remember_source
 say "Updated to $("$PREFIX/loxsicmp" version). Users, quotas, panel credentials, port and TLS settings preserved."
 say "Backup: $backup_dir"
}
change_port(){ require_installed;local panel_port bind_address;get_port panel_port;if [[ $panel_port == 80 ]] && python3 -c 'import json,sys;sys.exit(not bool(json.load(open("/etc/loxsicmp/config.json"))["tls_cert"]))';then say 'Port 80 must remain available for Certbot renewal.';return 1;fi;bind_address=$(python3 -c 'import json;print(json.load(open("/etc/loxsicmp/config.json"))["panel_listen"].rsplit(":",1)[0])');edit_config panel_listen "$bind_address:$panel_port";systemctl restart loxsicmp.service;say "Panel port changed to $panel_port. Restarting the service.";}
