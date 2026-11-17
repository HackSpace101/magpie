#!/usr/bin/env bash
# magpie.sh — one-command Docker deployment of this fork's magpie gateway.
#
#   sudo bash magpie.sh install --public IP  first install (plain HTTP on IP), or again to change options
#   sudo magpiectl upgrade [--tag T]           pull a new image and switch to it, rolling back on failure
#   sudo magpiectl rollback                    back to the image before the last upgrade
#   magpiectl status | logs | url | version    look at it
#   sudo magpiectl backup                      a backup of the data folder
#   sudo magpiectl key add <name>              a gateway key for a client
#   sudo magpiectl tune                        the host's kernel and file limits only
#   sudo magpiectl self-update                 this script, from the repo
#
# install copies this script to <dir>/magpie.sh and links /usr/local/bin/magpiectl
# to it. Everything else lives in <dir> (default /opt/magpie): compose.yaml,
# .env (the web key and settings, mode 600), config/ (magpie's data),
# caddy/ (HTTPS), backups/. No secret is ever written into the repo.
#
# Docs: docs/fork/deploy-docker.md
set -Eeuo pipefail

SCRIPT_VERSION=2026.11.17
DEFAULT_DIR=/opt/magpie
DEFAULT_IMAGE=ghcr.io/hackspace101/magpie-gateway
DEFAULT_SCRIPT_URL=https://raw.githubusercontent.com/HackSpace101/magpie/main/deploy/docker/magpie.sh
# the image runs as nonroot, uid and gid 65532
CONTAINER_UID=65532
KEEP_BACKUPS=10
HEALTH_WAIT=180

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
	c_red=$'\e[31m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_bold=$'\e[1m' c_dim=$'\e[2m' c_off=$'\e[0m'
else
	c_red='' c_green='' c_yellow='' c_bold='' c_dim='' c_off=''
fi
say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$c_bold" "$c_off" "$*"; }
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die() {
	printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2
	exit 1
}
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

# ---------------------------------------------------------------- helpers

DRY_RUN=0
ASSUME_YES=0

# the folder of the install this script belongs to: its own folder when it
# is the installed copy, else MAGPIE_DIR or the default
here_dir() {
	local self
	self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
	if [ -f "$(dirname "$self")/compose.yaml" ] && [ -f "$(dirname "$self")/.env" ]; then
		dirname "$self"
	else
		printf '%s' "${MAGPIE_DIR:-$DEFAULT_DIR}"
	fi
}

need_root() {
	[ "$DRY_RUN" = 1 ] && return 0
	[ "$(id -u)" = 0 ] || die "run it as root: sudo $0 $*"
}

confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ -t 0 ] || return 1
	local a
	read -r -p "$1 [y/N] " a
	[[ $a == [yY]* ]]
}

# random_key prints 32 hex characters
random_key() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 16
	else
		od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
	fi
}

# env_get KEY prints KEY's value in $ENV_FILE, empty when it has none
env_get() {
	[ -f "$ENV_FILE" ] || return 0
	awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$ENV_FILE"
}

# env_get_at FILE KEY DEFAULT is env_get on FILE, DEFAULT when it has none
env_get_at() {
	local v
	v=$(ENV_FILE=$1 env_get "$2")
	printf '%s' "${v:-$3}"
}

# env_set KEY VALUE writes KEY=VALUE into $ENV_FILE, replacing the line it had
env_set() {
	local k=$1 v=$2 tmp
	case $v in *$'\n'*) die "a value for $k can't hold a new line" ;; esac
	tmp=$(mktemp "$ENV_FILE.XXXXXX")
	if [ -f "$ENV_FILE" ]; then
		awk -v k="$k" 'index($0, k "=") != 1' "$ENV_FILE" >"$tmp"
	fi
	printf '%s=%s\n' "$k" "$v" >>"$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$ENV_FILE"
}

compose() { (cd "$DIR" && docker compose "$@"); }

# image_digest REF prints REF's repo digest (name@sha256:…), empty when it has none
image_digest() {
	docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null | head -n 1
}

# wait_healthy waits for the magpie container's health check, for $HEALTH_WAIT seconds at most
wait_healthy() {
	local i s
	for ((i = 0; i < HEALTH_WAIT; i += 3)); do
		s=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' magpie 2>/dev/null || true)
		case $s in
		healthy) return 0 ;;
		exited | dead) return 1 ;;
		esac
		sleep 3
	done
	return 1
}

running_version() {
	docker exec magpie magpie version 2>/dev/null | head -n 1 || true
}

