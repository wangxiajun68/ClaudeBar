#!/bin/bash
# Ensure a *trusted* local code-signing identity "ClaudeBar Dev".
#
# An untrusted self-signed cert (`CSSMERR_TP_NOT_TRUSTED`) signs the app on
# disk, but the kernel/TCC treat it as unsigned. Screen Recording then binds to
# CDHash, which changes every rebuild — so macOS asks again every time.
#
# Prints a SHA-1 identity hash for `codesign --sign`.
set -euo pipefail

IDENTITY="${CLAUDEBAR_DEV_IDENTITY:-ClaudeBar Dev}"
PIN_FILE="${HOME}/Library/Application Support/ClaudeBar/dev-codesign-identity"

KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' "')"
if [ -z "$KEYCHAIN" ] || [ ! -f "$KEYCHAIN" ]; then
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fi

list_hashes() {
    security find-identity -p codesigning 2>/dev/null \
        | grep -F "\"$IDENTITY\"" \
        | awk '{print $2}'
}

is_trusted() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "$1"
}

pick_hash() {
    if [ -f "$PIN_FILE" ]; then
        local pinned
        pinned="$(tr -d '[:space:]' < "$PIN_FILE")"
        if [ -n "$pinned" ] && list_hashes | grep -qx "$pinned"; then
            echo "$pinned"
            return 0
        fi
    fi
    list_hashes | head -1 || true
}

save_pin() {
    mkdir -p "$(dirname "$PIN_FILE")"
    echo "$1" > "$PIN_FILE"
}

# Write PEM for the identity whose SHA-1 fingerprint matches $1.
export_pem() {
    local want="$1" dest="$2" tmp n=0 pem fp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudebar-pem.XXXXXX")"
    security find-certificate -a -c "$IDENTITY" -p > "$tmp/all.pem"
    awk -v d="$tmp" '
        /-----BEGIN CERTIFICATE-----/ { n++; f=sprintf("%s/%d.pem", d, n); p=1 }
        p { print > f }
        /-----END CERTIFICATE-----/ { p=0 }
    ' "$tmp/all.pem"
    for pem in "$tmp"/*.pem; do
        [ -f "$pem" ] || continue
        fp="$(openssl x509 -in "$pem" -noout -fingerprint -sha1 2>/dev/null \
            | sed 's/^.*=//;s/://g')"
        if [ "$fp" = "$want" ]; then
            cp "$pem" "$dest"
            rm -rf "$tmp"
            return 0
        fi
    done
    rm -rf "$tmp"
    return 1
}

# Mark the cert as a code-signing trust root in the login keychain.
# `-r unspecified` is not enough — identity stays CSSMERR_TP_NOT_TRUSTED.
trust_hash() {
    local hash="$1" pem
    if is_trusted "$hash"; then
        return 0
    fi
    pem="$(mktemp "${TMPDIR:-/tmp}/claudebar-trust.XXXXXX.pem")"
    if ! export_pem "$hash" "$pem"; then
        rm -f "$pem"
        echo "Could not export certificate $hash from the keychain." >&2
        return 1
    fi
    echo "Trusting '$IDENTITY' for code signing (login keychain)…" >&2
    if ! security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem"; then
        rm -f "$pem"
        echo "Could not trust '$IDENTITY'. In Keychain Access: find the cert → Get Info → Trust → Code Signing = Always Trust." >&2
        return 1
    fi
    rm -f "$pem"
    if ! is_trusted "$hash"; then
        echo "'$IDENTITY' is still untrusted. Screen Recording will reset on every rebuild." >&2
        return 1
    fi
}

HASH="$(pick_hash)"
if [ -n "${HASH:-}" ]; then
    save_pin "$HASH"
    trust_hash "$HASH"
    echo "Using existing identity $IDENTITY ($HASH)" >&2
    echo "$HASH"
    exit 0
fi

echo "Creating local code-signing certificate: $IDENTITY" >&2

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claudebar-codesign.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Self-signed CA (so trustRoot is valid) that is also a code-signing leaf.
cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[req_distinguished_name]
CN = ClaudeBar Dev
O = ClaudeBar Local
C = CN

[v3_codesign]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -days 3650 \
    -config "$TMP/openssl.cnf" \
    -extensions v3_codesign

PASS="$(openssl rand -base64 18)"
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" \
    -passout "pass:$PASS" \
    -name "$IDENTITY"

security import "$TMP/cert.p12" \
    -k "$KEYCHAIN" \
    -P "$PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

HASH="$(list_hashes | head -1 || true)"
if [ -z "${HASH:-}" ]; then
    echo "Failed to install '$IDENTITY' into the keychain." >&2
    exit 1
fi

save_pin "$HASH"
trust_hash "$HASH"
echo "Created '$IDENTITY' ($HASH). Grant Screen Recording once; later rebuilds keep it." >&2
echo "If Keychain asks for access, choose Always Allow." >&2
echo "$HASH"
