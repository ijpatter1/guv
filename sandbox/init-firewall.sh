#!/bin/bash
# init-firewall.sh
# Sets up iptables firewall with domain allowlisting.
# Runs as root (entrypoint runs as root for iptables, then drops to claude user).
# Resolves domains to IPs at container start.
#
# IMPORTANT: DNS resolution happens once at startup. If a service's
# IP changes during a long session, restart the container to refresh.
#
# CDN-HOSTED SERVICES (npm, GitHub):
# These services use CDNs (Cloudflare, Fastly) that may return different
# IPs on subsequent requests. We resolve each domain multiple times to
# capture more edge IPs, but intermittent failures are still possible
# during very long sessions. Restart the container if npm install fails.

set -e

echo "[firewall] Initializing iptables firewall..."

# ─────────────────────────────────────────────
# ALLOWLISTED DOMAINS
# Only these services are reachable from inside the container.
# Edit this list based on your project's needs.
# ─────────────────────────────────────────────

ALLOWED_DOMAINS=(
    # Anthropic API (required for Claude Code)
    "api.anthropic.com"
    "claude.ai"
    "statsig.anthropic.com"

    # npm registry (required for package installation)
    "registry.npmjs.org"
    "www.npmjs.com"

    # GitHub (required for git operations — push blocked by bash-guard hook)
    "github.com"
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"

    # Vercel (deployment)
    "vercel.com"
    "api.vercel.com"
)

# Domains needed only when gcloud is installed (Phase 4+).
# Uncomment these when you uncomment gcloud in the Dockerfile.
GCLOUD_DOMAINS=(
    "oauth2.googleapis.com"
    "accounts.google.com"
    "www.googleapis.com"
    "bigquery.googleapis.com"
    "pubsub.googleapis.com"
    "run.googleapis.com"
    "storage.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "dataform.googleapis.com"
    "tagmanager.googleapis.com"
)

# Domains for CMP and sGTM — uncomment when configuring these services
INSTRUMENTATION_DOMAINS=(
    # "stape.io"
    # "consent.cookiebot.com"
    # "cdn.cookiebot.com"
)

# ─────────────────────────────────────────────
# FIREWALL RULES
# ─────────────────────────────────────────────

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true

# Default policy: drop all outbound
iptables -P OUTPUT DROP

# Allow loopback (localhost — needed for dev server, tests, etc.)
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections (responses to allowed requests)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (required for domain resolution during setup and runtime)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Collect all active domains
ALL_DOMAINS=("${ALLOWED_DOMAINS[@]}")
for d in "${GCLOUD_DOMAINS[@]}"; do
    [[ "$d" != \#* ]] && [ -n "$d" ] && ALL_DOMAINS+=("$d")
done
for d in "${INSTRUMENTATION_DOMAINS[@]}"; do
    [[ "$d" != \#* ]] && [ -n "$d" ] && ALL_DOMAINS+=("$d")
done

# Resolve each domain and add iptables rules.
# Resolve multiple times to capture CDN edge rotation.
RESOLVED_COUNT=0
FAILED_DOMAINS=()

for domain in "${ALL_DOMAINS[@]}"; do
    # Resolve 3 times to capture multiple CDN edge IPs
    ALL_IPS=""
    for i in 1 2 3; do
        BATCH=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
        if [ -n "$BATCH" ]; then
            ALL_IPS="${ALL_IPS}${BATCH}"$'\n'
        fi
        # Brief pause between lookups to encourage different CDN responses
        [ $i -lt 3 ] && sleep 0.2
    done

    # Deduplicate IPs
    UNIQUE_IPS=$(echo "$ALL_IPS" | sort -u | grep -E '^[0-9]+\.' || true)

    if [ -n "$UNIQUE_IPS" ]; then
        while IFS= read -r ip; do
            # Check if rule already exists to avoid duplicates
            if ! iptables -C OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
                iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
                iptables -A OUTPUT -d "$ip" -p tcp --dport 80 -j ACCEPT
            fi
            ((RESOLVED_COUNT++)) || true
        done <<< "$UNIQUE_IPS"
        IP_COUNT=$(echo "$UNIQUE_IPS" | wc -l | tr -d ' ')
        echo "[firewall] ✓ $domain ($IP_COUNT IPs)"
    else
        FAILED_DOMAINS+=("$domain")
        echo "[firewall] ✗ $domain (could not resolve — will be unreachable)"
    fi
done

# Final drop rule (explicit, in case default policy doesn't apply to some chains)
iptables -A OUTPUT -j DROP

echo "[firewall] Initialized: $RESOLVED_COUNT IPs allowed from ${#ALL_DOMAINS[@]} domains"

if [ ${#FAILED_DOMAINS[@]} -gt 0 ]; then
    echo "[firewall] WARNING: ${#FAILED_DOMAINS[@]} domain(s) could not be resolved:"
    for d in "${FAILED_DOMAINS[@]}"; do
        echo "  - $d"
    done
    echo "[firewall] These domains will be unreachable. Restart container to retry."
fi

echo "[firewall] All other outbound traffic is blocked."