# ---------------------------------------------------------------- host tuning

# The host's limits for many connections at once. The container's own
# network limits are set in compose.yaml (sysctls), since a container has
# its own network namespace; fs.* are the host's only.
SYSCTL_FILE=/etc/sysctl.d/99-magpie.conf
tune_host() {
	step "Tuning the host for many connections ($SYSCTL_FILE)"
	local conf
	conf=$(
		cat <<'EOF'
# Written by magpie.sh (deploy/docker). Delete this file and run
# `sysctl --system` to undo it.

# open files: the container is given 1048576 (compose.yaml ulimits),
# which needs fs.nr_open at least that
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# accept queues for bursts of new connections (Caddy, docker-proxy)
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384

# outgoing connections to the vendors: more local ports, ports in
# TIME_WAIT reused sooner
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# long streams through NAT: find dead peers within ~8 minutes
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF
	)
	# Docker's NAT tracks every connection; the default table fills under load
	if [ -e /proc/sys/net/netfilter/nf_conntrack_max ] || modprobe -q nf_conntrack 2>/dev/null; then
		conf+=$'\n\n# connections Docker NAT tracks\nnet.netfilter.nf_conntrack_max = 1048576'
	fi
	if [ "$DRY_RUN" = 1 ]; then
		say "$conf"
		return 0
	fi
	printf '%s\n' "$conf" >"$SYSCTL_FILE"
	# a key this kernel lacks is reported, the rest still applied
	if ! sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>"$DIR/.sysctl.err"; then
		warn "some kernel settings didn't apply on this host:"
		sed 's/^/    /' "$DIR/.sysctl.err" >&2 || true
	fi
	rm -f "$DIR/.sysctl.err"
	ok "kernel settings applied (fs.file-max=$(sysctl -n fs.file-max), somaxconn=$(sysctl -n net.core.somaxconn))"

	# Docker's own limit for the processes it starts (docker-proxy among them)
	if [ -d /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
		local dropin=/etc/systemd/system/docker.service.d/99-magpie-limits.conf
		if [ ! -f "$dropin" ]; then
			mkdir -p "$(dirname "$dropin")"
			printf '# Written by magpie.sh\n[Service]\nLimitNOFILE=1048576\n' >"$dropin"
			systemctl daemon-reload
			ok "Docker's open-file limit set to 1048576 (takes effect when Docker next restarts)"
		fi
	fi
}

# ---------------------------------------------------------------- files

write_compose() {
	cat >"$1" <<'EOF'
# Written by magpie.sh install (deploy/docker). Settings are in .env next to
# this file; run `magpiectl install` again after changing what this file holds.
name: magpie

x-limits: &limits
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  # the container's own network namespace; the host's are set by `magpiectl tune`
  sysctls:
    net.core.somaxconn: 65535
    net.ipv4.ip_local_port_range: "10240 65535"
    net.ipv4.tcp_tw_reuse: 1
    net.ipv4.tcp_fin_timeout: 15
  logging:
    driver: json-file
    options:
      max-size: 50m
      max-file: "5"

services:
  magpie:
    <<: *limits
    image: ${MAGPIE_IMAGE_REF:?set MAGPIE_IMAGE_REF in .env}
    container_name: magpie
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    # the gateway (3425) and the web UI (3430); the web port answers the
    # gateway's /v1 routes too, with a gateway key
    command: [web, --addr, "0.0.0.0:3430", --no-open]
    environment:
      MAGPIE_WEB_KEY: ${MAGPIE_WEB_KEY:?set MAGPIE_WEB_KEY in .env}
      MAGPIE_PLUGIN_STREAMS: ${MAGPIE_PLUGIN_STREAMS:-2048}
      MAGPIE_PUBLIC_URL: ${MAGPIE_PUBLIC_URL:-}
      MAGPIE_WEB_URL: ${MAGPIE_WEB_URL:-}
      MAGPIE_ALLOW_IPS: ${MAGPIE_ALLOW_IPS:-}
      TZ: ${TZ:-Asia/Shanghai}
    ports:
      - "${MAGPIE_BIND:-127.0.0.1}:${MAGPIE_GATEWAY_PORT:-3425}:3425"
      # the web UI holds magpie's admin key: on this host only unless --web-bind
      - "${MAGPIE_WEB_BIND:-127.0.0.1}:${MAGPIE_WEB_PORT:-3430}:3430"
    volumes:
      - ./config:/config

  # HTTPS in front of magpie, with a certificate from Let's Encrypt; on
  # when .env has COMPOSE_PROFILES=https (install --domain)
  caddy:
    <<: *limits
    image: ${CADDY_IMAGE:-caddy:2}
    container_name: magpie-caddy
    profiles: [https]
    restart: unless-stopped
    depends_on:
      magpie:
        condition: service_healthy
    environment:
      MAGPIE_DOMAIN: ${MAGPIE_DOMAIN:-}
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
EOF
}

write_caddyfile() {
	cat >"$1" <<'EOF'
# Written by magpie.sh install. Caddy gets and renews the certificate for
# MAGPIE_DOMAIN by itself (ports 80 and 443 must reach this host), and adds
# X-Forwarded-For, so magpie answers every request it passes on as one from
# another machine: a gateway key is needed.
{$MAGPIE_DOMAIN} {
	reverse_proxy magpie:3430 {
		# streams (SSE) go out as they come
		flush_interval -1
	}
}
EOF
}

# ---------------------------------------------------------------- commands

usage() {
	cat <<'EOF'
magpie.sh — one-command Docker deployment of this fork's magpie gateway.

  sudo bash magpie.sh install --public IP  first install (plain HTTP on IP), or again to change options
  sudo magpiectl upgrade [--tag T]        pull a new image and switch to it, back on failure
  sudo magpiectl rollback [--restore F]   back to the image before the last upgrade
  magpiectl status | logs [svc] | url     look at it
  sudo magpiectl backup                   a backup of the data folder
  sudo magpiectl key add <name>           a gateway key for a client
  sudo magpiectl restart                  restart magpie
  sudo magpiectl tune                     the host's kernel and file limits only
  sudo magpiectl self-update              this script, from the repo

EOF
	cat <<EOF
install options:
  --public IP         serve the gateway to other machines on this host's IP, over
                      plain HTTP (http://IP:3425); the web UI stays on this host
  --dir DIR           where it all lives (default $DEFAULT_DIR)
  --image IMAGE       the image, without a tag (default $DEFAULT_IMAGE)
  --tag TAG           the image tag (default latest)
  --bind ADDR         the host address the gateway's port is published on
                      (default 127.0.0.1; 0.0.0.0 for every interface)
  --web-bind ADDR     the same for the web UI's port (default 127.0.0.1: reach
                      it through ssh -L); 0.0.0.0 sends its admin key in the clear
  --gateway-port N    the host port for the gateway (default 3425)
  --web-port N        the host port for the web UI (default 3430)
  --streams N         MAGPIE_PLUGIN_STREAMS, plugin fetches at once (default 2048)
  --public-url URL    MAGPIE_PUBLIC_URL, the gateway's address for others
  --allow-ips LIST    MAGPIE_ALLOW_IPS: only these addresses may call magpie (off: any)
  --tz ZONE           the container's time zone (default Asia/Shanghai)
  --domain NAME       optional: HTTPS on NAME through Caddy (ports 80 and 443)
  --no-domain         stop serving HTTPS through Caddy
  --no-tune           leave the host's kernel and file limits alone
  --install-docker    install Docker when it is missing, without asking
  --dry-run           print what it would write, change nothing
  -y, --yes           don't ask
A private image: set GHCR_USER and GHCR_TOKEN (read:packages) in the
environment; the token is passed to docker login on stdin, never written here.
EOF
}

ensure_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), Compose $(docker compose version --short 2>/dev/null || echo '?')"
		return 0
	fi
	if command -v docker >/dev/null 2>&1; then
		die "Docker is here but the Compose plugin isn't: install docker-compose-plugin (apt install docker-compose-plugin / dnf install docker-compose-plugin)"
	fi
	if [ "$INSTALL_DOCKER" = 1 ] || confirm "Docker isn't installed. Install it now with get.docker.com?"; then
		step "Installing Docker"
		local args=()
		# DOCKER_MIRROR=Aliyun (or AzureChinaCloud) for hosts in mainland China
		[ -n "${DOCKER_MIRROR:-}" ] && args+=(--mirror "$DOCKER_MIRROR")
		curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
		sh /tmp/get-docker.sh "${args[@]}"
		rm -f /tmp/get-docker.sh
		systemctl enable --now docker >/dev/null 2>&1 || true
		docker compose version >/dev/null 2>&1 || die "Docker installed, but docker compose doesn't run"
		ok "Docker installed"
	else
		die "Docker is needed: https://docs.docker.com/engine/install/ (or run again with --install-docker)"
	fi
}

