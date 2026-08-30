#!/bin/sh
# Prints the Kubernetes node labels for this gateway, one key=value per line.
#
# Installed as /usr/bin/izuma-node-labels and used by two callers, so that the
# label set has exactly one definition:
#
#   - the kubelet launcher, which turns it into --node-labels at registration
#   - install-thick-edge-services.sh, which reconciles it onto a Node object
#     that already exists
#
# Run it by hand to see what this gateway would be labelled with.

IZUMA_IDENTITY_JSON=${IZUMA_IDENTITY_JSON:-/var/lib/pelion/edge_gw_config/identity.json}
IZUMA_OS_RELEASE=${IZUMA_OS_RELEASE:-/etc/os-release}
IZUMA_EDGE_CORE_STATUS_URL=${IZUMA_EDGE_CORE_STATUS_URL:-http://localhost:9101/status}
NODE_LABELS_FILE=${NODE_LABELS_FILE:-/etc/pelion/node-labels}

# A label value must be 63 characters or fewer, start and end with an
# alphanumeric, and otherwise hold only alphanumerics, '-', '_' and '.'.
# "AlmaLinux 9.8 (Olive Jaguar)" is not a legal value; "almalinux" is.
izuma_label_value() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
		| sed -e 's/[^a-z0-9._-]/-/g' -e 's/^[^a-z0-9]*//' -e 's/[^a-z0-9]*$//' \
		| cut -c1-63
}

# The endpoint name is the device name shown in Device Management; the node name
# is the opaque internal ID, so this is what makes a node recognisable in the
# Kubernetes views. It identifies rather than groups - and a label is the only
# mechanism available, since a kubelet self-registers labels, not annotations.
izuma_endpoint_name() {
	name=$(curl -fsS --max-time 3 "$IZUMA_EDGE_CORE_STATUS_URL" 2>/dev/null \
		| jq -r '."endpoint-name" // empty' 2>/dev/null)

	# Otherwise read it back out of identity.json: pe-utils records the endpoint
	# name as the serial number (generate-identity.sh passes -e "$endpointname"
	# to create-dev-identity.sh, which writes it out as serialNumber).
	if [ -z "$name" ]; then
		name=$(jq -r '.serialNumber // empty' "$IZUMA_IDENTITY_JSON" 2>/dev/null)
	fi

	printf '%s' "$name"
}

# Derived labels are printed before the file's, so a key repeated in the file
# overrides them: kubelet keeps the last value it parses for a given key, and
# the reconcile step builds its patch the same way.
distro=$(izuma_label_value "$(. "$IZUMA_OS_RELEASE" 2>/dev/null; printf '%s' "${ID:-}")")
[ -n "$distro" ] && printf 'distro=%s\n' "$distro"

# Kept separate from `distro` rather than folded into it as "ubuntu-22.04",
# because a nodeSelector matches exactly: with one combined label, "every Ubuntu
# gateway" stops being expressible and a mixed 22.04/24.04 fleet needs one
# workload per version. Two labels keep both granularities targetable.
distro_version=$(izuma_label_value "$(. "$IZUMA_OS_RELEASE" 2>/dev/null; printf '%s' "${VERSION_ID:-}")")
[ -n "$distro_version" ] && printf 'distro-version=%s\n' "$distro_version"

mode=$(izuma_label_value "$(jq -r '.category // empty' "$IZUMA_IDENTITY_JSON" 2>/dev/null)")
[ -n "$mode" ] && printf 'mode=%s\n' "$mode"

endpoint=$(izuma_label_value "$(izuma_endpoint_name)")
[ -n "$endpoint" ] && printf 'endpoint-name=%s\n' "$endpoint"

if [ -r "$NODE_LABELS_FILE" ]; then
	grep -v '^[[:space:]]*#' "$NODE_LABELS_FILE" | grep '='
fi

exit 0