registry_login() {
	[ -n "${GHCR_TOKEN:-}" ] || return 0
	local registry=${IMAGE%%/*}
	step "Signing in to $registry as ${GHCR_USER:?set GHCR_USER beside GHCR_TOKEN}"
	printf '%s' "$GHCR_TOKEN" | docker login "$registry" -u "$GHCR_USER" --password-stdin >/dev/null
	ok "signed in (docker keeps it in ~/.docker/config.json)"
}

# check_ports warns when a port this install publishes is held by something
# other than its own containers
check_ports() {
	command -v ss >/dev/null 2>&1 || return 0
	local p ports=() mine
	ports+=("$(env_get MAGPIE_GATEWAY_PORT)" "$(env_get MAGPIE_WEB_PORT)")
	[ "${ports[0]}" ] || ports[0]=3425
	[ "${ports[1]}" ] || ports[1]=3430
	[ -n "$(env_get MAGPIE_DOMAIN)" ] && ports+=(80 443)
	mine=$(docker ps -q --filter name='^magpie' 2>/dev/null || true)
	[ -n "$mine" ] && return 0 # re-run: the ports are its own
	for p in "${ports[@]}"; do
		if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then
			warn "port $p is in use on this host: $(ss -Hltnp "sport = :$p" 2>/dev/null | awk '{print $NF}' | head -n 1)"
		fi
	done
}

cmd_install() {
	local tag='' domain='' no_domain=0 bind='' web_bind='' public_ip='' gw_port='' web_port='' streams='' public_url='' allow_ips='' tz='' tune=1 image=''
	DIR=${MAGPIE_DIR:-$DEFAULT_DIR}
	INSTALL_DOCKER=0
	while [ $# -gt 0 ]; do
		case $1 in
		--dir) DIR=${2:?--dir needs a folder}; shift ;;
		--image) image=${2:?}; shift ;;
		--tag) tag=${2:?}; shift ;;
		--domain) domain=${2:?}; shift ;;
		--no-domain) no_domain=1 ;;
		--bind) bind=${2:?}; shift ;;
		--web-bind) web_bind=${2:?}; shift ;;
		--public) public_ip=${2:?--public needs this host IP}; shift ;;
		--gateway-port) gw_port=${2:?}; shift ;;
		--web-port) web_port=${2:?}; shift ;;
		--streams) streams=${2:?}; shift ;;
		--public-url) public_url=${2:?}; shift ;;
		--allow-ips) allow_ips=${2:?}; shift ;;
		--tz) tz=${2:?}; shift ;;
		--no-tune) tune=0 ;;
		--install-docker) INSTALL_DOCKER=1 ;;
		--dry-run) DRY_RUN=1 ;;
		-y | --yes) ASSUME_YES=1 ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown option $1 (magpie.sh install --help)" ;;
		esac
		shift
	done
	need_root install
	[ "$(uname -s)" = Linux ] || [ "$DRY_RUN" = 1 ] || die "this installs on Linux"
	if [ -n "$image" ] && [[ ${image##*/} == *[:@]* ]]; then
		die "--image is the name without a tag ($image); give the tag with --tag"
	fi
	for p in "$gw_port" "$web_port" "$streams"; do
		[ -z "$p" ] || [[ $p =~ ^[0-9]+$ ]] || die "not a number: $p"
	done
	if [ -n "$public_ip" ]; then
		[ -z "$domain" ] || die "--public is plain HTTP on an IP; --domain is HTTPS on a name: give one of them"
		[[ $public_ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $public_ip == *:* ]] || die "--public takes this host's IP address, not $public_ip"
		bind=0.0.0.0
		no_domain=1
		local shown=$public_ip
		[[ $public_ip == *:* ]] && shown="[$public_ip]"
		public_url=${public_url:-http://$shown:${gw_port:-$(env_get_at "$DIR/.env" MAGPIE_GATEWAY_PORT 3425)}}
	fi
	ENV_FILE=$DIR/.env

	# Behind Caddy magpie sees Caddy's address, so an allow list there, set
	# now or kept from a --public install, would shut every client out.
	# Checked before .env is touched: what this run asks for, else what it keeps.
	local will_domain=$domain will_allow=$allow_ips
	[ -n "$will_domain" ] || [ "$no_domain" = 1 ] || will_domain=$(env_get MAGPIE_DOMAIN)
	[ -n "$will_allow" ] || will_allow=$(env_get MAGPIE_ALLOW_IPS)
	[ "$will_allow" = off ] && will_allow=''
	if [ -n "$will_domain" ] && [ -n "$will_allow" ]; then
		if [ -n "$allow_ips" ]; then
			die "--allow-ips with --domain would shut everyone out: behind Caddy, magpie sees Caddy's address, not the client's. Limit addresses in caddy/Caddyfile instead (docs/fork/deploy-docker.md)"
		fi
		die "this install has an allow list ($will_allow), which behind Caddy would shut everyone out: magpie sees Caddy's address, not the client's. Add --allow-ips off (and limit addresses in caddy/Caddyfile if you need to, docs/fork/deploy-docker.md)"
	fi

	step "magpie gateway → $DIR"
	[ "$DRY_RUN" = 1 ] || ensure_docker

	if [ "$DRY_RUN" = 0 ]; then
		mkdir -p "$DIR/config" "$DIR/backups" "$DIR/caddy/data" "$DIR/caddy/config"
		chmod 700 "$DIR" "$DIR/backups"
		chown -R "$CONTAINER_UID:$CONTAINER_UID" "$DIR/config"
	else
		mkdir -p "$DIR/caddy"
	fi

	# .env: what was set before stays unless an option says otherwise; the
	# web key is made once and kept
	[ -f "$ENV_FILE" ] && ok "keeping the settings in $ENV_FILE"
	[ -n "$(env_get MAGPIE_WEB_KEY)" ] || env_set MAGPIE_WEB_KEY "$(random_key)"
	[ -n "$image" ] && env_set MAGPIE_IMAGE "$image"
	[ -n "$(env_get MAGPIE_IMAGE)" ] || env_set MAGPIE_IMAGE "$DEFAULT_IMAGE"
	[ -n "$tag" ] && env_set MAGPIE_TAG "$tag"
	[ -n "$(env_get MAGPIE_TAG)" ] || env_set MAGPIE_TAG latest
	# the image that runs: kept across a re-run, unless --image or --tag names another
	if [ -n "$image" ] || [ -n "$tag" ] || [ -z "$(env_get MAGPIE_IMAGE_REF)" ]; then
		env_set MAGPIE_IMAGE_REF "$(env_get MAGPIE_IMAGE):$(env_get MAGPIE_TAG)"
	fi
	[ -n "$streams" ] && env_set MAGPIE_PLUGIN_STREAMS "$streams"
	[ -n "$(env_get MAGPIE_PLUGIN_STREAMS)" ] || env_set MAGPIE_PLUGIN_STREAMS 2048
	[ -n "$gw_port" ] && env_set MAGPIE_GATEWAY_PORT "$gw_port"
	[ -n "$web_port" ] && env_set MAGPIE_WEB_PORT "$web_port"
	[ -n "$tz" ] && env_set TZ "$tz"
	[ -n "$(env_get TZ)" ] || env_set TZ Asia/Shanghai
	if [ "$allow_ips" = off ]; then
		env_set MAGPIE_ALLOW_IPS ""
	elif [ -n "$allow_ips" ]; then
		env_set MAGPIE_ALLOW_IPS "$allow_ips"
	fi
	if [ -n "$domain" ]; then
		env_set MAGPIE_DOMAIN "$domain"
		env_set MAGPIE_PUBLIC_URL "${public_url:-https://$domain}"
		env_set MAGPIE_WEB_URL "https://$domain"
	elif [ "$no_domain" = 1 ]; then
		env_set MAGPIE_DOMAIN ""
		env_set MAGPIE_WEB_URL ""
		env_set MAGPIE_PUBLIC_URL "$public_url"
	elif [ -n "$public_url" ]; then
		env_set MAGPIE_PUBLIC_URL "$public_url"
	fi
	# Caddy runs while a domain is set; behind it magpie's own ports stay on this host
	if [ -n "$(env_get MAGPIE_DOMAIN)" ]; then
		env_set COMPOSE_PROFILES https
		bind=127.0.0.1
		web_bind=127.0.0.1
	else
		env_set COMPOSE_PROFILES ""
	fi
	[ -n "$bind" ] && env_set MAGPIE_BIND "$bind"
	[ -n "$(env_get MAGPIE_BIND)" ] || env_set MAGPIE_BIND 127.0.0.1
	[ -n "$web_bind" ] && env_set MAGPIE_WEB_BIND "$web_bind"
	[ -n "$(env_get MAGPIE_WEB_BIND)" ] || env_set MAGPIE_WEB_BIND 127.0.0.1
	if [ "$(env_get MAGPIE_WEB_BIND)" != 127.0.0.1 ] && [ -z "$(env_get MAGPIE_DOMAIN)" ]; then
		warn "the web UI is published on $(env_get MAGPIE_WEB_BIND) over plain HTTP: its link carries magpie's admin key in the clear. Without --web-bind it stays on this host (ssh -L)"
	fi

	# compose.yaml and the Caddyfile are this script's; an older one is kept as .bak
	local f
	for f in compose.yaml caddy/Caddyfile; do
		[ -f "$DIR/$f" ] && cp -f "$DIR/$f" "$DIR/$f.bak"
	done
	write_compose "$DIR/compose.yaml"
	write_caddyfile "$DIR/caddy/Caddyfile"

	if [ "$DRY_RUN" = 1 ]; then
		step "dry run: wrote $DIR/compose.yaml, $DIR/caddy/Caddyfile and $DIR/.env; the host's settings would be:"
		tune_host
		return 0
	fi

	# the installed copy of this script, and the magpiectl command; run
	# through a pipe (curl … | bash) there is no file to copy, so it is fetched
	local src=${BASH_SOURCE[0]:-}
	if [ -n "$src" ] && [ -f "$src" ]; then
		[ "$(readlink -f "$src")" = "$DIR/magpie.sh" ] || install -m 0755 "$src" "$DIR/magpie.sh"
	else
		curl -fsSL "${MAGPIE_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}" -o "$DIR/magpie.sh" ||
			die "couldn't fetch the script to keep in $DIR; download magpie.sh and run it as a file"
		chmod 0755 "$DIR/magpie.sh"
	fi
	ln -sfn "$DIR/magpie.sh" /usr/local/bin/magpiectl
	ok "installed $DIR/magpie.sh, run as: magpiectl <command>"

	[ "$tune" = 1 ] && tune_host
	check_ports

	IMAGE=$(env_get MAGPIE_IMAGE)
	registry_login
	step "Pulling $(env_get MAGPIE_IMAGE_REF)"
	compose pull || die "couldn't pull the image. A private GHCR image needs GHCR_USER and GHCR_TOKEN (read:packages) set when you run this, or the package made public"
	# pin the tag to what it is now, so a moving tag (latest) changes nothing until `magpiectl upgrade`
	local ref digest
	ref=$(env_get MAGPIE_IMAGE_REF)
	digest=$(image_digest "$ref")
	[ -n "$digest" ] && env_set MAGPIE_IMAGE_REF "$digest"

	step "Starting"
	# a profile turned off leaves its container running: Caddy goes by hand
	if [ -z "$(env_get MAGPIE_DOMAIN)" ] && docker container inspect magpie-caddy >/dev/null 2>&1; then
		docker rm -f magpie-caddy >/dev/null
		ok "stopped Caddy (no domain)"
	fi
	compose up -d --remove-orphans
	if ! wait_healthy; then
		compose logs --tail 80 magpie >&2 || true
		die "magpie didn't become healthy within ${HEALTH_WAIT}s (its log is above)"
	fi
	ok "magpie is up: $(running_version)"
	if [ -n "$(env_get MAGPIE_DOMAIN)" ]; then
		say "${c_dim}  Caddy gets the certificate for $(env_get MAGPIE_DOMAIN) on first use; \`magpie logs caddy\` says how it went${c_off}"
	fi
	say
	cmd_url
	say
	say "Next: open the web UI, install your provider plugin and sign in its accounts,"
	say "then give each client a key: ${c_bold}sudo magpiectl key add <name>${c_off}"
}

cmd_url() {
	local key bind web_bind port gp domain public
	key=$(env_get MAGPIE_WEB_KEY)
	bind=$(env_get MAGPIE_BIND)
	web_bind=$(env_get MAGPIE_WEB_BIND)
	web_bind=${web_bind:-127.0.0.1}
	port=$(env_get MAGPIE_WEB_PORT)
	port=${port:-3430}
	gp=$(env_get MAGPIE_GATEWAY_PORT)
	gp=${gp:-3425}
	domain=$(env_get MAGPIE_DOMAIN)
	public=$(env_get MAGPIE_PUBLIC_URL)
	say "${c_bold}Web UI${c_off}"
	if [ -n "$domain" ]; then
		say "  https://$domain/?k=$key"
	fi
	if [ "$web_bind" = 127.0.0.1 ]; then
		say "  http://127.0.0.1:$port/?k=$key"
		say "  ${c_dim}on this host only. From your computer: ssh -L $port:127.0.0.1:$port <user>@<this host>, then open the link above${c_off}"
	else
		say "  http://<this host>:$port/?k=$key"
	fi
	say "${c_bold}Gateway${c_off} (every client sends a gateway key: sudo magpiectl key add <name>)"
	if [ -n "$domain" ]; then
		say "  OpenAI: https://$domain/v1    Anthropic / Gemini: https://$domain"
	elif [ -n "$public" ]; then
		say "  OpenAI: ${public%/}/v1    Anthropic / Gemini: ${public%/}"
	elif [ "$bind" = 127.0.0.1 ]; then
		say "  OpenAI: http://127.0.0.1:$gp/v1    ${c_dim}(this host only; install --public <IP> serves other machines)${c_off}"
	else
		say "  OpenAI: http://<this host>:$gp/v1    Anthropic / Gemini: http://<this host>:$gp"
	fi
	say "${c_dim}The web link carries magpie's admin key; anyone with it can change magpie. Keep it to yourself.${c_off}"
}

# backup_config [label] writes backups/config-<time>[-label].tar.gz, without
# the cache (Bun, the model catalog), which magpie fetches again
backup_config() {
	local label=${1:-} name rc=0
	name="config-$(date +%Y%m%d-%H%M%S)${label:+-$label}.tar.gz"
	mkdir -p "$DIR/backups"
	# taken while magpie runs: a file it is writing may change under tar,
	# which GNU tar reports with exit status 1; magpie replaces its files
	# whole (write, then rename), so the copy taken is a whole one
	tar -C "$DIR" --warning=no-file-changed --exclude=./config/cache \
		-czf "$DIR/backups/$name" ./config ./.env ./compose.yaml || rc=$?
	[ "$rc" -le 1 ] || die "the backup failed (tar exit $rc)"
	chmod 600 "$DIR/backups/$name"
	# the newest $KEEP_BACKUPS stay
	ls -1t "$DIR"/backups/config-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
	printf '%s' "$DIR/backups/$name"
}

load_install() {
	DIR=$(here_dir)
	ENV_FILE=$DIR/.env
	[ -f "$DIR/compose.yaml" ] && [ -f "$ENV_FILE" ] || die "no install in $DIR (sudo bash magpie.sh install, or MAGPIE_DIR=<folder>)"
	IMAGE=$(env_get MAGPIE_IMAGE)
}

cmd_upgrade() {
	local tag='' do_backup=1
	while [ $# -gt 0 ]; do
		case $1 in
		--tag) tag=${2:?--tag needs a tag}; shift ;;
		--no-backup) do_backup=0 ;;
		-y | --yes) ASSUME_YES=1 ;;
		*) die "unknown option $1 (magpiectl upgrade [--tag TAG] [--no-backup])" ;;
		esac
		shift
	done
	need_root upgrade
	load_install
	tag=${tag:-$(env_get MAGPIE_TAG)}
	tag=${tag:-latest}
	local old new
	old=$(env_get MAGPIE_IMAGE_REF)

	registry_login
	step "Pulling $IMAGE:$tag (magpie keeps running meanwhile)"
	docker pull "$IMAGE:$tag" >/dev/null
	new=$(image_digest "$IMAGE:$tag")
	new=${new:-$IMAGE:$tag}
	if [ "$new" = "$old" ]; then
		ok "already on $IMAGE:$tag ($(running_version))"
		return 0
	fi
	say "  from: $old ($(running_version))"
	say "  to:   $new"
	warn "requests in flight are cut when magpie restarts (a few seconds); pick a quiet moment"
	confirm "Upgrade now?" || [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ] || die "left as it was"

	if [ "$do_backup" = 1 ]; then
		step "Backing up the data"
		ok "$(backup_config before-upgrade)"
	fi
	env_set MAGPIE_PREV_IMAGE_REF "$old"
	env_set MAGPIE_IMAGE_REF "$new"
	env_set MAGPIE_TAG "$tag"

	step "Restarting on the new image"
	compose up -d --remove-orphans
	if wait_healthy; then
		ok "upgraded: $(running_version)"
		docker image prune -f >/dev/null 2>&1 || true
		return 0
	fi
	compose logs --tail 80 magpie >&2 || true
	warn "the new image didn't become healthy; going back to $old"
	env_set MAGPIE_IMAGE_REF "$old"
	env_set MAGPIE_PREV_IMAGE_REF "$new"
	compose up -d --remove-orphans
	if wait_healthy; then
		die "rolled back to the old image, which is running; the new one's log is above"
	fi
	die "the old image doesn't start either: magpiectl rollback --restore <backup> puts the data back as it was (backups in $DIR/backups)"
}

cmd_rollback() {
	local restore=''
	while [ $# -gt 0 ]; do
		case $1 in
		--restore) restore=${2:?--restore needs a backup file}; shift ;;
		-y | --yes) ASSUME_YES=1 ;;
		*) die "unknown option $1 (magpiectl rollback [--restore BACKUP])" ;;
		esac
		shift
	done
	need_root rollback
	load_install
	local cur prev
	cur=$(env_get MAGPIE_IMAGE_REF)
	prev=$(env_get MAGPIE_PREV_IMAGE_REF)
	[ -n "$prev" ] || [ -n "$restore" ] || die "no earlier image recorded (only an upgrade records one)"
	if [ -n "$restore" ]; then
		[ -f "$restore" ] || restore=$DIR/backups/$restore
		[ -f "$restore" ] || die "no backup $restore (ls $DIR/backups)"
		confirm "Replace the data in $DIR/config with $restore?" || die "left as it was"
		step "Restoring $restore"
		compose stop magpie
		local aside
		aside="$DIR/config.before-restore-$(date +%Y%m%d-%H%M%S)"
		mv "$DIR/config" "$aside"
		tar -C "$DIR" -xzf "$restore" ./config
		# the cache wasn't backed up: the current one is kept
		[ -d "$aside/cache" ] && mv "$aside/cache" "$DIR/config/cache"
		chown -R "$CONTAINER_UID:$CONTAINER_UID" "$DIR/config"
		ok "restored; the data it replaced is in $aside"
	fi
	if [ -n "$prev" ]; then
		env_set MAGPIE_IMAGE_REF "$prev"
		env_set MAGPIE_PREV_IMAGE_REF "$cur"
		step "Back to $prev"
	fi
	compose up -d --remove-orphans
	wait_healthy || {
		compose logs --tail 80 magpie >&2 || true
		die "magpie didn't become healthy"
	}
	ok "running: $(running_version)"
}

cmd_status() {
	load_install
	compose ps
	say
	say "version:  $(running_version)"
	say "image:    $(env_get MAGPIE_IMAGE_REF)"
	say "previous: $(env_get MAGPIE_PREV_IMAGE_REF)"
	say "streams:  $(docker exec magpie printenv MAGPIE_PLUGIN_STREAMS 2>/dev/null || echo '?') plugin fetches at once"
	say "open files in the container: $(docker exec magpie sh -c 'ulimit -n' 2>/dev/null || echo '?')"
	say "data:     $DIR/config ($(du -sh "$DIR/config" 2>/dev/null | cut -f1))"
	say "backups:  $(ls -1 "$DIR"/backups/config-*.tar.gz 2>/dev/null | wc -l) in $DIR/backups"
}

cmd_self_update() {
	need_root self-update
	load_install
	local url=${MAGPIE_SCRIPT_URL:-$DEFAULT_SCRIPT_URL} tmp
	tmp=$(mktemp)
	step "Fetching $url"
	curl -fsSL "$url" -o "$tmp"
	bash -n "$tmp" || die "the fetched script doesn't parse; kept the current one"
	if cmp -s "$tmp" "$DIR/magpie.sh"; then
		rm -f "$tmp"
		ok "the script is current ($SCRIPT_VERSION)"
		return 0
	fi
	install -m 0755 "$tmp" "$DIR/magpie.sh"
	rm -f "$tmp"
	ok "updated $DIR/magpie.sh ($(grep -m1 '^SCRIPT_VERSION=' "$DIR/magpie.sh" | cut -d= -f2)); run \`sudo magpie install\` to apply a new compose.yaml"
}

main() {
	local cmd=${1:-help}
	[ $# -gt 0 ] && shift
	case $cmd in
	install) cmd_install "$@" ;;
	upgrade | update) cmd_upgrade "$@" ;;
	rollback) cmd_rollback "$@" ;;
	status) cmd_status ;;
	logs)
		load_install
		compose logs -f --tail 200 "${@:-magpie}"
		;;
	url)
		load_install
		cmd_url
		;;
	version)
		load_install
		say "$(running_version)  (script $SCRIPT_VERSION)"
		;;
	backup)
		need_root backup
		load_install
		ok "$(backup_config manual)"
		;;
	key)
		load_install
		[ "${1:-}" = add ] && [ -n "${2:-}" ] || die "magpiectl key add <name>"
		docker exec magpie magpie gateway-key add "$2"
		;;
	tune)
		need_root tune
		DIR=$(here_dir)
		mkdir -p "$DIR"
		tune_host
		;;
	restart)
		load_install
		compose restart magpie
		wait_healthy || die "magpie didn't become healthy (magpiectl logs)"
		ok "running: $(running_version)"
		;;
	self-update) cmd_self_update ;;
	help | -h | --help) usage ;;
	*) die "unknown command $cmd (magpiectl help)" ;;
	esac
}

main "$@"
