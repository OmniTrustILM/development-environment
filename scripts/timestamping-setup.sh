#!/usr/bin/env bash
# timestamping-setup.sh
#
# IMPORTANT: The default values defined in the "--- Defaults ---" section below are relied upon
# by the issue-timestamp script in the ILM-Core repository. Any change to a default here
# must also be reflected in that script.
#
# Automates the ILM timestamping environment setup:
#   1. Creates connectors (credential-provider v1 for credentials, credential-provider v2 for secrets,
#      EJBCA, the --crypto-provider connector, and timestamp-formatting-connector)
#   2. Creates a SoftKeyStore credential from a PKCS12 bundle
#   3. Creates an EJBCA authority instance
#   4. Discovers the vault instance (by name)
#   5. Creates a vault profile under it, for TSP profiles' Basic credentials and PKCS#11 token's user PIN
#   6. Creates a token on the --crypto-provider connector
#   7. Creates a token profile
#   8. Creates a Time Quality configuration (used by the qualified signing profile)
#   9. Creates the dedicated mapped user, authenticating with Basic credentials
#  10. Creates the timestamping role and attaches it to that user (its permissions are granted in step 21)
#  11. With --issuer-ca: uploads the issuing CA where Core lacks it, then marks it as trusted
#   For each of two sets (non-qualified / qualified):
#      12. Creates a key pair
#      13. Creates an RA profile (resolving EJBCA profile IDs dynamically)
#      14. Issues a TSA certificate with the requested DN suffix
#      15. Polls for certificate issuance completion
#      16. Trusts the certificate chain (marks root CA as trusted, triggers validation)
#      17. Creates and enables a TSP profile (clientCertificate + basicPassword, linked to the vault profile)
#      18. Creates and enables a Signing Profile
#          (qualified profile links to the Time Quality configuration)
#      19. Links the Signing Profile to the TSP Profile bidirectionally
#      20. Creates a Basic (username/password) credential on the TSP profile, mapped to the user
#  21. Grants object-scoped timestamping permissions to the role (applied after both sets exist)

set -euo pipefail
# Bash clears -e inside $(...). A function run in one therefore passes each nested failure out with || exit 1.

# --- Defaults -----------------------------------------------------------------
# Targets Core running directly from the IDE on the default port.
# When running Core via docker-compose, override with --ilm-host http://localhost:8280.
ILM_HOST="http://localhost:8080"

# Authentication mode:
#   header - send the admin certificate in the ssl-client-cert header (local instances).
#   mtls   - present an admin PKCS12 as a real TLS client certificate (remote HTTPS instances).
AUTH_MODE="header"
CLIENT_CERT_PEM=""          # header mode: admin client certificate PEM
CLIENT_P12_BUNDLE=""        # mtls mode:   admin client PKCS12 bundle
CLIENT_P12_PASSPHRASE=""
INSECURE_TLS="false"        # mtls mode:   skip server TLS verification (curl -k)

CONNECTOR_HOST="localhost"
PORT_CRED_PROVIDER="8200"
PORT_EJBCA="8210"
PORT_CRYPTO_PROVIDER="8230"
PORT_PKCS11_PROVIDER="8290"
PORT_TIMESTAMP_FORMATTING="8270"

# Cryptography provider the TSA keys live on:
#   software-v1 - software-cryptography-provider registered as a v1 connector
#   software-v2 - software-cryptography-provider registered as a v2 connector
#   pkcs11      - pkcs11-cryptography-provider (v2 only)
CRYPTO_PROVIDER="software-v2"
PKCS11_PROFILE="softhsm"      # config profile, which names the proxy sidecar
PKCS11_TOKEN="softhsm"        # token label, as the token's PKCS#11 URI states it
PIN_ENV="SOFTHSM_USER_PIN"    # environment variable holding the pkcs11 token user PIN

# Attributes exposed by the corresponding --crypto-provider connector.
KEY_ALGORITHM_ATTR=""
KEY_SPEC_GROUP=""
KEY_ALIAS_ATTR=""
RSA_KEY_SIZE_ATTR=""
MLDSA_LEVEL_ATTR=""
MLDSA_PREHASH_ATTR=""         # empty where the connector offers pure ML-DSA only

PKCS12_BUNDLE=""
PKCS12_PASSWORD="00000000"
TOKEN_PASSWORD=""          # defaults to PKCS12_PASSWORD when empty
CERTIFICATE_CN_PREFIX=""   # --certificate-dn; -non-qualified / -qualified are appended

EJBCA_URL="https://ejbca.3key.company/ejbca/ejbcaws/ejbcaws?wsdl"
EJBCA_EE_PROFILE="DemoTSAEndEntityProfile"
EJBCA_CERT_PROFILE="DemoTSAEECertificateProfile"
EJBCA_CERT_PROFILE_QUALIFIED="DemoTSAQCEECertificateProfile"
EJBCA_CA_NAME="DemoRootCA_2307RSA"
EJBCA_USERNAME_GEN_METHOD="CN"    # certificate CN is hardcoded in EJBCA

CREDENTIAL_NAME="ejbca.3key.company"
AUTHORITY_NAME="ejbca.3key.company"
TOKEN_NAME="tsa"
TOKEN_PROFILE_NAME="tsa"
KEY_NAME_BASE=""                  # -non-qualified / -qualified appended
RA_PROFILE_NAME_BASE=""           # -non-qualified / -qualified appended
KEY_ALGORITHM="RSA"               # key algorithm code from the connector
KEY_SPEC=""                       # NAME=VALUE,... over the connector's key-spec fields
DEFAULT_RSA_KEY_SIZE=2048
DEFAULT_MLDSA_LEVEL=3             # ML-DSA-65
DEFAULT_MLDSA_PREHASH=false       # pure ML-DSA
TSP_PROFILE_NAME_BASE=""          # -non-qualified / -qualified appended
SIGNING_PROFILE_NAME_BASE=""      # -non-qualified / -qualified appended
SET_NAME=""                       # set of objects and certificates
DEFAULT_KEY_NAME_BASE="tsa-rsa"
DEFAULT_TSA_NAME_BASE="tsa"
DEFAULT_TSP_NAME_BASE="tsp"

SIGNATURE_SCHEME=""
SIGNATURE_DIGEST=""
DEFAULT_SIGNATURE_SCHEME="PKCS1-v1_5"
DEFAULT_SIGNATURE_DIGEST="SHA-384"
ISSUER_CA_FILE=""
TIMESTAMP_FORMATTING_CONNECTOR_NAME="timestamp-formatting-connector"

# Vault backing for TSP Basic credentials.
# The common-credential-provider, when registered as a v2 connector, exposes the `secret`
# interface and acts as the vault provider -- no separate vault service is needed. This v2
# registration runs at the same URL/port as the v1 credential-provider (PORT_CRED_PROVIDER).
VAULT_CONNECTOR_NAME="common-credential-provider-v2"
VAULT_INSTANCE_NAME="vault"
VAULT_PROFILE_NAME="timestamping"
# The common-credential-provider vault requires no data attributes at either the instance or the
# profile level (its listVaultAttributes / listVaultProfileAttributes both return an empty list),
# so both creation requests send an empty attributes array. Hardcoded here; not parametrized.

# Mapped user the TSP Basic credentials authenticate as (created if absent; no certificate).
MAPPED_USER_USERNAME="f.jednicka"
MAPPED_USER_FIRST_NAME="Franta Pepa"
MAPPED_USER_LAST_NAME="Jednicka"
MAPPED_USER_EMAIL="franta.pepa.jednicka@example.com"

# Role granting the mapped user the TSP timestamping right (resource 'tspProfiles', action 'timestamp').
# Without it, every TSP request is rejected by the OPA authorization check in TsaServiceImpl.
MAPPED_USER_ROLE_NAME="timestamping"

# TSP Basic credential (created on both TSP profiles).
TSP_CREDENTIAL_USERNAME="f.jednicka"
TSP_CREDENTIAL_PASSWORD="tsp-test-changeme"

# Policy OIDs (hardcoded; no CLI override)
POLICY_ID_NON_QUALIFIED="1.2.3.4.5.6"
POLICY_ID_QUALIFIED="1.2.3.4.5.7"

# Request validation lists written onto the signing profiles.
# Comma-separated; the value "any" (any case) provisions an empty list (accept anything).
ALLOWED_POLICY_IDS=""                                # empty: the set's own policy OID only
ALLOWED_DIGEST_ALGORITHMS="SHA-256,SHA-384,SHA-512"  # codes from the DigestAlgorithm enum

# Time Quality configuration (used by the qualified signing profile)
TIME_QUALITY_CONFIG_NAME="time-quality"
TIME_QUALITY_NTP_SERVERS="ntp"       # comma-separated list, e.g. "pool.ntp.org,time.cloudflare.com"
TIME_QUALITY_ACCURACY="PT1S"
TIME_QUALITY_NTP_CHECK_INTERVAL="PT0.5S"
TIME_QUALITY_NTP_CHECK_TIMEOUT="PT0.3S"
TIME_QUALITY_NTP_SAMPLES_PER_SERVER=3
TIME_QUALITY_NTP_SERVERS_MIN_REACHABLE=1
TIME_QUALITY_MAX_CLOCK_DRIFT="PT0.8S"
TIME_QUALITY_LEAP_SECOND_GUARD=true

CERT_POLL_ATTEMPTS=20  # max poll attempts for certificate issuance
CERT_POLL_INTERVAL=1   # seconds between poll attempts

JSON_SUMMARY_FILE=""   # --json-summary target; empty disables the JSON summary

# --- Result variables (populated by setup functions) --------------------------
CLIENT_CERT_HEADER_VAL=""
CURL_AUTH_ARGS=()           # curl auth arguments, built by configure_authentication
MTLS_CERT_PEM=""            # mtls mode: temp file holding client cert extracted from PKCS12 (OpenSSL curl only)
MTLS_KEY_PEM=""             # mtls mode: temp file holding client key extracted from PKCS12 (OpenSSL curl only)
CRED_CONN_UUID=""                  CRED_CONN_NAME=""
EJBCA_CONN_UUID=""                 EJBCA_CONN_NAME=""
CRYPTO_CONN_UUID=""                CRYPTO_CONN_NAME=""
TIMESTAMP_FORMATTING_CONN_UUID=""  TIMESTAMP_FORMATTING_CONN_NAME=""
VAULT_CONN_UUID=""                 VAULT_CONN_NAME=""
CRED_UUID=""
AUTH_UUID=""
TOKEN_UUID=""
PIN_SECRET_NAME=""
PIN_SECRET_UUID=""
TOKEN_PROFILE_UUID=""
VAULT_INSTANCE_UUID=""
VAULT_PROFILE_UUID=""
MAPPED_USER_UUID=""
MAPPED_USER_ROLE_UUID=""
ISSUER_CA_UUID=""
KEY_SPEC_PAIRS="{}"         # --key-spec as a JSON object

# Time Quality configuration
TIME_QUALITY_UUID=""
# Settings as stored on the server.
TIME_QUALITY_EFFECTIVE_ACCURACY=""
TIME_QUALITY_EFFECTIVE_NTP_SERVERS_JSON="[]"
TIME_QUALITY_EFFECTIVE_NTP_CHECK_INTERVAL=""
TIME_QUALITY_EFFECTIVE_NTP_CHECK_TIMEOUT=""
TIME_QUALITY_EFFECTIVE_NTP_SAMPLES_PER_SERVER=""
TIME_QUALITY_EFFECTIVE_NTP_SERVERS_MIN_REACHABLE=""
TIME_QUALITY_EFFECTIVE_MAX_CLOCK_DRIFT=""
TIME_QUALITY_EFFECTIVE_LEAP_SECOND_GUARD=""

# Non-qualified set
KEY_UUID_NQ=""
PRIVATE_KEY_ITEM_UUID_NQ=""
RA_PROFILE_UUID_NQ=""
ISSUED_CERT_UUID_NQ=""
ISSUED_CERT_CN_NQ=""
TSP_PROFILE_UUID_NQ=""
TSP_CREDENTIAL_UUID_NQ=""
SIGNING_PROFILE_UUID_NQ=""
POLICY_OID_NQ=""
TIME_QUALITY_UUID_NQ=""

# Qualified set
KEY_UUID_Q=""
PRIVATE_KEY_ITEM_UUID_Q=""
RA_PROFILE_UUID_Q=""
ISSUED_CERT_UUID_Q=""
ISSUED_CERT_CN_Q=""
TSP_PROFILE_UUID_Q=""
TSP_CREDENTIAL_UUID_Q=""
SIGNING_PROFILE_UUID_Q=""
POLICY_OID_Q=""
TIME_QUALITY_UUID_Q=""

# --- Usage --------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Required:
  --pkcs12-bundle FILE        Path to PKCS12 bundle with EJBCA client credentials
  --certificate-dn PREFIX     DN prefix for TSA certificates (optional with --set-name).
                              Actual CNs will be <PREFIX>-non-qualified and <PREFIX>-qualified.
  Plus the admin credential for the chosen --auth-mode (see "ILM API auth").

Connector options (defaults: localhost, ports 8200/8210/8230/8290/8270):
  --connector-host HOST            hostname for connectors as seen from ILM server
  --port-cred-provider PORT        common-credential-provider port     (default: 8200)
  --port-ejbca PORT                ejbca-ng-connector port             (default: 8210)
  --port-crypto-provider PORT      software-cryptography-provider port (default: 8230)
  --port-pkcs11-provider PORT      pkcs11-cryptography-provider port   (default: 8290)
  --port-timestamp-formatting PORT timestamp-formatting-connector port (default: 8270)
  --timestamp-formatting-connector-name NAME
                                   timestamp formatting connector name (default: timestamp-formatting-connector)
  --vault-connector-name NAME      credential-provider v2 connector used as vault
                                   (default: common-credential-provider-v2; runs on --port-cred-provider)

Vault / Basic credential options:
  --vault-instance-name NAME  Vault instance name (created if absent; default: vault)
  --vault-profile-name NAME   Vault profile name (created if absent; default: timestamping)
  --mapped-user-username NAME Username of the mapped user for Basic credentials (default: f.jednicka)
  --tsp-credential-username NAME  Basic credential username (default: f.jednicka)
  --tsp-credential-password PASS  Basic credential password (default: tsp-test-changeme)

Cryptography provider options:
  --crypto-provider PROVIDER  Where the TSA keys live     (default: software-v2)
                              software-v1  software-cryptography-provider (v1 connector)
                              software-v2  software-cryptography-provider (v2 connector)
                              pkcs11       pkcs11-cryptography-provider   (v2-only connector)
  --pkcs11-profile NAME       pkcs11 config profile, specifying the proxy sidecar  (default: softhsm)
  --pkcs11-token LABEL        pkcs11 token label (default: softhsm)
  --pin-env VAR               env. variable with pkcs11 token user PIN (default: SOFTHSM_USER_PIN)

Credential/token options:
  --pkcs12-password PASS      PKCS12 bundle password     (default: 00000000)
  --token-password PASS       Software provider token code (default: same as pkcs12-password)

ILM API auth:
  --ilm-host HOST             URL of ILM API                (default: http://localhost:8080)
                              For a remote instance use the API origin, e.g.
                              https://semik7.3key.company (NOT the /administrator/ FE path).
  --auth-mode MODE            header | mtls                 (default: header)
  --client-cert-pem FILE      Admin client certificate PEM  (required for --auth-mode header)
  --client-p12-bundle FILE    Admin client PKCS12 bundle    (required for --auth-mode mtls)
  --client-p12-password PASS  Admin PKCS12 password
  --insecure-tls              Skip server TLS verification  (mtls only; for untrusted/demo certs)

EJBCA options:
  --ejbca-url URL             EJBCA WSDL URL                     (default https://ejbca.3key.company/ejbca/ejbcaws/ejbcaws?wsdl)
  --ejbca-ca NAME             Issuing CA name                    (default: DemoRootCA_2307RSA)
  --ejbca-ee-profile NAME     End entity profile (both sets)     (default: DemoTSAEndEntityProfile)
  --ejbca-cert-profile NAME   Certificate profile (non-qualified)(default: DemoTSAEECertificateProfile)
  --ejbca-cert-profile-qualified NAME
                              Certificate profile (qualified)    (default: DemoTSAQCEECertificateProfile)
  --issuer-ca FILE            One root CA certificate (PEM or DER)

Object name bases (suffixes -non-qualified / -qualified are appended automatically):
  --credential-name NAME      (default: ejbca.3key.company)
  --authority-name NAME       (default: ejbca.3key.company)
  --token-name NAME           (default: tsa)
  --token-profile-name NAME   (default: tsa)
  --set-name NAME             names a set: ${DEFAULT_TSA_NAME_BASE}-NAME for its key, RA and Signing Profile,
                              ${DEFAULT_TSP_NAME_BASE}-NAME for its TSP profile, NAME-<UTC timestamp> as its --certificate-dn
  --key-name NAME             base for key names          (default: ${DEFAULT_KEY_NAME_BASE})
  --ra-profile-name NAME      base for RA profile names   (default: ${DEFAULT_TSA_NAME_BASE})
  --tsp-profile-name NAME     base for TSP profile names  (default: ${DEFAULT_TSP_NAME_BASE})
  --signing-profile-name NAME base for Signing Profile names (default: ${DEFAULT_TSA_NAME_BASE})

Key and signature:
  --key-algorithm ALG         e.g. RSA | ECDSA | ML-DSA | SLH-DSA (default: RSA)
  --key-spec NAME=VALUE,...   key-spec fields, e.g. data_ecdsaCurve=secp384r1 (default: RSA 2048 bits, ML-DSA level 3)
  --signature-scheme SCHEME   data_rsaSigScheme, e.g. PKCS1-v1_5 | PSS (default: ${DEFAULT_SIGNATURE_SCHEME})
  --signature-digest DIGEST   data_sigDigest, e.g. SHA-256 | SHA-384 | SHA-512 (default: ${DEFAULT_SIGNATURE_DIGEST})

Certificate polling:
  --cert-poll-attempts N      Max poll attempts for certificate issuance (default: 20)
  --cert-poll-interval N      Seconds between poll attempts              (default: 1)

Request validation:
  --allowed-policy-ids LIST   comma-separated TSA policy OIDs (default: own policy OID)
                              use "any" (any case) for an empty, unrestricted list
                              the set's own policy OID always joins a non-empty list
  --allowed-digest-algorithms LIST comma-separated DigestAlgorithm (default: SHA-256,SHA-384,SHA-512)
                              use "any" (any case) for an empty, unrestricted list
  Neither accepts an empty value. Both apply only to Signing Profiles created by this run.

Output:
  --json-summary FILE         Reports the provisioned objects to FILE as JSON, in addition
                              to the human-readable summary on stdout. Rotates an existing
                              TSP Basic credential to --tsp-credential-password. The rotation
                              reaches the TSP credential cache asynchronously.

Time Quality configuration (used by the qualified signing profile):
  --time-quality-name NAME                    (default: time-quality)
  --time-quality-ntp-servers SERVERS          Comma-separated NTP server list (default: ntp)
  --time-quality-accuracy DURATION            ISO-8601 duration (default: PT1S)
  --time-quality-ntp-check-interval DURATION  ISO-8601 duration (default: PT0.5S)
  --time-quality-ntp-check-timeout DURATION   ISO-8601 duration (default: PT0.3S)
  --time-quality-ntp-samples-per-server N     (default: 3)
  --time-quality-ntp-servers-min-reachable N  (default: 1)
  --time-quality-max-clock-drift DURATION     ISO-8601 duration (default: PT0.8S)
  --time-quality-leap-second-guard BOOL       true|false (default: true)
EOF
  exit 1
}

# --- Helpers ------------------------------------------------------------------

log()  { echo "==> $*" >&2; }
ok()   { echo "    OK: $*" >&2; }
warn() { echo "    WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

TEMP_FILES=()
cleanup() { [[ ${#TEMP_FILES[@]} -gt 0 ]] && rm -f "${TEMP_FILES[@]}"; return 0; }

# INT and TERM exit with the signal's status. The EXIT trap alone then removes TEMP_FILES.
install_cleanup_traps() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# ilm_curl METHOD PATH [-d BODY]
# Fails with a clear message on non-2xx HTTP status.
ilm_curl() {
  local method="$1"; shift
  local path="$1"; shift
  local tmp err http_code response curl_err
  tmp=$(mktemp); err=$(mktemp)
  # Why `|| true`? On a connection/TLS failure curl exits non-zero and `set -e` would abort before the status check below.
  # Swallow curl's exit so the http_code check (000 on connection failure) produces the shaped error message instead.
  http_code=$(curl -s --show-error -o "$tmp" -w "%{http_code}" -X "$method" \
    "${CURL_AUTH_ARGS[@]}" \
    -H "content-type: application/json" \
    "${ILM_HOST}/api${path}" \
    "$@" 2>"$err" || true)
  response=$(<"$tmp"); curl_err=$(<"$err"); rm -f "$tmp" "$err"
  if [[ "$http_code" == "000" ]]; then
    die "Could not reach ILM at ${ILM_HOST} (${method} /api${path}): ${curl_err:-connection failed}"
  fi
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    die "HTTP ${http_code} on ${method} /api${path}: ${response}"
  fi
  echo "$response"
}

# require_uuid RESPONSE CONTEXT -- extracts .uuid from JSON; exits if missing or null
require_uuid() {
  local uuid
  uuid=$(echo "$1" | jq -r '.uuid // empty')
  [[ -z "$uuid" ]] && die "No UUID returned for $2. Response: $1"
  echo "$uuid"
}

# die_missing_attribute ATTRS_JSON EXPECTATION
# Prints each received attribute so the script can be updated.
die_missing_attribute() {
  echo "ERROR: Expected ${2} -- not found." >&2
  echo "       Received attributes:" >&2
  echo "$1" | jq -r \
    '.[] | "         name=\(.name)  contentType=\(.contentType // "(none)")  type=\(.type)"' >&2
  exit 1
}

# attr_uuid ATTRS_JSON EXPECTED_NAME EXPECTED_CONTENT_TYPE
# Looks up the uuid of an attribute by name + contentType (the stable contract).
attr_uuid() {
  local attrs="$1" name="$2" content_type="$3"
  local uuid
  uuid=$(echo "$attrs" | jq -r \
    --arg n "$name" --arg ct "$content_type" \
    'first(.[] | select(.name==$n and .contentType==$ct) | .uuid) // empty')
  [[ -z "$uuid" ]] && die_missing_attribute "$attrs" "attribute  name='${name}'  contentType='${content_type}'"
  echo "$uuid"
}

# group_uuid ATTRS_JSON EXPECTED_NAME
# Like attr_uuid but for group-type attributes, which carry no contentType.
group_uuid() {
  local attrs="$1" name="$2"
  local uuid
  uuid=$(echo "$attrs" | jq -r \
    --arg n "$name" \
    'first(.[] | select(.name==$n and .type=="group") | .uuid) // empty')
  [[ -z "$uuid" ]] && die_missing_attribute "$attrs" "group attribute  name='${name}'"
  echo "$uuid"
}

# offers_attribute ATTRS_JSON NAME
offers_attribute() {
  [[ -n "$(echo "$1" | jq -r --arg n "$2" 'first(.[] | select(.name==$n) | .uuid) // empty')" ]]
}

# request_attribute ATTRS_JSON NAME CONTENT_JSON
request_attribute() {
  local attrs="$1" name="$2" content="$3"
  offers_attribute "$attrs" "$name" || die_missing_attribute "$attrs" "attribute  name='${name}'"
  echo "$attrs" | jq -c --arg n "$name" --argjson content "$content" '
    first(.[] | select(.name==$n)) as $d
    | if ($d.version | tostring | ltrimstr("v")) == "3"
      then {name: $n, content: ($content | map({contentType: $d.contentType} + .)),
            contentType: $d.contentType, uuid: $d.uuid, version: "v3"}
      else {name: $n, content: ($content | map(del(.contentType))),
            contentType: $d.contentType, uuid: $d.uuid, version: "v2"}
      end'
}

# chosen_attribute ATTRS_JSON NAME VALUE
chosen_attribute() {
  local attrs="$1" name="$2" value="$3" item
  item=$(echo "$attrs" | jq -c --arg n "$name" --arg v "$value" \
    'first(.[] | select(.name==$n) | .content[]? | select((.data | tostring) == $v)) // empty')
  if [[ -z "$item" ]]; then
    offers_attribute "$attrs" "$name" || die_missing_attribute "$attrs" "attribute  name='${name}'"
    die "Attribute '${name}' offers no value '${value}'. Offered: $(echo "$attrs" \
      | jq -c --arg n "$name" '[.[] | select(.name==$n) | .content[]?.data]')"
  fi
  request_attribute "$attrs" "$name" "$(echo "$item" | jq -c '[.]')"
}

# --- Idempotent reuse helpers -------------------------------------------------
# find_named_item <json_array> <name> -> compact JSON of the first element whose .name equals <name>, or empty.
find_named_item() {
  echo "$1" | jq -c --arg n "$2" 'first(.[] | select(.name==$n)) // empty'
}

# uuid_of_named <list_json> <name> -> the item's uuid, or empty if not found.
uuid_of_named() {
  local match; match=$(find_named_item "$1" "$2") || exit 1
  [[ -n "$match" ]] && echo "$match" | jq -r '.uuid // empty'
  return 0
}

# list_paginated <path> -> JSON array of .items for POST .../list endpoints
list_paginated() {
  ilm_curl POST "$1" -d '{"itemsPerPage":1000,"pageNumber":1,"filters":[]}' | jq '.items // []'
}

# trim <string> -> the string without leading and trailing whitespace.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# csv_to_json_array <csv> [fallback_csv]
csv_to_json_array() {
  local csv fallback
  csv=$(trim "${1:-}") || exit 1
  fallback=$(trim "${2:-}") || exit 1
  [[ -z "$csv" ]] && csv="$fallback"
  [[ -z "$csv" || "$(printf '%s' "$csv" | tr '[:upper:]' '[:lower:]')" == "any" ]] && { echo '[]'; return 0; }
  jq -cn --arg csv "$csv" '$csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# --- Argument parsing ---------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pkcs12-bundle)                          PKCS12_BUNDLE="$2";                          shift 2 ;;
      --pkcs12-password)                        PKCS12_PASSWORD="$2";                        shift 2 ;;
      --token-password)                         TOKEN_PASSWORD="$2";                         shift 2 ;;
      --certificate-dn)                         CERTIFICATE_CN_PREFIX="$2";                  shift 2 ;;
      --ejbca-url)                              EJBCA_URL="$2";                              shift 2 ;;
      --connector-host)                         CONNECTOR_HOST="$2";                         shift 2 ;;
      --port-cred-provider)                     PORT_CRED_PROVIDER="$2";                     shift 2 ;;
      --port-ejbca)                             PORT_EJBCA="$2";                             shift 2 ;;
      --port-crypto-provider)                   PORT_CRYPTO_PROVIDER="$2";                   shift 2 ;;
      --port-pkcs11-provider)                   PORT_PKCS11_PROVIDER="$2";                   shift 2 ;;
      --crypto-provider)                        CRYPTO_PROVIDER="$2";                        shift 2 ;;
      --pkcs11-profile)                         PKCS11_PROFILE="$2";                         shift 2 ;;
      --pkcs11-token)                           PKCS11_TOKEN="$2";                           shift 2 ;;
      --pin-env)                                PIN_ENV="$2";                                shift 2 ;;
      --port-timestamp-formatting)              PORT_TIMESTAMP_FORMATTING="$2";              shift 2 ;;
      --timestamp-formatting-connector-name)    TIMESTAMP_FORMATTING_CONNECTOR_NAME="$2";    shift 2 ;;
      --vault-connector-name)                   VAULT_CONNECTOR_NAME="$2";                   shift 2 ;;
      --vault-instance-name)                    VAULT_INSTANCE_NAME="$2";                    shift 2 ;;
      --vault-profile-name)                     VAULT_PROFILE_NAME="$2";                     shift 2 ;;
      --mapped-user-username)                   MAPPED_USER_USERNAME="$2";                   shift 2 ;;
      --tsp-credential-username)                TSP_CREDENTIAL_USERNAME="$2";                shift 2 ;;
      --tsp-credential-password)                TSP_CREDENTIAL_PASSWORD="$2";                shift 2 ;;
      --ilm-host)                               ILM_HOST="$2";                               shift 2 ;;
      --auth-mode)                              AUTH_MODE="$2";                              shift 2 ;;
      --client-cert-pem)                        CLIENT_CERT_PEM="$2";                        shift 2 ;;
      --client-p12-bundle)                      CLIENT_P12_BUNDLE="$2";                      shift 2 ;;
      --client-p12-password)                    CLIENT_P12_PASSPHRASE="$2";                  shift 2 ;;
      --insecure-tls)                           INSECURE_TLS="true";                         shift   ;;
      --ejbca-ee-profile)                       EJBCA_EE_PROFILE="$2";                       shift 2 ;;
      --ejbca-cert-profile)                     EJBCA_CERT_PROFILE="$2";                     shift 2 ;;
      --ejbca-cert-profile-qualified)           EJBCA_CERT_PROFILE_QUALIFIED="$2";           shift 2 ;;
      --ejbca-ca)                               EJBCA_CA_NAME="$2";                          shift 2 ;;
      --credential-name)                        CREDENTIAL_NAME="$2";                        shift 2 ;;
      --authority-name)                         AUTHORITY_NAME="$2";                         shift 2 ;;
      --token-name)                             TOKEN_NAME="$2";                             shift 2 ;;
      --token-profile-name)                     TOKEN_PROFILE_NAME="$2";                     shift 2 ;;
      --key-name)                               KEY_NAME_BASE="$2";                          shift 2 ;;
      --key-algorithm)                          KEY_ALGORITHM="$2";                          shift 2 ;;
      --key-spec)                               KEY_SPEC="$2";                               shift 2 ;;
      --signature-scheme)                       SIGNATURE_SCHEME="$2";                       shift 2 ;;
      --signature-digest)                       SIGNATURE_DIGEST="$2";                       shift 2 ;;
      --issuer-ca)                              ISSUER_CA_FILE="$2";                         shift 2 ;;
      --set-name)                               SET_NAME="$2";                               shift 2 ;;
      --ra-profile-name)                        RA_PROFILE_NAME_BASE="$2";                   shift 2 ;;
      --tsp-profile-name)                       TSP_PROFILE_NAME_BASE="$2";                  shift 2 ;;
      --signing-profile-name)                   SIGNING_PROFILE_NAME_BASE="$2";              shift 2 ;;
      --cert-poll-attempts)                     CERT_POLL_ATTEMPTS="$2";                     shift 2 ;;
      --cert-poll-interval)                     CERT_POLL_INTERVAL="$2";                     shift 2 ;;
      --allowed-policy-ids)                     ALLOWED_POLICY_IDS="$2";                     shift 2 ;;
      --allowed-digest-algorithms)              ALLOWED_DIGEST_ALGORITHMS="$2";              shift 2 ;;
      --json-summary)                           JSON_SUMMARY_FILE="$2";                      shift 2 ;;
      --time-quality-name)                      TIME_QUALITY_CONFIG_NAME="$2";               shift 2 ;;
      --time-quality-ntp-servers)               TIME_QUALITY_NTP_SERVERS="$2";               shift 2 ;;
      --time-quality-accuracy)                  TIME_QUALITY_ACCURACY="$2";                  shift 2 ;;
      --time-quality-ntp-check-interval)        TIME_QUALITY_NTP_CHECK_INTERVAL="$2";        shift 2 ;;
      --time-quality-ntp-check-timeout)         TIME_QUALITY_NTP_CHECK_TIMEOUT="$2";         shift 2 ;;
      --time-quality-ntp-samples-per-server)    TIME_QUALITY_NTP_SAMPLES_PER_SERVER="$2";    shift 2 ;;
      --time-quality-ntp-servers-min-reachable) TIME_QUALITY_NTP_SERVERS_MIN_REACHABLE="$2"; shift 2 ;;
      --time-quality-max-clock-drift)           TIME_QUALITY_MAX_CLOCK_DRIFT="$2";           shift 2 ;;
      --time-quality-leap-second-guard)         TIME_QUALITY_LEAP_SECOND_GUARD="$2";         shift 2 ;;
      --help|-h)                     usage ;;
      *) echo "Unknown option: $1"; usage ;;
    esac
  done
}

# --- Validation ---------------------------------------------------------------
validate() {
  local errors=0
  command -v jq     &>/dev/null || { echo "ERROR: jq is required but not installed";     exit 1; }
  command -v curl   &>/dev/null || { echo "ERROR: curl is required but not installed";   exit 1; }
  command -v base64 &>/dev/null || { echo "ERROR: base64 is required but not installed"; exit 1; }
  resolve_object_names
  [[ -z "$PKCS12_BUNDLE" ]] && { echo "ERROR: --pkcs12-bundle is required"; errors=$((errors+1)); }
  [[ -z "$CERTIFICATE_CN_PREFIX" ]] && { echo "ERROR: --certificate-dn or --set-name is required"; errors=$((errors+1)); }
  case "$AUTH_MODE" in
    header) [[ -z "$CLIENT_CERT_PEM" ]]   && { echo "ERROR: --client-cert-pem is required for --auth-mode header"; errors=$((errors+1)); } ;;
    mtls)   [[ -z "$CLIENT_P12_BUNDLE" ]] && { echo "ERROR: --client-p12-bundle is required for --auth-mode mtls"; errors=$((errors+1)); } ;;
    *)      echo "ERROR: --auth-mode must be 'header' or 'mtls' (got '$AUTH_MODE')";                               errors=$((errors+1)) ;;
  esac
  [[ -n "$ALLOWED_POLICY_IDS" && -z "$(trim "$ALLOWED_POLICY_IDS")" ]] \
    && { echo "ERROR: --allowed-policy-ids requires a non-blank value (use 'any' for an unrestricted list)"; errors=$((errors+1)); }
  [[ -z "$(trim "$ALLOWED_DIGEST_ALGORITHMS")" ]] \
    && { echo "ERROR: --allowed-digest-algorithms requires a non-blank value (use 'any' for an unrestricted list)"; errors=$((errors+1)); }
  [[ -z "$(trim "$TSP_CREDENTIAL_PASSWORD")" ]] \
    && { echo "ERROR: --tsp-credential-password requires a non-blank value"; errors=$((errors+1)); }
  KEY_ALGORITHM=$(echo "$KEY_ALGORITHM" | tr '[:lower:]' '[:upper:]')
  [[ "$KEY_ALGORITHM" == "MLDSA" ]] && KEY_ALGORITHM="ML-DSA"
  [[ -z "$KEY_ALGORITHM" ]] && { echo "ERROR: --key-algorithm requires a value"; errors=$((errors+1)); }
  KEY_SPEC_PAIRS=$(key_spec_pairs 2>/dev/null) \
    || { echo "ERROR: --key-spec takes NAME=VALUE,... (got '$KEY_SPEC')"; errors=$((errors+1)); }
  CRYPTO_PROVIDER=$(echo "$CRYPTO_PROVIDER" | tr '[:upper:]' '[:lower:]')
  case "$CRYPTO_PROVIDER" in
    software-v1|software-v2|pkcs11) ;;
    *) echo "ERROR: --crypto-provider must be software-v1, software-v2 or pkcs11 (got '$CRYPTO_PROVIDER')"; errors=$((errors+1)) ;;
  esac
  [[ "$PIN_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { echo "ERROR: --pin-env must reference an environment variable (got '$PIN_ENV')"; errors=$((errors+1)); }
  [[ $errors -gt 0 ]] && usage

  [[ ! -f "$PKCS12_BUNDLE" ]]   && { echo "ERROR: PKCS12 bundle not found: $PKCS12_BUNDLE"; exit 1; }
  if [[ -n "$ISSUER_CA_FILE" ]]; then
    [[ ! -f "$ISSUER_CA_FILE" ]] && { echo "ERROR: --issuer-ca file not found: $ISSUER_CA_FILE"; exit 1; }
    command -v openssl &>/dev/null || { echo "ERROR: openssl is required for --issuer-ca"; exit 1; }
  fi

  [[ -z "$TOKEN_PASSWORD" ]] && TOKEN_PASSWORD="$PKCS12_PASSWORD"

  validate_json_summary_destination
  configure_authentication
  configure_crypto_provider
}

resolve_object_names() {
  local tsa="$DEFAULT_TSA_NAME_BASE" tsp="$DEFAULT_TSP_NAME_BASE" key="$DEFAULT_KEY_NAME_BASE"
  if [[ -n "$SET_NAME" ]]; then
    [[ -z "$CERTIFICATE_CN_PREFIX" ]] && CERTIFICATE_CN_PREFIX=$(timestamped_cn_prefix "$SET_NAME")
    tsa="${DEFAULT_TSA_NAME_BASE}-${SET_NAME}"; tsp="${DEFAULT_TSP_NAME_BASE}-${SET_NAME}"; key="$tsa"
  fi
  KEY_NAME_BASE="${KEY_NAME_BASE:-$key}"
  RA_PROFILE_NAME_BASE="${RA_PROFILE_NAME_BASE:-$tsa}"
  TSP_PROFILE_NAME_BASE="${TSP_PROFILE_NAME_BASE:-$tsp}"
  SIGNING_PROFILE_NAME_BASE="${SIGNING_PROFILE_NAME_BASE:-$tsa}"
}

# timestamped_cn_prefix <set_name> -> <set_name>-<UTC timestamp>.
timestamped_cn_prefix() {
  echo "${1}-$(date -u +%Y%m%d-%H%M%S)"
}

configure_crypto_provider() {
  case "$CRYPTO_PROVIDER" in
    software-v1)
      KEY_ALGORITHM_ATTR="data_keyAlgorithm"; KEY_SPEC_GROUP="group_keySpec";     KEY_ALIAS_ATTR="data_keyAlias"
      RSA_KEY_SIZE_ATTR="data_rsaKeySize";    MLDSA_LEVEL_ATTR="data_mldsaLevel"; MLDSA_PREHASH_ATTR="data_mldsaPrehash" ;;
    software-v2)
      KEY_ALGORITHM_ATTR="data_keyAlgorithm"; KEY_SPEC_GROUP="group_keySpecV2";   KEY_ALIAS_ATTR="data_keyAlias"
      RSA_KEY_SIZE_ATTR="data_rsaKeySize";    MLDSA_LEVEL_ATTR="data_mldsaLevel"; MLDSA_PREHASH_ATTR="" ;;
    pkcs11)
      KEY_ALGORITHM_ATTR="keyAlgorithm";      KEY_SPEC_GROUP="keySpec";           KEY_ALIAS_ATTR="keyLabel"
      RSA_KEY_SIZE_ATTR="rsaKeySize";         MLDSA_LEVEL_ATTR="mlDsaLevel";      MLDSA_PREHASH_ATTR="" ;;
  esac
}

validate_json_summary_destination() {
  [[ -z "$JSON_SUMMARY_FILE" ]] && return 0

  [[ -d "$JSON_SUMMARY_FILE" ]] && die "--json-summary target is a directory: $JSON_SUMMARY_FILE"
  case "$JSON_SUMMARY_FILE" in
    */) die "--json-summary target names a directory, not a file: $JSON_SUMMARY_FILE" ;;
  esac
  local base; base=$(basename "$JSON_SUMMARY_FILE")
  [[ "$base" == "." || "$base" == ".." ]] \
    && die "--json-summary target names a directory, not a file: $JSON_SUMMARY_FILE"

  local dir; dir=$(dirname "$JSON_SUMMARY_FILE")
  mkdir -p "$dir" || die "Cannot create directory for --json-summary: $dir"

  local probe
  probe=$(mktemp "${dir}/.json-summary-probe.XXXXXX") \
    || die "Cannot write the --json-summary destination directory: $dir"
  rm -f "$probe"
  return 0
}

# Populates CURL_AUTH_ARGS according to AUTH_MODE.
configure_authentication() {
  if [[ "$AUTH_MODE" == "header" ]]; then
    [[ ! -f "$CLIENT_CERT_PEM" ]] && { echo "ERROR: Client cert PEM not found: $CLIENT_CERT_PEM"; exit 1; }
    # Extract the base64 body of the first certificate only, then URL-encode it.
    local _cert_b64
    _cert_b64=$(awk '/-----BEGIN CERTIFICATE-----/ { body = 1; next }
                     /-----END CERTIFICATE-----/   { exit }
                     body' "$CLIENT_CERT_PEM" | tr -d '\n\r')
    [[ -n "$_cert_b64" ]] || { echo "ERROR: no certificate block found in: $CLIENT_CERT_PEM"; exit 1; }
    CLIENT_CERT_HEADER_VAL=$(printf '%s' "$_cert_b64" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')
    CURL_AUTH_ARGS=(-H "ssl-client-cert: ${CLIENT_CERT_HEADER_VAL}")
    return
  fi

  # mtls: present the admin PKCS12 as a real TLS client certificate.
  [[ ! -f "$CLIENT_P12_BUNDLE" ]] && { echo "ERROR: Admin PKCS12 not found: $CLIENT_P12_BUNDLE"; exit 1; }
  command -v openssl &>/dev/null || { echo "ERROR: openssl is required for --auth-mode mtls"; exit 1; }

  if curl -V | grep -qi "securetransport"; then
    # SecureTransport curl ignores PEM client certs - it needs a modern PKCS12 bundle (non-legacy PBE).
    if openssl pkcs12 -in "$CLIENT_P12_BUNDLE" -passin "pass:${CLIENT_P12_PASSPHRASE}" \
         -nokeys -clcerts -out /dev/null 2>/dev/null; then
      CURL_AUTH_ARGS=(--cert-type P12 --cert "$CLIENT_P12_BUNDLE" --pass "$CLIENT_P12_PASSPHRASE")
    elif openssl pkcs12 -legacy -in "$CLIENT_P12_BUNDLE" -passin "pass:${CLIENT_P12_PASSPHRASE}" \
         -nokeys -clcerts -out /dev/null 2>/dev/null; then
      die_unsupported_pkcs12 "$CLIENT_P12_BUNDLE"
    else
      die "Cannot read admin PKCS12 ${CLIENT_P12_BUNDLE} (wrong --client-p12-password or corrupt bundle?)"
    fi
  else
    # OpenSSL-backed curl loads PEM client certs directly: extract cert + key from the bundle.
    MTLS_CERT_PEM=$(mktemp)
    MTLS_KEY_PEM=$(mktemp)
    TEMP_FILES+=("$MTLS_CERT_PEM" "$MTLS_KEY_PEM")
    chmod 600 "$MTLS_CERT_PEM" "$MTLS_KEY_PEM"
    extract_p12_pem "$CLIENT_P12_BUNDLE" "$CLIENT_P12_PASSPHRASE" "$MTLS_CERT_PEM" "$MTLS_KEY_PEM"
    CURL_AUTH_ARGS=(--cert "$MTLS_CERT_PEM" --key "$MTLS_KEY_PEM")
  fi
  if [[ "$INSECURE_TLS" == "true" ]]; then
    CURL_AUTH_ARGS+=(--insecure)
  fi
}

# The admin PKCS12 uses a legacy PBE that SecureTransport curl cannot load.
die_unsupported_pkcs12() {
  local p12="$1" modern="${1%.p12}-modern.p12"
  cat >&2 <<EOF
ERROR: Admin PKCS12 '${p12}' uses a legacy encryption format that SecureTransport curl cannot load.

Convert it once to a modern PKCS12, then re-run with the converted bundle:

  read -rs P12_PASS                     # type the --client-p12-password, then press Enter
  openssl pkcs12 -legacy -in '${p12}' -passin "pass:\$P12_PASS" -nodes -out /tmp/admin-mtls.pem
  openssl pkcs12 -export -in /tmp/admin-mtls.pem -passout "pass:\$P12_PASS" -out '${modern}'
  rm -f /tmp/admin-mtls.pem; unset P12_PASS

Then re-run with:  --client-p12-bundle '${modern}'  (keep the same --client-p12-password)
EOF
  exit 1
}

# Keeps only the PEM blocks from stdin, dropping OpenSSL's "Bag Attributes" dump lines.
pem_only() { sed -n '/-----BEGIN /,/-----END /p'; }

# extract_p12_pem <p12> <password> <out_cert_pem> <out_key_pem>
# Splits a PKCS12 into a client-cert PEM and an unencrypted key PEM. Retries with
# -legacy for bundles using legacy PBE algorithms unsupported by OpenSSL 3 defaults.
extract_p12_pem() {
  local p12="$1" pass="$2" out_cert="$3" out_key="$4" legacy=""
  if ! openssl pkcs12 -in "$p12" -passin "pass:${pass}" -clcerts -nokeys 2>/dev/null | pem_only > "$out_cert"; then
    legacy="-legacy"
    openssl pkcs12 $legacy -in "$p12" -passin "pass:${pass}" -clcerts -nokeys 2>/dev/null | pem_only > "$out_cert" \
      || die "Failed to extract client certificate from ${p12} (wrong password or unsupported format?)"
  fi
  openssl pkcs12 $legacy -in "$p12" -passin "pass:${pass}" -nocerts -nodes 2>/dev/null | pem_only > "$out_key" \
    || die "Failed to extract private key from ${p12} (wrong password or unsupported format?)"
}

# --- Step 1: Connectors -------------------------------------------------------
# On a fresh local instance the connectors don't exist yet and are created.
# On a pre-provisioned instance they're already registered, in WAITING_FOR_APPROVAL status.
# v1 connectors are matched by function group + kind;
# v2 connectors are matched by provided interface and feature flag.
CONNECTORS_V1_JSON=""
CONNECTORS_V2_JSON=""

load_existing_connectors() {
  log "Listing existing connectors..."
  CONNECTORS_V1_JSON=$(ilm_curl GET /v1/connectors)
  CONNECTORS_V2_JSON=$(ilm_curl POST /v2/connectors/list -d \
    '{"itemsPerPage":1000,"pageNumber":1,"filters":[]}' | jq '.items // []')
}

# find_connector <connectors_json> <select_filter>
# Prints "<uuid>\t<statusCode>\t<name>" for the first matching connector, or nothing.
find_connector() {
  echo "$1" | jq -r "first(.[] | select($2)) // empty | \"\(.uuid)\t\(.status)\t\(.name // \"\")\""
}

# approve_connector <uuid> -- approves a WAITING_FOR_APPROVAL connector and waits until it reaches CONNECTED.
approve_connector() {
  local uuid="$1" attempt status details
  log "  Approving connector ${uuid}..."
  ilm_curl PATCH "/v2/connectors/${uuid}/approve" >/dev/null
  for (( attempt=1; attempt<=20; attempt++ )); do
    details=$(ilm_curl GET "/v1/connectors/${uuid}")
    status=$(echo "$details" | jq -r '.status // empty')
    [[ "$status" == "connected" ]] && { ok "  connector ${uuid} connected"; return 0; }
    sleep 0.5
  done
  die "Connector ${uuid} did not reach 'connected' after approval (last status: '${status}')"
}

# discover_or_create_connector <out_uuid_var> <out_name_var> <created_name> <desc> <connectors_json> <filter> <create_fn>
discover_or_create_connector() {
  local out_var="$1" out_name_var="$2" created_name="$3" desc="$4" connectors_json="$5" filter="$6" create_fn="$7"
  local match uuid status name
  match=$(find_connector "$connectors_json" "$filter")
  if [[ -n "$match" ]]; then
    IFS=$'\t' read -r uuid status name <<<"$match"
    log "Found pre-registered ${desc} connector '${name}' ${uuid} (status=${status})"
    [[ "$status" == "waitingForApproval" ]] && approve_connector "$uuid"
  else
    log "No pre-registered ${desc} connector found; creating it..."
    uuid=$("$create_fn")
    name="$created_name"
  fi
  printf -v "$out_var" '%s' "$uuid"
  printf -v "$out_name_var" '%s' "$name"
}

setup_connectors() {
  load_existing_connectors

  discover_or_create_connector CRED_CONN_UUID CRED_CONN_NAME "common-credential-provider" \
    "credential-provider" "$CONNECTORS_V1_JSON" \
    '(.functionGroups // []) | any(.functionGroupCode=="credentialProvider" and ((.kinds // []) | index("SoftKeyStore")))' \
    create_cred_connector
  ok "$CRED_CONN_NAME  $CRED_CONN_UUID"

  discover_or_create_connector EJBCA_CONN_UUID EJBCA_CONN_NAME "ejbca-ng-connector" \
    "authority (EJBCA)" "$CONNECTORS_V1_JSON" \
    '(.functionGroups // []) | any(.functionGroupCode=="authorityProvider" and ((.kinds // []) | index("EJBCA")))' \
    create_ejbca_connector
  ok "$EJBCA_CONN_NAME  $EJBCA_CONN_UUID"

  case "$CRYPTO_PROVIDER" in
    software-v1)
      discover_or_create_connector CRYPTO_CONN_UUID CRYPTO_CONN_NAME "software-cryptography-provider-v1" \
        "cryptography-provider v1" "$CONNECTORS_V1_JSON" \
        '(.functionGroups // []) | any(.functionGroupCode=="cryptographyProvider" and ((.kinds // []) | index("SOFT")))' \
        create_crypto_connector_v1 ;;
    software-v2)
      discover_or_create_connector CRYPTO_CONN_UUID CRYPTO_CONN_NAME "software-cryptography-provider-v2" \
        "cryptography-provider v2" "$CONNECTORS_V2_JSON" \
        ".url==\"http://${CONNECTOR_HOST}:${PORT_CRYPTO_PROVIDER}\" and .version==\"v2\"" \
        create_crypto_connector_v2 ;;
    pkcs11)
      discover_or_create_connector CRYPTO_CONN_UUID CRYPTO_CONN_NAME "pkcs11-cryptography-provider" \
        "pkcs11-cryptography-provider" "$CONNECTORS_V2_JSON" \
        ".url==\"http://${CONNECTOR_HOST}:${PORT_PKCS11_PROVIDER}\" and .version==\"v2\"" \
        create_pkcs11_connector ;;
  esac
  ok "$CRYPTO_CONN_NAME  $CRYPTO_CONN_UUID"

  discover_or_create_connector TIMESTAMP_FORMATTING_CONN_UUID TIMESTAMP_FORMATTING_CONN_NAME \
    "$TIMESTAMP_FORMATTING_CONNECTOR_NAME" "timestamp-formatting-connector" "$CONNECTORS_V2_JSON" \
    '(.interfaces // []) | any(.code=="signatureFormatting" and ((.features // []) | index("timestamping")))' \
    create_timestamp_formatting_connector
  ok "$TIMESTAMP_FORMATTING_CONN_NAME  $TIMESTAMP_FORMATTING_CONN_UUID"

  discover_or_create_connector VAULT_CONN_UUID VAULT_CONN_NAME \
    "$VAULT_CONNECTOR_NAME" "vault (credential-provider v2)" "$CONNECTORS_V2_JSON" \
    '(.interfaces // []) | any(.code=="secret")' \
    create_vault_connector
  ok "$VAULT_CONN_NAME  $VAULT_CONN_UUID"
}

# create_connector <name> <port> <version> <log_desc>
create_connector() {
  local name="$1" port="$2" version="$3" desc="$4"
  local _resp
  log "Creating ${desc}..."
  _resp=$(ilm_curl POST /v2/connectors -d \
    "{\"name\":\"${name}\",\"url\":\"http://${CONNECTOR_HOST}:${port}\",\"authType\":\"none\",\"customAttributes\":[],\"version\":\"${version}\"}") || exit 1
  require_uuid "$_resp" "${name} connector"
}

create_cred_connector()                 { create_connector "common-credential-provider"           "$PORT_CRED_PROVIDER"        "v1" "credential-provider connector (port ${PORT_CRED_PROVIDER})"; }
create_ejbca_connector()                { create_connector "ejbca-ng-connector"                   "$PORT_EJBCA"                "v1" "ejbca-ng connector (port ${PORT_EJBCA})"; }
create_crypto_connector_v1()            { create_connector "software-cryptography-provider-v1"    "$PORT_CRYPTO_PROVIDER"      "v1" "software-cryptography-provider v1 connector (port ${PORT_CRYPTO_PROVIDER})"; }
create_crypto_connector_v2()            { create_connector "software-cryptography-provider-v2"    "$PORT_CRYPTO_PROVIDER"      "v2" "software-cryptography-provider v2 connector (port ${PORT_CRYPTO_PROVIDER})"; }
create_pkcs11_connector()               { create_connector "pkcs11-cryptography-provider"         "$PORT_PKCS11_PROVIDER"      "v2" "pkcs11-cryptography-provider connector (port ${PORT_PKCS11_PROVIDER})"; }
create_timestamp_formatting_connector() { create_connector "$TIMESTAMP_FORMATTING_CONNECTOR_NAME" "$PORT_TIMESTAMP_FORMATTING" "v2" "timestamp-formatting-connector (port ${PORT_TIMESTAMP_FORMATTING})"; }
create_vault_connector()                { create_connector "$VAULT_CONNECTOR_NAME"                "$PORT_CRED_PROVIDER"        "v2" "credential-provider v2 connector for vault use (port ${PORT_CRED_PROVIDER})"; }

# --- Step 2: Credential -------------------------------------------------------
setup_credential() {
  local _resp cred_attr_defs ks_type_uuid ks_pass_uuid ks_file_uuid pkcs12_b64 pkcs12_filename _existing _list

  _list=$(ilm_curl GET /v1/credentials)
  _existing=$(find_named_item "$_list" "$CREDENTIAL_NAME")
  if [[ -n "$_existing" ]]; then
    CRED_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing credential '${CREDENTIAL_NAME}'  $CRED_UUID"
    return 0
  fi

  log "Fetching SoftKeyStore credential attribute definitions..."
  cred_attr_defs=$(ilm_curl GET \
    "/v1/connectors/${CRED_CONN_UUID}/attributes/credentialProvider/SoftKeyStore")
  ks_type_uuid=$(attr_uuid "$cred_attr_defs" "keyStoreType"     "string")
  ks_pass_uuid=$(attr_uuid "$cred_attr_defs" "keyStorePassword" "secret")
  ks_file_uuid=$(attr_uuid "$cred_attr_defs" "keyStore"         "file")

  log "Creating credential '${CREDENTIAL_NAME}' from $(basename "$PKCS12_BUNDLE")..."
  pkcs12_b64=$(base64 < "$PKCS12_BUNDLE" | tr -d '\n')
  pkcs12_filename=$(basename "$PKCS12_BUNDLE")

  _resp=$(ilm_curl POST /v1/credentials -d \
    "$(jq -n \
      --arg name        "$CREDENTIAL_NAME" \
      --arg connUuid    "$CRED_CONN_UUID" \
      --arg pass        "$PKCS12_PASSWORD" \
      --arg b64         "$pkcs12_b64" \
      --arg fname       "$pkcs12_filename" \
      --arg ksTypeUuid  "$ks_type_uuid" \
      --arg ksPassUuid  "$ks_pass_uuid" \
      --arg ksFileUuid  "$ks_file_uuid" \
      '{
        name: $name,
        connectorUuid: $connUuid,
        kind: "SoftKeyStore",
        attributes: [
          {
            name: "keyStoreType",
            content: [{data: "PKCS12", reference: "PKCS12"}],
            contentType: "string",
            uuid: $ksTypeUuid,
            version: "v2"
          },
          {
            name: "keyStorePassword",
            content: [{data: {secret: $pass}}],
            contentType: "secret",
            uuid: $ksPassUuid,
            version: "v2"
          },
          {
            name: "keyStore",
            content: [{data: {content: $b64, fileName: $fname, mimeType: "application/x-pkcs12"}}],
            contentType: "file",
            uuid: $ksFileUuid,
            version: "v2"
          }
        ],
        customAttributes: []
      }')")
  CRED_UUID=$(require_uuid "$_resp" "credential '${CREDENTIAL_NAME}'")
  ok "credential  $CRED_UUID"
}

# --- Step 3: Authority --------------------------------------------------------
setup_authority() {
  local _resp auth_attr_defs auth_url_uuid auth_cred_uuid _existing _list

  _list=$(ilm_curl GET /v1/authorities)
  _existing=$(find_named_item "$_list" "$AUTHORITY_NAME")
  if [[ -n "$_existing" ]]; then
    AUTH_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing authority '${AUTHORITY_NAME}'  $AUTH_UUID"
    return 0
  fi

  log "Fetching EJBCA authority attribute definitions..."
  auth_attr_defs=$(ilm_curl GET \
    "/v1/connectors/${EJBCA_CONN_UUID}/attributes/authorityProvider/EJBCA")
  auth_url_uuid=$(attr_uuid  "$auth_attr_defs" "url"        "string")
  auth_cred_uuid=$(attr_uuid "$auth_attr_defs" "credential" "credential")

  log "Creating EJBCA authority '${AUTHORITY_NAME}'..."
  _resp=$(ilm_curl POST /v1/authorities -d \
    "$(jq -n \
      --arg name         "$AUTHORITY_NAME" \
      --arg connUuid     "$EJBCA_CONN_UUID" \
      --arg credUuid     "$CRED_UUID" \
      --arg credName     "$CREDENTIAL_NAME" \
      --arg url          "$EJBCA_URL" \
      --arg authUrlUuid  "$auth_url_uuid" \
      --arg authCredUuid "$auth_cred_uuid" \
      '{
        name: $name,
        connectorUuid: $connUuid,
        kind: "EJBCA",
        attributes: [
          {
            name: "url",
            content: [{data: $url}],
            contentType: "string",
            uuid: $authUrlUuid,
            version: "v2"
          },
          {
            name: "credential",
            content: [{data: {uuid: $credUuid, name: $credName}, reference: $credName}],
            contentType: "credential",
            uuid: $authCredUuid,
            version: "v2"
          }
        ],
        customAttributes: []
      }')")
  AUTH_UUID=$(require_uuid "$_resp" "EJBCA authority '${AUTHORITY_NAME}'")
  ok "authority  $AUTH_UUID"
}

# --- Step 4: Vault instance ---------------------------------------------------
# Created (or reused) under the credential-provider v2 connector, bound to its `secret` interface.
# The connector requires no instance data attributes, so the request sends an empty attributes array.
setup_vault_instance() {
  local _resp _list _existing iface_uuid

  _list=$(list_paginated /v1/vaults/list)
  _existing=$(find_named_item "$_list" "$VAULT_INSTANCE_NAME")
  if [[ -n "$_existing" ]]; then
    VAULT_INSTANCE_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing vault instance '${VAULT_INSTANCE_NAME}'  $VAULT_INSTANCE_UUID"
    return 0
  fi

  iface_uuid=$(connector_interface_uuid "$VAULT_CONN_UUID" "secret")

  log "Creating vault instance '${VAULT_INSTANCE_NAME}'..."
  _resp=$(ilm_curl POST /v1/vaults -d \
    "$(jq -n \
      --arg name      "$VAULT_INSTANCE_NAME" \
      --arg connUuid  "$VAULT_CONN_UUID" \
      --arg ifaceUuid "$iface_uuid" \
      '{connectorUuid: $connUuid, interfaceUuid: $ifaceUuid, name: $name,
        attributes: [], customAttributes: []}')")
  VAULT_INSTANCE_UUID=$(require_uuid "$_resp" "vault instance '${VAULT_INSTANCE_NAME}'")
  ok "vault instance  $VAULT_INSTANCE_UUID"
}

# connector_interface_uuid <connector_uuid> <interface_code>
connector_interface_uuid() {
  local connector_uuid="$1" code="$2" iface
  iface=$(list_paginated /v2/connectors/list | jq -r --arg u "$connector_uuid" --arg c "$code" \
    'first(.[] | select(.uuid==$u) | .interfaces[] | select(.code==$c) | .uuid) // empty') || exit 1
  [[ -z "$iface" ]] && die "Connector ${connector_uuid} exposes no '${code}' interface"
  echo "$iface"
}

# --- Step 5: Vault profile ----------------------------------------------------
# Created under the (reused) vault instance; backs the TSP profiles' Basic credentials and token's user PIN.
# The connector requires no profile data attributes, so the request sends an empty attributes array.
setup_vault_profile() {
  local _resp _existing _list

  _list=$(list_paginated /v1/vaultProfiles/list)
  _existing=$(find_named_item "$_list" "$VAULT_PROFILE_NAME")
  if [[ -n "$_existing" ]]; then
    VAULT_PROFILE_UUID=$(echo "$_existing" | jq -r '.uuid')
    if [[ "$(echo "$_existing" | jq -r '.enabled // false')" != "true" ]]; then
      ilm_curl PATCH "/v1/vaults/${VAULT_INSTANCE_UUID}/vaultProfiles/${VAULT_PROFILE_UUID}/enable" >/dev/null
    fi
    ok "reusing existing vault profile '${VAULT_PROFILE_NAME}'  $VAULT_PROFILE_UUID"
    return 0
  fi

  log "Creating vault profile '${VAULT_PROFILE_NAME}'..."
  _resp=$(ilm_curl POST "/v1/vaults/${VAULT_INSTANCE_UUID}/vaultProfiles" -d \
    "$(jq -n --arg name "$VAULT_PROFILE_NAME" \
      '{name: $name, description: "", attributes: [], customAttributes: []}')")
  VAULT_PROFILE_UUID=$(require_uuid "$_resp" "vault profile '${VAULT_PROFILE_NAME}'")
  ok "vault profile  $VAULT_PROFILE_UUID"

  log "Enabling vault profile..."
  ilm_curl PATCH "/v1/vaults/${VAULT_INSTANCE_UUID}/vaultProfiles/${VAULT_PROFILE_UUID}/enable" >/dev/null
  ok "vault profile enabled"
}

# --- Step 6: Token ------------------------------------------------------------
SET_NAME_FLAGS="--set-name, or --key-name, --ra-profile-name, --tsp-profile-name, --signing-profile-name"
FRESH_TOKEN_NAMES_HINT="choose fresh object names (--token-name and --token-profile-name, plus ${SET_NAME_FLAGS}) and re-run"

# A token is reused by name only when it lives on the --crypto-provider connector.
setup_token() {
  local _resp _existing _list token_attrs kind=""

  _list=$(ilm_curl GET /v1/tokens)
  _existing=$(find_named_item "$_list" "$TOKEN_NAME")
  if [[ -n "$_existing" ]]; then
    TOKEN_UUID=$(echo "$_existing" | jq -r '.uuid')
    [[ "$(echo "$_existing" | jq -r '.connectorUuid // empty')" != "$CRYPTO_CONN_UUID" ]] && die \
      "Existing token '${TOKEN_NAME}' (${TOKEN_UUID}) lives on connector '$(echo "$_existing" | jq -r '.connectorName // "unknown"')', not on '${CRYPTO_CONN_NAME}'; pass the --crypto-provider it was created on, or ${FRESH_TOKEN_NAMES_HINT}"
    require_token_usable
    ok "reusing existing token '${TOKEN_NAME}'  $TOKEN_UUID"
    return 0
  fi

  case "$CRYPTO_PROVIDER" in
    software-v1) token_attrs=$(software_token_attributes); kind="SOFT" ;;
    software-v2) token_attrs=$(software_token_attributes) ;;
    pkcs11)      setup_pin_secret; token_attrs=$(pkcs11_token_attributes) ;;
  esac

  log "Creating token '${TOKEN_NAME}' on ${CRYPTO_CONN_NAME}..."
  _resp=$(ilm_curl POST /v1/tokens -d \
    "$(jq -n \
      --arg name     "$TOKEN_NAME" \
      --arg connUuid "$CRYPTO_CONN_UUID" \
      --arg kind     "$kind" \
      --argjson attributes "$token_attrs" \
      '{name: $name, connectorUuid: $connUuid, attributes: $attributes, customAttributes: []}
       + (if $kind == "" then {} else {kind: $kind} end)')")
  TOKEN_UUID=$(require_uuid "$_resp" "token '${TOKEN_NAME}'")
  ok "token  $TOKEN_UUID"
}

require_token_usable() {
  local reload status
  reload=$(ilm_curl PATCH "/v1/tokens/${TOKEN_UUID}") \
    || die "Could not reload existing token '${TOKEN_NAME}' (${TOKEN_UUID}) at connector '${CRYPTO_CONN_NAME}'; start the connector where it is down, else ${FRESH_TOKEN_NAMES_HINT}"
  status=$(echo "$reload" | jq -r '.status.status // empty | ascii_downcase')
  case "$status" in
    disconnected) die "Existing token '${TOKEN_NAME}' (${TOKEN_UUID}) is disconnected at connector '${CRYPTO_CONN_NAME}'; ${FRESH_TOKEN_NAMES_HINT}" ;;
    deactivated)  die "Existing token '${TOKEN_NAME}' (${TOKEN_UUID}) is deactivated at connector '${CRYPTO_CONN_NAME}'; activate it in Core, or ${FRESH_TOKEN_NAMES_HINT}" ;;
  esac
  return 0
}

# The software provider serves one token form on both registrations. It returns two different
# attribute schemas depending on whether it already has any token instances:
#   - empty connector  -> data_createTokenAction/newTokenName/tokenCode at top level
#   - has token(s)     -> a 'data_options' selector whose 'group_loadToken' callback (option=new) yields the real create attributes
# This script may run against either state, so it must handle both.
software_token_attributes() {
  local token_attr_defs form_path callback_path load_group_uuid create_attrs options_attr=""
  local action_attr name_attr code_attr

  if [[ "$CRYPTO_PROVIDER" == "software-v1" ]]; then
    form_path="/v1/connectors/${CRYPTO_CONN_UUID}/attributes/cryptographyProvider/SOFT"
    callback_path="/v1/connectors/${CRYPTO_CONN_UUID}/cryptographyProvider/SOFT/callback"
  else
    form_path="/v1/tokens/${CRYPTO_CONN_UUID}/attributes"
    callback_path="/v2/connectors/${CRYPTO_CONN_UUID}/callback"
  fi

  log "Fetching software provider token attribute definitions..."
  token_attr_defs=$(ilm_curl GET "$form_path") || exit 1

  if [[ -n "$(echo "$token_attr_defs" | jq -r 'first(.[] | select(.name=="data_options" and .type=="data") | .uuid) // empty')" ]]; then
    load_group_uuid=$(group_uuid "$token_attr_defs" "group_loadToken") || exit 1
    log "Resolving 'new token' attributes via connector callback..."
    create_attrs=$(ilm_curl POST "$callback_path" -d \
      "$(jq -n --arg uuid "$load_group_uuid" \
        '{uuid:$uuid,name:"group_loadToken",pathVariable:{option:"new"},requestParameter:{},body:{}}')") || exit 1
    options_attr=$(chosen_attribute "$token_attr_defs" "data_options" "new") || exit 1
  else
    create_attrs="$token_attr_defs"
  fi

  action_attr=$(request_attribute "$create_attrs" "data_createTokenAction" '[{"reference":"new","data":"new"}]') || exit 1
  # The connector names a keystore with letters, digits and underscores only.
  name_attr=$(request_attribute "$create_attrs" "data_newTokenName" \
    "$(jq -nc --arg name "${TOKEN_NAME//-/_}" '[{data: $name}]')") || exit 1
  code_attr=$(request_attribute "$create_attrs" "data_tokenCode" \
    "$(jq -nc --arg code "$TOKEN_PASSWORD" '[{data: {secret: $code}}]')") || exit 1
  jq -nc --argjson action "$action_attr" --argjson name "$name_attr" --argjson code "$code_attr" \
    --arg options "$options_attr" \
    '[$action, $name, $code] + (if $options == "" then [] else [$options | fromjson] end)'
}

# percent_decode TEXT
percent_decode() {
  local text="${1//\\/\\\\}"
  printf '%b' "${text//%/\\x}"
}

# pkcs11_uri_token_label URI
pkcs11_uri_token_label() {
  percent_decode "$(jq -rn --arg uri "$1" \
    '$uri | ltrimstr("pkcs11:") | split("?")[0] | split(";")[] | select(startswith("token=")) | ltrimstr("token=")')"
}

# A pkcs11 token is addressed by its config profile (ref proxy sidecar), and PKCS#11 URI of a token.
pkcs11_token_attributes() {
  local token_attr_defs profile_attr token_attr_uuid iface_uuid offered item label matches token_attr pin_attr

  log "Fetching pkcs11 token attribute definitions..."
  token_attr_defs=$(ilm_curl GET "/v1/tokens/${CRYPTO_CONN_UUID}/attributes") || exit 1
  profile_attr=$(chosen_attribute "$token_attr_defs" "profile" "$PKCS11_PROFILE") || exit 1
  token_attr_uuid=$(attr_uuid "$token_attr_defs" "token" "string") || exit 1
  iface_uuid=$(connector_interface_uuid "$CRYPTO_CONN_UUID" "cryptography") || exit 1

  log "Listing the tokens of profile '${PKCS11_PROFILE}' via connector callback..."
  offered=$(ilm_curl POST "/v2/connectors/${CRYPTO_CONN_UUID}/callback" -d \
    "$(jq -nc --arg uuid "$token_attr_uuid" --arg iface "$iface_uuid" --argjson profile "$profile_attr" \
      '{name: "token", uuid: $uuid, interfaceUuid: $iface, attributes: [$profile]}')") || exit 1
  matches="[]"
  while IFS= read -r item; do
    label=$(pkcs11_uri_token_label "$(echo "$item" | jq -r '.data')") || exit 1
    if [[ "$label" == "$PKCS11_TOKEN" ]]; then
      matches=$(echo "$matches" | jq -c --argjson item "$item" '. + [$item]')
    fi
  done < <(echo "$offered" | jq -c '.[]')
  case "$(echo "$matches" | jq 'length')" in
    1) ;;
    0) die "Profile '${PKCS11_PROFILE}' offers no token labelled '${PKCS11_TOKEN}'. Offered: $(echo "$offered" | jq -c '[.[].data]')" ;;
    *) die "Profile '${PKCS11_PROFILE}' offers more than one token labelled '${PKCS11_TOKEN}': $(echo "$matches" | jq -c '[.[].data]')" ;;
  esac

  token_attr=$(request_attribute "$token_attr_defs" "token" "$(echo "$matches" | jq -c '[.[0] | {data, reference}]')") || exit 1
  pin_attr=$(request_attribute "$token_attr_defs" "pin" \
    "$(jq -nc --arg uuid "$PIN_SECRET_UUID" --arg name "$PIN_SECRET_NAME" \
      '[{data: {resource: "secrets", uuid: $uuid, name: $name}}]')") || exit 1
  jq -nc --argjson profile "$profile_attr" --argjson token "$token_attr" --argjson pin "$pin_attr" \
    '[$profile, $token, $pin]'
}

setup_pin_secret() {
  local _list _existing _resp attempt state="" enabled=""
  PIN_SECRET_NAME="${TOKEN_NAME}-pin"

  _list=$(list_paginated /v1/secrets)
  _existing=$(find_named_item "$_list" "$PIN_SECRET_NAME")
  if [[ -n "$_existing" ]]; then
    PIN_SECRET_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing secret '${PIN_SECRET_NAME}'  $PIN_SECRET_UUID"
  else
    [[ -z "${!PIN_ENV:-}" ]] && die \
      "Environment variable ${PIN_ENV} holds no token user PIN; export it, or name another with --pin-env, to create secret '${PIN_SECRET_NAME}'"
    log "Creating secret '${PIN_SECRET_NAME}' holding the token user PIN from ${PIN_ENV}..."
    _resp=$(jq -n --arg name "$PIN_SECRET_NAME" --arg pinEnv "$PIN_ENV" \
        '{name: $name, description: "PKCS#11 token user PIN",
          secret: {type: "generic", content: $ENV[$pinEnv]}, attributes: [], customAttributes: []}' \
      | ilm_curl POST "/v1/vaults/${VAULT_INSTANCE_UUID}/vaultProfiles/${VAULT_PROFILE_UUID}/secrets" --data-binary @-)
    PIN_SECRET_UUID=$(require_uuid "$_resp" "secret '${PIN_SECRET_NAME}'")
    ok "secret  $PIN_SECRET_UUID"
  fi

  for (( attempt=1; attempt<=15; attempt++ )); do
    state=$(ilm_curl GET "/v1/secrets/${PIN_SECRET_UUID}" | jq -r '.state // empty')
    [[ "$state" == "active" ]] && break
    sleep 1
  done
  [[ "$state" != "active" ]] && die "Secret '${PIN_SECRET_NAME}' did not become active (last state: '${state}')"
  for (( attempt=1; attempt<=15; attempt++ )); do
    enabled=$(ilm_curl GET "/v1/secrets/${PIN_SECRET_UUID}" | jq -r '.enabled // false')
    [[ "$enabled" == "true" ]] && { ok "secret enabled"; return 0; }
    ilm_curl PATCH "/v1/secrets/${PIN_SECRET_UUID}/enable" >/dev/null
    sleep 1
  done
  die "Secret '${PIN_SECRET_NAME}' did not stay enabled"
}

# --- Step 7: Token profile ----------------------------------------------------
setup_token_profile() {
  local _resp _existing _list

  _list=$(ilm_curl GET /v1/tokenProfiles)
  _existing=$(find_named_item "$_list" "$TOKEN_PROFILE_NAME")
  if [[ -n "$_existing" ]]; then
    TOKEN_PROFILE_UUID=$(echo "$_existing" | jq -r '.uuid')
    [[ "$(echo "$_existing" | jq -r '.tokenInstanceUuid // empty')" != "$TOKEN_UUID" ]] && die \
      "Existing token profile '${TOKEN_PROFILE_NAME}' (${TOKEN_PROFILE_UUID}) belongs to token '$(echo "$_existing" | jq -r '.tokenInstanceName // "unknown"')', not to '${TOKEN_NAME}'; choose a fresh --token-profile-name and re-run"
    if [[ "$(echo "$_existing" | jq -r '.enabled // false')" != "true" ]]; then
      ilm_curl PATCH "/v1/tokens/${TOKEN_UUID}/tokenProfiles/${TOKEN_PROFILE_UUID}/enable" >/dev/null
    fi
    ok "reusing existing token profile '${TOKEN_PROFILE_NAME}'  $TOKEN_PROFILE_UUID"
    return 0
  fi

  log "Creating token profile '${TOKEN_PROFILE_NAME}'..."
  _resp=$(ilm_curl POST /v1/tokens/${TOKEN_UUID}/tokenProfiles -d \
    "$(jq -n --arg name "$TOKEN_PROFILE_NAME" \
      '{name: $name, description: "", attributes: [], customAttributes: [],
        usage: ["sign","verify","encrypt","decrypt"]}')")
  TOKEN_PROFILE_UUID=$(require_uuid "$_resp" "token profile '${TOKEN_PROFILE_NAME}'")
  ok "token profile  $TOKEN_PROFILE_UUID"

  log "Enabling token profile..."
  ilm_curl PATCH "/v1/tokens/${TOKEN_UUID}/tokenProfiles/${TOKEN_PROFILE_UUID}/enable" \
    >/dev/null
  ok "token profile enabled"
}

# --- Step 8: Time Quality configuration ---------------------------------------
# record_time_quality_settings <configuration_detail_json>
record_time_quality_settings() {
  TIME_QUALITY_EFFECTIVE_ACCURACY=$(echo "$1"                  | jq -r 'if .accuracy               == null then empty else .accuracy               end')
  TIME_QUALITY_EFFECTIVE_MAX_CLOCK_DRIFT=$(echo "$1"           | jq -r 'if .maxClockDrift          == null then empty else .maxClockDrift          end')
  TIME_QUALITY_EFFECTIVE_NTP_SERVERS_JSON=$(echo "$1"          | jq -c '.ntpServers // []')
  TIME_QUALITY_EFFECTIVE_NTP_CHECK_INTERVAL=$(echo "$1"        | jq -r 'if .ntpCheckInterval       == null then empty else .ntpCheckInterval       end')
  TIME_QUALITY_EFFECTIVE_NTP_CHECK_TIMEOUT=$(echo "$1"         | jq -r 'if .ntpCheckTimeout        == null then empty else .ntpCheckTimeout        end')
  TIME_QUALITY_EFFECTIVE_NTP_SAMPLES_PER_SERVER=$(echo "$1"    | jq -r 'if .ntpSamplesPerServer    == null then empty else .ntpSamplesPerServer    end')
  TIME_QUALITY_EFFECTIVE_NTP_SERVERS_MIN_REACHABLE=$(echo "$1" | jq -r 'if .ntpServersMinReachable == null then empty else .ntpServersMinReachable end')
  TIME_QUALITY_EFFECTIVE_LEAP_SECOND_GUARD=$(echo "$1"         | jq -r 'if .leapSecondGuard        == null then empty else .leapSecondGuard        end')
}

setup_time_quality_config() {
  local _resp ntp_servers_json _existing _list _detail

  _list=$(list_paginated /v1/timeQualityConfigurations/list)
  _existing=$(find_named_item "$_list" "$TIME_QUALITY_CONFIG_NAME")
  if [[ -n "$_existing" ]]; then
    TIME_QUALITY_UUID=$(echo "$_existing" | jq -r '.uuid')
    if [[ -n "$JSON_SUMMARY_FILE" ]]; then
      _detail=$(ilm_curl GET "/v1/timeQualityConfigurations/${TIME_QUALITY_UUID}")
      record_time_quality_settings "$_detail"
    fi
    ok "reusing existing Time Quality configuration '${TIME_QUALITY_CONFIG_NAME}'  $TIME_QUALITY_UUID"
    return 0
  fi

  # Convert comma-separated NTP server list to a JSON array
  ntp_servers_json=$(echo "$TIME_QUALITY_NTP_SERVERS" | \
    jq -Rc 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')

  log "Creating Time Quality configuration '${TIME_QUALITY_CONFIG_NAME}'..."
  _resp=$(ilm_curl POST /v1/timeQualityConfigurations -d \
    "$(jq -n \
      --arg  name              "$TIME_QUALITY_CONFIG_NAME" \
      --arg  accuracy          "$TIME_QUALITY_ACCURACY" \
      --argjson ntpServers     "$ntp_servers_json" \
      --arg  checkInterval     "$TIME_QUALITY_NTP_CHECK_INTERVAL" \
      --arg  checkTimeout      "$TIME_QUALITY_NTP_CHECK_TIMEOUT" \
      --argjson samplesPerSrv  "$TIME_QUALITY_NTP_SAMPLES_PER_SERVER" \
      --argjson minReachable   "$TIME_QUALITY_NTP_SERVERS_MIN_REACHABLE" \
      --arg  maxClockDrift     "$TIME_QUALITY_MAX_CLOCK_DRIFT" \
      --argjson leapSecGuard   "$TIME_QUALITY_LEAP_SECOND_GUARD" \
      '{
        name:                   $name,
        accuracy:               $accuracy,
        ntpServers:             $ntpServers,
        ntpCheckInterval:       $checkInterval,
        ntpCheckTimeout:        $checkTimeout,
        ntpSamplesPerServer:    $samplesPerSrv,
        ntpServersMinReachable: $minReachable,
        maxClockDrift:          $maxClockDrift,
        leapSecondGuard:        $leapSecGuard,
        customAttributes:       []
      }')")
  TIME_QUALITY_UUID=$(require_uuid "$_resp" "Time Quality configuration '${TIME_QUALITY_CONFIG_NAME}'")
  record_time_quality_settings "$_resp"
  ok "Time Quality configuration  $TIME_QUALITY_UUID"
}

# --- Step 9: Mapped user ------------------------------------------------------
# The user the TSP Basic credentials authenticate as. Created without a certificate; a basic
# credential may not map to a system user, so a dedicated regular user is used.
setup_mapped_user() {
  local _resp _list _existing
  _list=$(ilm_curl GET /v1/users)
  _existing=$(find_named_item "$_list" "$MAPPED_USER_USERNAME")
  if [[ -z "$_existing" ]]; then
    # GET /v1/users matches on .username, not .name
    _existing=$(echo "$_list" | jq -c --arg u "$MAPPED_USER_USERNAME" 'first(.[] | select(.username==$u)) // empty')
  fi
  if [[ -n "$_existing" ]]; then
    MAPPED_USER_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing user '${MAPPED_USER_USERNAME}'  $MAPPED_USER_UUID"
    return 0
  fi

  log "Creating user '${MAPPED_USER_USERNAME}' (${MAPPED_USER_FIRST_NAME} ${MAPPED_USER_LAST_NAME})..."
  _resp=$(ilm_curl POST /v1/users -d \
    "$(jq -n \
      --arg username  "$MAPPED_USER_USERNAME" \
      --arg firstName "$MAPPED_USER_FIRST_NAME" \
      --arg lastName  "$MAPPED_USER_LAST_NAME" \
      --arg email     "$MAPPED_USER_EMAIL" \
      '{username: $username, firstName: $firstName, lastName: $lastName, email: $email, enabled: true}')")
  MAPPED_USER_UUID=$(require_uuid "$_resp" "user '${MAPPED_USER_USERNAME}'")
  ok "user  $MAPPED_USER_UUID"
}

# --- Step 10: Timestamping role -----------------------------------------------
# Serving one RFC 3161 timestamp request runs OPA authorization checks as the calling user,
# scattered across the request path (TsaServiceImpl -> resolver -> CryptographicOperationServiceImpl):
#   tspProfiles/timestamp   - AuthPermissionEvaluationServiceImpl.tspProfileTimestamping (entry gate)
#   tspProfiles/detail      - TspProfileServiceImpl.getTspProfile
#   signingProfiles/detail  - SigningProfileServiceImpl.getSigningProfileModel
#   keys/sign               - CryptographicOperationServiceImpl.signDataWithoutEventHistory (the actual sign)
#   tokens/detail           - same method, parentResource on the sign annotation
#   tokenProfiles/detail    - tokenProfile permission evaluation
# A freshly created user has none of these, so without this step timestamp requests are rejected
# (often deep in the chain, not at the gate).
#
# This function only creates the role and attaches it to the user. The permissions are object-scoped
# to the concrete TSP/signing profiles, token and token profile, which only exist after the TSA sets
# are built -- so they are applied later by grant_timestamping_permissions().
setup_timestamping_role() {
  local _resp _existing _list _roles

  _list=$(ilm_curl GET /v1/roles)
  _existing=$(find_named_item "$_list" "$MAPPED_USER_ROLE_NAME")
  if [[ -n "$_existing" ]]; then
    MAPPED_USER_ROLE_UUID=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing role '${MAPPED_USER_ROLE_NAME}'  $MAPPED_USER_ROLE_UUID"
  else
    log "Creating role '${MAPPED_USER_ROLE_NAME}'..."
    _resp=$(ilm_curl POST /v1/roles -d \
      "$(jq -n --arg name "$MAPPED_USER_ROLE_NAME" \
        '{name: $name, description: "TSP timestamping for the mapped user", customAttributes: []}')")
    MAPPED_USER_ROLE_UUID=$(require_uuid "$_resp" "role '${MAPPED_USER_ROLE_NAME}'")
    ok "role  $MAPPED_USER_ROLE_UUID"
  fi

  _roles=$(ilm_curl GET "/v1/users/${MAPPED_USER_UUID}/roles")
  if [[ "$(echo "$_roles" | jq -r --arg u "$MAPPED_USER_ROLE_UUID" 'any(.[]; .uuid==$u)')" == "true" ]]; then
    ok "role already attached to user '${MAPPED_USER_USERNAME}'"
  else
    log "Attaching role '${MAPPED_USER_ROLE_NAME}' to user '${MAPPED_USER_USERNAME}'..."
    ilm_curl PUT "/v1/users/${MAPPED_USER_UUID}/roles/${MAPPED_USER_ROLE_UUID}" >/dev/null
    ok "role attached"
  fi
}

# --- Step 11: Issuing CA ------------------------------------------------------
# Core fetches an issuing CA from the CA Issuers URI of its certificates.
# A CA whose certificates lack that URI comes from --issuer-ca.
setup_issuer_ca() {
  [[ -z "$ISSUER_CA_FILE" ]] && return 0
  local der_b64 fingerprint _resp
  der_b64=$(certificate_der_base64 "$ISSUER_CA_FILE")
  fingerprint=$(certificate_fingerprint "$der_b64")
  ISSUER_CA_UUID=$(certificate_uuid_by_fingerprint "$fingerprint")
  if [[ -n "$ISSUER_CA_UUID" ]]; then
    ok "Core holds the issuing CA from ${ISSUER_CA_FILE}  $ISSUER_CA_UUID"
  else
    log "Uploading the issuing CA from ${ISSUER_CA_FILE}..."
    _resp=$(ilm_curl POST /v1/certificates/upload -d \
      "$(jq -nc --arg certificate "$der_b64" '{certificate: $certificate, customAttributes: []}')")
    ISSUER_CA_UUID=$(require_uuid "$_resp" "issuing CA from ${ISSUER_CA_FILE}")
    ok "issuing CA  $ISSUER_CA_UUID"
  fi
  mark_certificate_as_trusted "$ISSUER_CA_UUID"
}

# certificate_der_base64 <file> -> the certificate in <file>, PEM or DER, as base64 DER.
certificate_der_base64() {
  local file="$1" form
  for form in PEM DER; do
    if openssl x509 -in "$file" -inform "$form" -noout 2>/dev/null; then
      openssl x509 -in "$file" -inform "$form" -outform DER | base64 | tr -d '\n'
      return 0
    fi
  done
  die "--issuer-ca ${file} holds no PEM or DER certificate"
}

# certificate_fingerprint <der_base64> -> Core's FINGERPRINT for a certificate: the lowercase hex SHA-256 of its DER.
certificate_fingerprint() {
  printf '%s' "$1" | openssl base64 -d -A | openssl dgst -sha256 -r | cut -d' ' -f1
}

# certificate_uuid_by_fingerprint <sha256_hex> -> the uuid of the certificate Core holds under it, or empty.
certificate_uuid_by_fingerprint() {
  ilm_curl POST /v1/certificates -d "$(jq -nc --arg fingerprint "$1" \
      '{itemsPerPage: 1, pageNumber: 1, includeArchived: true,
        filters: [{fieldSource: "property", fieldIdentifier: "FINGERPRINT", condition: "EQUALS", value: $fingerprint}]}')" \
    | jq -r 'first(.certificates[]?.uuid) // empty'
}

# --- Step 12: Key pair --------------------------------------------------------
# An existing key is matched by name alone. A rerun that changes the key algorithm, the key spec or --crypto-provider
# would otherwise reuse the old material and report the requested key over it.
# Usage: require_key_spec <key_details_json> <key_name> <key_uuid>
require_key_spec() {
  local key_details="$1" key_name="$2" key_uuid="$3" actual requested mismatch held_names unheld
  local hint="choose fresh object names (${SET_NAME_FLAGS}) and re-run"
  [[ "$(echo "$key_details" | jq -r '.tokenInstanceUuid // empty')" != "$TOKEN_UUID" ]] \
    && die "Existing key '${key_name}' (${key_uuid}) lives on token '$(echo "$key_details" | jq -r '.tokenInstanceName // "unknown"')', not on '${TOKEN_NAME}'; ${hint}"
  actual=$(echo "$key_details" | jq -r 'first(.items[]?.keyAlgorithm) // empty')
  [[ "$actual" != "$KEY_ALGORITHM" ]] \
    && die "Existing key '${key_name}' (${key_uuid}) is ${actual:-of an unknown algorithm}, but --key-algorithm asks for ${KEY_ALGORITHM}; ${hint}"

  # Core stores the key-spec attributes a key was created with.
  [[ "$(echo "$key_details" | jq '(.attributes // []) | length')" == 0 ]] \
    && die "Existing key '${key_name}' (${key_uuid}) holds no creation attributes to check its key spec against; ${hint}"
  requested=$(requested_key_spec)
  mismatch=$(echo "$key_details" | jq -r --argjson req "$requested" '
    [(.attributes // [])[] | select($req[.name] != null)
     | {name, held: (.content // [] | map(.data | tostring) | join("|"))}
     | select(.held != $req[.name])
     | "\(.name)=\(.held), but the run asks for \(.name)=\($req[.name])"] | join("; ")')
  [[ -n "$mismatch" ]] && die "Existing key '${key_name}' (${key_uuid}) holds ${mismatch}; ${hint}"
  held_names=$(echo "$key_details" | jq -c '[(.attributes // [])[].name]')
  unheld=$(key_spec_names_outside "$held_names" "$requested")
  [[ -n "$unheld" ]] && die "Existing key '${key_name}' (${key_uuid}) holds no ${unheld}, which the run asks for; ${hint}"

  if [[ "$KEY_ALGORITHM" == "ML-DSA" && "$CRYPTO_PROVIDER" == "software-v1" ]]; then
    require_recorded_prehash "$key_details" "$key_name" "$key_uuid" "$requested" "$hint"
  fi
  return 0
}

# Usage: require_recorded_prehash <key_details_json> <key_name> <key_uuid> <requested_json> <hint>
require_recorded_prehash() {
  local key_details="$1" key_name="$2" key_uuid="$3" requested="$4" hint="$5" prehash want_prehash
  want_prehash=$(echo "$requested" | jq -r --arg n "$MLDSA_PREHASH_ATTR" '.[$n]')
  prehash=$(echo "$key_details" | jq -r 'first(.items[]? | select(.type == "Private") | .keyData | fromjson? | objects | .prehash | select(. != null) | tostring) // empty')
  [[ "$prehash" == "$want_prehash" ]] && return 0
  die "Existing key '${key_name}' (${key_uuid}) records prehash=${prehash:-nothing}, but the run asks for ${MLDSA_PREHASH_ATTR}=${want_prehash}; ${hint}"
}

# Usage: signing_operation_attributes <attrs_json>
signing_operation_attributes() {
  local attrs="$1" scheme_attrs digest_attrs
  scheme_attrs=$(signature_field "$attrs" data_rsaSigScheme --signature-scheme "$SIGNATURE_SCHEME" "$DEFAULT_SIGNATURE_SCHEME") || exit 1
  digest_attrs=$(signature_field "$attrs" data_sigDigest    --signature-digest "$SIGNATURE_DIGEST" "$DEFAULT_SIGNATURE_DIGEST") || exit 1
  jq -nc --argjson scheme_attrs "$scheme_attrs" --argjson digest_attrs "$digest_attrs" '$scheme_attrs + $digest_attrs'
}

# signature_field <attrs_json> <field_name> <option_name> <option_value> <default>
# The result is [the field set to <option_value>, else <default>], or [] where the key lacks the field.
signature_field() {
  local attrs="$1" field_name="$2" option_name="$3" option_value="$4" default="$5" field
  if ! offers_attribute "$attrs" "$field_name"; then
    [[ -n "$option_value" ]] && die \
      "${option_name} sets ${field_name}, which the ${KEY_ALGORITHM} key's signature lacks. Offered: $(echo "$attrs" | jq -c '[.[].name]')"
    echo '[]'
    return 0
  fi
  field=$(chosen_attribute "$attrs" "$field_name" "${option_value:-$default}") || exit 1
  jq -nc --argjson field "$field" '[$field]'
}

# The key spec is a group the connector resolves once the algorithm is chosen.
# Usage: key_spec_definitions <keypair_attr_defs> <key_alg_attr_json>
key_spec_definitions() {
  local keypair_attr_defs="$1" key_alg_attr="$2" key_spec_group_uuid
  key_spec_group_uuid=$(group_uuid "$keypair_attr_defs" "$KEY_SPEC_GROUP") || exit 1
  if [[ "$CRYPTO_PROVIDER" == "software-v1" ]]; then
    ilm_curl POST "/v1/keys/${TOKEN_PROFILE_UUID}/callback" -d \
      "$(jq -n --arg uuid "$key_spec_group_uuid" --arg name "$KEY_SPEC_GROUP" --arg algorithm "$KEY_ALGORITHM" \
        '{"uuid":$uuid,"name":$name,"pathVariable":{"algorithm":$algorithm},
          "requestParameter":{},"body":{},"filter":{}}')"
  else
    ilm_curl POST "/v1/keys/${TOKEN_PROFILE_UUID}/callback" -d \
      "$(jq -n --arg uuid "$key_spec_group_uuid" --arg name "$KEY_SPEC_GROUP" --argjson algorithm "$key_alg_attr" \
        '{uuid: $uuid, name: $name, attributes: [$algorithm]}')"
  fi
}

requested_key_spec() {
  local defaults='{}'
  case "$KEY_ALGORITHM" in
    RSA)
      defaults=$(jq -nc --arg size_attr "$RSA_KEY_SIZE_ATTR" --arg size "$DEFAULT_RSA_KEY_SIZE" '{($size_attr): $size}') ;;
    ML-DSA)
      defaults=$(jq -nc --arg level_attr "$MLDSA_LEVEL_ATTR" --arg level "$DEFAULT_MLDSA_LEVEL" \
        --arg prehash_attr "$MLDSA_PREHASH_ATTR" --arg prehash "$DEFAULT_MLDSA_PREHASH" \
        '{($level_attr): $level} + (if $prehash_attr == "" then {} else {($prehash_attr): $prehash} end)') ;;
  esac
  jq -nc --argjson defaults "$defaults" --argjson pairs "$KEY_SPEC_PAIRS" '$defaults + $pairs'
}

key_spec_pairs() {
  jq -cn --arg spec "$KEY_SPEC" '
    [$spec | split(",")[] | select(test("\\S"))
     | (capture("^\\s*(?<name>[^=\\s][^=]*?)\\s*=\\s*(?<value>\\S.*?)\\s*$") // error("not NAME=VALUE: \(.)"))]
    | map({(.name): .value}) | add // {}'
}

key_spec_names_outside() {
  jq -rn --argjson names "$1" --argjson pairs "$2" \
    '[$pairs | keys[] | select(. as $n | $names | index($n) | not)] | join(", ")'
}

require_offered_key_spec_names() {
  local names unknown
  names=$(echo "$1" | jq -c '[.[] | select(.type == "data") | .name]') || exit 1
  unknown=$(key_spec_names_outside "$names" "$KEY_SPEC_PAIRS") || exit 1
  [[ -z "$unknown" ]] && return 0
  die "--key-spec names ${unknown}, which the ${KEY_ALGORITHM} key spec lacks. Offered: ${names}"
}

# Usage: key_spec_attributes <key_spec_defs> <requested_json>
key_spec_attributes() {
  local defs="$1" requested="$2" fields missing plan name value offered attr attrs='[]'
  local has_default_def='def has_default: .properties.list != true and ((.content // []) | length > 0);'
  require_offered_key_spec_names "$defs"
  fields=$(echo "$defs" | jq -c '[.[] | select(.type == "data")]') || exit 1
  missing=$(jq -rn --argjson fields "$fields" --argjson req "$requested" "${has_default_def}"'
    first($fields[] | select(.properties.required == true and (.name as $n | $req | has($n) | not) and (has_default | not))
          | "\(.name)\t\([.content[]?.data] | tojson)") // empty') || exit 1
  if [[ -n "$missing" ]]; then
    IFS=$'\t' read -r name offered <<<"$missing"
    die "${KEY_ALGORITHM} key-spec field '${name}' needs a value; pass --key-spec ${name}=VALUE. Offered: ${offered}"
  fi
  plan=$(jq -rn --argjson fields "$fields" --argjson req "$requested" "${has_default_def}"'
    $fields[] | .name as $n
    | if $req | has($n) then [$n, $req[$n]]
      elif .properties.required == true and has_default then [$n, (.content[0].data | tostring)]
      else empty end
    | @tsv') || exit 1
  [[ -z "$plan" ]] && { echo '[]'; return 0; }
  while IFS=$'\t' read -r name value; do
    attr=$(key_spec_attribute "$defs" "$name" "$value") || exit 1
    attrs=$(jq -nc --argjson attrs "$attrs" --argjson attr "$attr" '$attrs + [$attr]')
  done <<<"$plan"
  echo "$attrs"
}

# Usage: key_spec_attribute <key_spec_defs> <name> <value>
key_spec_attribute() {
  local defs="$1" name="$2" value="$3" field content
  field=$(echo "$defs" | jq -c --arg n "$name" 'first(.[] | select(.name == $n))') || exit 1
  if field_takes_offered_item "$field" "$value"; then
    chosen_attribute "$defs" "$name" "$value"
    return
  fi
  content=$(echo "$field" | jq -c --arg v "$value" '[{data: (
      if .contentType == "boolean" then (if $v == "true" then true elif $v == "false" then false else error end)
      elif .contentType == "integer" or .contentType == "float" then ($v | tonumber)
      else $v end)}]' 2>/dev/null) \
    || die "Key-spec field '${name}' takes a $(echo "$field" | jq -r '.contentType') value; got '${value}'"
  request_attribute "$defs" "$name" "$content"
}

# field_takes_offered_item <field_json> <value>
field_takes_offered_item() {
  [[ "$(echo "$1" | jq --arg v "$2" '(.properties.list == true) or any(.content[]?; (.data | tostring) == $v)')" == "true" ]]
}

key_spec_summary() {
  echo "$1" | jq -r 'map("\(.name)=\(.content | map(.data | tostring) | join("|"))") | join(", ")'
}

# Usage: setup_key_pair <key_name> <out_key_uuid_var> <out_priv_item_uuid_var>
setup_key_pair() {
  local key_name="$1" out_key_uuid="$2" out_priv_item_uuid="$3"
  local _resp keypair_attr_defs key_alias_attr key_alg_attr
  local key_spec_defs key_details _key_uuid _priv_uuid _existing _list
  local requested key_spec_json

  _list=$(ilm_curl GET /v1/keys/pairs)
  _existing=$(find_named_item "$_list" "$key_name")
  if [[ -n "$_existing" ]]; then
    _key_uuid=$(echo "$_existing" | jq -r '.uuid')
    ok "reusing existing key '${key_name}'  $_key_uuid"
    key_details=$(ilm_curl GET "/v1/keys/${_key_uuid}")
    require_key_spec "$key_details" "$key_name" "$_key_uuid"
    _priv_uuid=$(echo "$key_details" | jq -r \
      'first(.items[] | select(.type == "Private") | .uuid) // empty')
    [[ -z "$_priv_uuid" ]] && die "Reused key ${_key_uuid} has no Private key item"
    ok "private key item  $_priv_uuid"
    printf -v "$out_key_uuid"       '%s' "$_key_uuid"
    printf -v "$out_priv_item_uuid" '%s' "$_priv_uuid"
    return 0
  fi

  log "Fetching key pair attribute definitions..."
  keypair_attr_defs=$(ilm_curl GET \
    "/v1/tokens/${TOKEN_UUID}/tokenProfiles/${TOKEN_PROFILE_UUID}/keys/keyPair/attributes")
  key_alg_attr=$(chosen_attribute "$keypair_attr_defs" "$KEY_ALGORITHM_ATTR" "$KEY_ALGORITHM")
  key_alias_attr=$(request_attribute "$keypair_attr_defs" "$KEY_ALIAS_ATTR" \
    "$(jq -nc --arg name "$key_name" '[{data: $name}]')")

  log "Fetching ${KEY_ALGORITHM} key-spec attributes via callback..."
  key_spec_defs=$(key_spec_definitions "$keypair_attr_defs" "$key_alg_attr")
  requested=$(requested_key_spec)
  key_spec_json=$(key_spec_attributes "$key_spec_defs" "$requested")
  log "Creating ${KEY_ALGORITHM} key pair '${key_name}' ($(key_spec_summary "$key_spec_json"))..."

  _resp=$(ilm_curl POST \
    "/v1/tokens/${TOKEN_UUID}/tokenProfiles/${TOKEN_PROFILE_UUID}/keys/keyPair" -d \
    "$(jq -n \
      --arg name            "$key_name" \
      --argjson keyAlias    "$key_alias_attr" \
      --argjson keyAlg      "$key_alg_attr" \
      --argjson keySpec     "$key_spec_json" \
      '{
        groupUuids: [],
        name: $name,
        description: "",
        attributes: ([$keyAlias, $keyAlg] + $keySpec),
        customAttributes: []
      }')")
  _key_uuid=$(require_uuid "$_resp" "${KEY_ALGORITHM} key pair '${key_name}'")
  ok "key  $_key_uuid"

  log "Enabling key..."
  ilm_curl PATCH "/v1/keys/${_key_uuid}/enable" >/dev/null
  ok "key enabled"

  log "Fetching key details for private key item UUID..."
  key_details=$(ilm_curl GET "/v1/keys/${_key_uuid}")
  _priv_uuid=$(echo "$key_details" | jq -r \
    'first(.items[] | select(.type == "Private") | .uuid) // empty')
  if [[ -z "$_priv_uuid" ]]; then
    echo "ERROR: Could not find Private key item in key ${_key_uuid}. Available items:" >&2
    echo "$key_details" | jq -r '.items[] | "  type=\(.type)  uuid=\(.uuid)"' >&2
    exit 1
  fi
  ok "private key item  $_priv_uuid"

  printf -v "$out_key_uuid"       '%s' "$_key_uuid"
  printf -v "$out_priv_item_uuid" '%s' "$_priv_uuid"
}

# --- Step 13: RA profile (with dynamic EJBCA profile lookup) ------------------
# Usage: setup_ra_profile <ra_name> <cert_profile_name> <out_ra_profile_uuid_var>
setup_ra_profile() {
  local ra_name="$1" ejbca_cert_profile="$2" out_ra_uuid="$3"
  local _resp ra_attrs ee_profile_attr_uuid cert_profile_attr_uuid ca_attr_uuid
  local send_notif_attr_uuid key_recover_attr_uuid username_gen_attr_uuid
  local ejbca_authority_id ee_profile_id cert_profiles cert_profile_id ca_list ejbca_ca_id
  local _ra_uuid _existing _list

  _list=$(ilm_curl GET /v1/raProfiles)
  _existing=$(find_named_item "$_list" "$ra_name")
  if [[ -n "$_existing" ]]; then
    _ra_uuid=$(echo "$_existing" | jq -r '.uuid')
    if [[ "$(echo "$_existing" | jq -r '.enabled // false')" != "true" ]]; then
      ilm_curl PATCH "/v1/authorities/${AUTH_UUID}/raProfiles/${_ra_uuid}/enable" >/dev/null
    fi
    ok "reusing existing RA profile '${ra_name}'  $_ra_uuid"
    printf -v "$out_ra_uuid" '%s' "$_ra_uuid"
    return 0
  fi

  log "Fetching available RA profile attributes from authority..."
  ra_attrs=$(ilm_curl GET "/v1/authorities/${AUTH_UUID}/attributes/raProfile")

  # Extract attribute definition UUIDs from the schema
  ee_profile_attr_uuid=$(attr_uuid   "$ra_attrs" "endEntityProfile"       "object")
  cert_profile_attr_uuid=$(attr_uuid "$ra_attrs" "certificateProfile"     "object")
  ca_attr_uuid=$(attr_uuid           "$ra_attrs" "certificationAuthority" "object")
  send_notif_attr_uuid=$(attr_uuid   "$ra_attrs" "sendNotifications"      "boolean")
  key_recover_attr_uuid=$(attr_uuid  "$ra_attrs" "keyRecoverable"         "boolean")
  username_gen_attr_uuid=$(attr_uuid "$ra_attrs" "usernameGenMethod"      "string")

  # The EJBCA internal authority instance UUID is embedded as a static callback mapping value
  ejbca_authority_id=$(echo "$ra_attrs" | jq -r '
    .[] | select(.name=="certificationAuthority") |
    .attributeCallback.mappings[] |
    select(.to=="authorityId" and has("value")) | .value')

  # Resolve end entity profile ID by name
  ee_profile_id=$(echo "$ra_attrs" | jq -r \
    --arg name "$EJBCA_EE_PROFILE" \
    '.[] | select(.name=="endEntityProfile") | .content[] | select(.data.name==$name) | .data.id')
  [[ -z "$ee_profile_id" ]] && {
    echo "ERROR: End entity profile '$EJBCA_EE_PROFILE' not found. Available:" >&2
    echo "$ra_attrs" | jq -r '.[] | select(.name=="endEntityProfile") | .content[].data.name' >&2
    exit 1
  }
  ok "end-entity profile '$EJBCA_EE_PROFILE'  id=$ee_profile_id"

  log "Resolving certificate profile '${ejbca_cert_profile}'..."
  cert_profiles=$(ilm_curl POST "/v1/raProfiles/${AUTH_UUID}/callback" -d \
    "$(jq -n \
      --arg uuid   "$cert_profile_attr_uuid" \
      --arg authId "$ejbca_authority_id" \
      --argjson eeId "$ee_profile_id" \
      '{"uuid":$uuid,"name":"certificateProfile","pathVariable":{"endEntityProfileId":$eeId,"authorityId":$authId},"requestParameter":{},"body":{},"filter":{}}')")
  cert_profile_id=$(echo "$cert_profiles" | jq -r \
    --arg name "$ejbca_cert_profile" '.[] | select(.data.name==$name) | .data.id')
  [[ -z "$cert_profile_id" ]] && {
    echo "ERROR: Certificate profile '$ejbca_cert_profile' not found. Available:" >&2
    echo "$cert_profiles" | jq -r '.[].data.name' >&2
    exit 1
  }
  ok "certificate profile '$ejbca_cert_profile'  id=$cert_profile_id"

  log "Resolving CA '${EJBCA_CA_NAME}'..."
  ca_list=$(ilm_curl POST "/v1/raProfiles/${AUTH_UUID}/callback" -d \
    "$(jq -n \
      --arg uuid   "$ca_attr_uuid" \
      --arg authId "$ejbca_authority_id" \
      --argjson eeId "$ee_profile_id" \
      '{"uuid":$uuid,"name":"certificationAuthority","pathVariable":{"authorityId":$authId,"endEntityProfileId":$eeId},"requestParameter":{},"body":{},"filter":{}}')")
  ejbca_ca_id=$(echo "$ca_list" | jq -r \
    --arg name "$EJBCA_CA_NAME" '.[] | select(.data.name==$name) | .data.id')
  [[ -z "$ejbca_ca_id" ]] && {
    echo "ERROR: CA '$EJBCA_CA_NAME' not found. Available:" >&2
    echo "$ca_list" | jq -r '.[].data.name' >&2
    exit 1
  }
  ok "CA '$EJBCA_CA_NAME'  id=$ejbca_ca_id"

  log "Creating RA profile '${ra_name}'..."
  _resp=$(ilm_curl POST "/v1/authorities/${AUTH_UUID}/raProfiles" -d \
    "$(jq -n \
      --arg     name              "$ra_name" \
      --arg     eeProfileName     "$EJBCA_EE_PROFILE" \
      --argjson eeId              "$ee_profile_id" \
      --arg     eeAttrUuid        "$ee_profile_attr_uuid" \
      --arg     cpName            "$ejbca_cert_profile" \
      --argjson cpId              "$cert_profile_id" \
      --arg     cpAttrUuid        "$cert_profile_attr_uuid" \
      --arg     caName            "$EJBCA_CA_NAME" \
      --argjson caId              "$ejbca_ca_id" \
      --arg     caAttrUuid        "$ca_attr_uuid" \
      --arg     snAttrUuid        "$send_notif_attr_uuid" \
      --arg     krAttrUuid        "$key_recover_attr_uuid" \
      --arg     ugAttrUuid        "$username_gen_attr_uuid" \
      --arg     usernameGenMethod "$EJBCA_USERNAME_GEN_METHOD" \
      '{
        name: $name,
        description: "",
        attributes: [
          {
            name: "endEntityProfile",
            content: [{data: {id: $eeId, name: $eeProfileName}, reference: $eeProfileName}],
            contentType: "object",
            uuid: $eeAttrUuid,
            version: "v2"
          },
          {
            name: "certificateProfile",
            content: [{data: {id: $cpId, name: $cpName}, reference: $cpName}],
            contentType: "object",
            uuid: $cpAttrUuid,
            version: "v2"
          },
          {
            name: "certificationAuthority",
            content: [{data: {id: $caId, name: $caName}, reference: $caName}],
            contentType: "object",
            uuid: $caAttrUuid,
            version: "v2"
          },
          {
            name: "sendNotifications",
            content: [{data: false}],
            contentType: "boolean",
            uuid: $snAttrUuid,
            version: "v2"
          },
          {
            name: "keyRecoverable",
            content: [{data: false}],
            contentType: "boolean",
            uuid: $krAttrUuid,
            version: "v2"
          },
          {
            name: "usernameGenMethod",
            content: [{data: $usernameGenMethod}],
            contentType: "string",
            uuid: $ugAttrUuid,
            version: "v2"
          }
        ],
        customAttributes: []
      }')")
  _ra_uuid=$(require_uuid "$_resp" "RA profile '${ra_name}'")
  ok "RA profile  $_ra_uuid"

  log "Enabling RA profile..."
  ilm_curl PATCH "/v1/authorities/${AUTH_UUID}/raProfiles/${_ra_uuid}/enable" >/dev/null
  ok "RA profile enabled"

  printf -v "$out_ra_uuid" '%s' "$_ra_uuid"
}

# --- Step 14: Issue TSA certificate -------------------------------------------
# Usage: issue_certificate <cn> <key_uuid> <priv_item_uuid> <ra_profile_uuid> <out_cert_uuid_var>
issue_certificate() {
  local cn="$1" key_uuid="$2" priv_item_uuid="$3" ra_profile_uuid="$4" out_cert_uuid="$5"
  local _resp csr_attrs cn_uuid sig_attrs signature_attrs _cert_uuid

  log "Fetching CSR attribute definitions..."
  csr_attrs=$(ilm_curl GET "/v1/certificates/csr/attributes")
  cn_uuid=$(attr_uuid "$csr_attrs" "commonName" "string")

  log "Fetching signature attribute definitions..."
  sig_attrs=$(ilm_curl GET \
    "/v1/operations/tokens/${TOKEN_UUID}/tokenProfiles/${TOKEN_PROFILE_UUID}/keys/${key_uuid}/items/${priv_item_uuid}/sign/attributes")
  signature_attrs=$(signing_operation_attributes "$sig_attrs")

  log "Issuing TSA certificate  CN=${cn}..."
  _resp=$(ilm_curl POST \
    "/v2/operations/authorities/${AUTH_UUID}/raProfiles/${ra_profile_uuid}/certificates" -d \
    "$(jq -n \
      --arg cn               "$cn" \
      --arg keyUuid          "$key_uuid" \
      --arg tokenProfileUuid "$TOKEN_PROFILE_UUID" \
      --arg cnUuid           "$cn_uuid" \
      --argjson signatureAttributes "$signature_attrs" \
      '{
        format: "pkcs10",
        request: "",
        attributes: [],
        csrAttributes: [
          {
            name: "commonName",
            content: [{data: $cn, contentType: "string"}],
            contentType: "string",
            uuid: $cnUuid,
            version: "v3"
          }
        ],
        signatureAttributes: $signatureAttributes,
        keyUuid: $keyUuid,
        tokenProfileUuid: $tokenProfileUuid,
        customAttributes: []
      }')")
  _cert_uuid=$(require_uuid "$_resp" "TSA certificate CN=${cn}")
  ok "issued certificate  $_cert_uuid"

  printf -v "$out_cert_uuid" '%s' "$_cert_uuid"
}

# --- Step 15: Poll for certificate issuance result ----------------------------
# Usage: poll_certificate <cert_uuid> <cn>
poll_certificate() {
  local cert_uuid="$1" cn="$2"
  local cert_state="" cert_details attempt history err_msg err_text

  log "Waiting for certificate issuance to complete (CN=${cn})..."
  for (( attempt=1; attempt<=CERT_POLL_ATTEMPTS; attempt++ )); do
    cert_details=$(ilm_curl GET "/v1/certificates/${cert_uuid}")
    cert_state=$(echo "$cert_details" | jq -r '.state // empty')
    case "$cert_state" in
      issued)
        ok "certificate state: issued"
        break
        ;;
      failed)
        history=$(ilm_curl GET "/v1/certificates/${cert_uuid}/history")
        err_msg=$(echo "$history" | jq -r '
          first(
            .[] | select(.event=="Issue Certificate" and .status=="FAILED") | .message
          ) // empty')
        # message is a JSON-encoded string: {"message":"<text>"}
        if [[ -n "$err_msg" ]]; then
          err_text=$(echo "$err_msg" | jq -r '. | fromjson | .message' 2>/dev/null \
            || echo "$err_msg")
        else
          err_text="(no error message available in certificate history)"
        fi
        die "Certificate issuance failed: ${err_text}"
        ;;
      *)
        log "  attempt ${attempt}/${CERT_POLL_ATTEMPTS}: state='${cert_state}' -- waiting ${CERT_POLL_INTERVAL}s..."
        sleep "$CERT_POLL_INTERVAL"
        ;;
    esac
  done
  if [[ "$cert_state" != "issued" ]]; then
    die "Certificate issuance timed out after $(( CERT_POLL_ATTEMPTS * CERT_POLL_INTERVAL ))s (last state: '${cert_state}')"
  fi
}


# --- Step 16: Trust the certificate chain -------------------------------------
# Usage: trust_certificate_chain <cert_uuid>
#
# A signing profile needs this step. ILM rejects a certificate whose chain is untrusted or awaits re-validation.
trust_certificate_chain() {
  local cert_uuid="$1"
  log "Trusting certificate chain for ${cert_uuid}..."

  if [[ -n "$ISSUER_CA_UUID" ]]; then
    refresh_issuer_linkage "$cert_uuid"
  fi

  local root_uuid
  root_uuid=$(find_root_certificate "$cert_uuid")
  [[ -z "$root_uuid" ]] && return 0

  mark_certificate_as_trusted "$root_uuid"
  wait_for_certificate_validation "$cert_uuid"
  ok "Certificate chain trusted and validated"
}

# refresh_issuer_linkage <cert_uuid>
refresh_issuer_linkage() {
  ilm_curl GET "/v1/certificates/${1}/chain" >/dev/null
}

# find_root_certificate <cert_uuid>
find_root_certificate() {
  local cert_uuid="$1"
  local current_uuid

  current_uuid=$(wait_for_issuer_linkage "$cert_uuid") || exit 1
  [[ -z "$current_uuid" ]] && return 0

  while [[ -n "$current_uuid" ]]; do
    local cert_details next_uuid
    cert_details=$(ilm_curl GET "/v1/certificates/${current_uuid}") || exit 1
    next_uuid=$(echo "$cert_details" | jq -r '.issuerCertificateUuid // empty')

    if [[ -z "$next_uuid" ]]; then
      echo "$current_uuid"
      return 0
    fi

    log "  Skipping intermediate ${current_uuid}..."
    current_uuid="$next_uuid"
  done
}

# wait_for_issuer_linkage <cert_uuid>
# Polls until issuerCertificateUuid is available; returns issuer UUID or empty for self-signed.
wait_for_issuer_linkage() {
  local cert_uuid="$1"
  local cert_details current_uuid attempt

  for (( attempt=1; attempt<=10; attempt++ )); do
    cert_details=$(ilm_curl GET "/v1/certificates/${cert_uuid}") || exit 1
    current_uuid=$(echo "$cert_details" | jq -r '.issuerCertificateUuid // empty')

    [[ -n "$current_uuid" ]] && { echo "$current_uuid"; return 0; }

    if is_self_signed "$cert_details"; then
      ok "Certificate is self-signed (subjectDn == issuerDn), no chain to trust"
      return 0
    fi

    if [[ $attempt -lt 10 ]]; then
      log "  Issuer linkage not yet available, waiting... (${attempt}/10)"
      sleep 0.5
    else
      die_unlinked_issuer "$cert_uuid" "$cert_details" "$attempt"
    fi
  done
}

# die_unlinked_issuer <cert_uuid> <cert_details_json> <attempts>
die_unlinked_issuer() {
  local cert_uuid="$1" attempts="$3" issuer ca_details ca_subject
  issuer=$(echo "$2" | jq -r '.issuerDn // empty')
  [[ -z "$ISSUER_CA_UUID" ]] && die \
    "Core holds no issuer certificate for ${cert_uuid} (issuerDn='${issuer}') after ${attempts} attempts; pass the issuing CA with --issuer-ca FILE"
  ca_details=$(ilm_curl GET "/v1/certificates/${ISSUER_CA_UUID}") || exit 1
  ca_subject=$(echo "$ca_details" | jq -r '.subjectDn // empty')
  [[ "$ca_subject" != "$issuer" ]] && die \
    "Core holds no issuer certificate for ${cert_uuid} (issuerDn='${issuer}') after ${attempts} attempts; --issuer-ca ${ISSUER_CA_FILE} holds '${ca_subject}'"
  die "Core has not linked ${cert_uuid} to its issuing CA '${ca_subject}' from --issuer-ca after ${attempts} attempts; re-run to resume the set"
}

# is_self_signed <cert_details_json>
is_self_signed() {
  local cert_details="$1"
  local subject issuer
  subject=$(echo "$cert_details" | jq -r '.subjectDn // empty')
  issuer=$(echo "$cert_details" | jq -r '.issuerDn // empty')
  [[ "$subject" == "$issuer" ]]
}

# mark_certificate_as_trusted <root_uuid>
mark_certificate_as_trusted() {
  local root_uuid="$1"
  log "  Found root certificate ${root_uuid}, marking as trusted..."
  ilm_curl PATCH "/v1/certificates/${root_uuid}" -d '{"trustedCa": true}' >/dev/null
  ok "  Root certificate ${root_uuid} marked trusted"
}

# wait_for_certificate_validation <cert_uuid>
wait_for_certificate_validation() {
  local cert_uuid="$1"
  local validation_result validation_status attempt

  log "  Waiting for certificate ${cert_uuid} to be re-validated..."
  for (( attempt=1; attempt<=20; attempt++ )); do
    validation_result=$(ilm_curl GET "/v1/certificates/${cert_uuid}/validate")
    validation_status=$(echo "$validation_result" | jq -r '.resultStatus // empty')

    if [[ "$validation_status" == "valid" || "$validation_status" == "expiring" ]]; then
      ok "  Certificate validation status: ${validation_status}"
      return 0
    fi

    if [[ $attempt -lt 20 ]]; then
      sleep 0.5
    else
      die "Certificate ${cert_uuid} validation status is '${validation_status}' after ${attempt} attempts (expected 'valid' or 'expiring'). Validation result: ${validation_result}"
    fi
  done
}

# --- Step 17: TSP profile -----------------------------------------------------
# Usage: setup_tsp_profile <name> <out_tsp_uuid_var>
setup_tsp_profile() {
  local tsp_name="$1" out_tsp_uuid="$2"
  local _resp _tsp_uuid _existing _list

  _list=$(list_paginated /v1/tspProfiles/list)
  _existing=$(find_named_item "$_list" "$tsp_name")
  if [[ -n "$_existing" ]]; then
    _tsp_uuid=$(echo "$_existing" | jq -r '.uuid')
    if [[ "$(echo "$_existing" | jq -r '.enabled // false')" != "true" ]]; then
      ilm_curl PATCH "/v1/tspProfiles/${_tsp_uuid}/enable" >/dev/null
    fi
    ok "reusing existing TSP profile '${tsp_name}'  $_tsp_uuid"
    printf -v "$out_tsp_uuid" '%s' "$_tsp_uuid"
    return 0
  fi

  log "Creating TSP profile '${tsp_name}'..."
  _resp=$(ilm_curl POST /v1/tspProfiles -d \
    "$(jq -n --arg name "$tsp_name" --arg vaultProfileUuid "$VAULT_PROFILE_UUID" \
      '{name: $name,
        vaultProfileUuid: $vaultProfileUuid,
        allowedAuthenticationMethods: ["clientCertificate", "basicPassword"],
        customAttributes: []}')")
  _tsp_uuid=$(require_uuid "$_resp" "TSP profile '${tsp_name}'")
  ok "TSP profile  $_tsp_uuid"

  log "Enabling TSP profile..."
  ilm_curl PATCH "/v1/tspProfiles/${_tsp_uuid}/enable" >/dev/null
  ok "TSP profile enabled"

  printf -v "$out_tsp_uuid" '%s' "$_tsp_uuid"
}

# --- Step 18: Signing Profile -------------------------------------------------
# Usage: setup_signing_profile <sp_name> <cert_uuid> <policy_oid> <time_quality_uuid> <timestamp_formatting_conn_uuid> <out_sp_uuid_var>
#
# Pass a non-empty <time_quality_uuid> for the qualified profile to enable
# qualifiedTimestamp and link to the Time Quality configuration.
# Pass an empty string for the non-qualified profile.
setup_signing_profile() {
  local sp_name="$1" cert_uuid="$2" policy_oid="$3" time_quality_uuid="$4" timestamp_formatting_conn_uuid="$5" out_sp_uuid="$6"
  local _resp sig_attrs signing_operation_attrs _sp_uuid formatting_attrs
  local qualified_timestamp allowed_policies allowed_digests

  if [[ -n "$time_quality_uuid" ]]; then
    qualified_timestamp="true"
  else
    qualified_timestamp="false"
  fi

  log "Fetching signing operation attributes for certificate ${cert_uuid}..."
  sig_attrs=$(ilm_curl GET \
    "/v1/signingProfiles/certificates/${cert_uuid}/signatureAttributes")
  signing_operation_attrs=$(signing_operation_attributes "$sig_attrs")

  log "Fetching timestamp-formatting-connector attributes..."
  formatting_attrs=$(ilm_curl GET \
    "/v1/signingProfiles/signatureFormattingConnectors/${timestamp_formatting_conn_uuid}/formattingAttributes" \
    | jq '[.[] | .version = ("v" + (.version | tostring))]')

  # One global --allowed-policy-ids covers both sets. So the set's own OID always joins a list.
  allowed_policies=$(csv_to_json_array "$ALLOWED_POLICY_IDS" "$policy_oid" \
    | jq -c --arg own "$policy_oid" 'if length > 0 and (index($own) | not) then . + [$own] else . end')
  allowed_digests=$(csv_to_json_array "$ALLOWED_DIGEST_ALGORITHMS")

  log "Creating Signing Profile '${sp_name}'..."
  _resp=$(ilm_curl POST /v1/signingProfiles -d \
    "$(jq -n \
      --arg     name                        "$sp_name" \
      --arg     policyOid                   "$policy_oid" \
      --arg     certUuid                    "$cert_uuid" \
      --argjson signingOperationAttrs       "$signing_operation_attrs" \
      --argjson qualifiedTimestamp          "$qualified_timestamp" \
      --arg     timeQualityUuid             "$time_quality_uuid" \
      --arg     timestampFormattingConnUuid "$timestamp_formatting_conn_uuid" \
      --argjson formattingAttrs             "$formatting_attrs" \
      --argjson allowedPolicyIds            "$allowed_policies" \
      --argjson allowedDigestAlgorithms     "$allowed_digests" \
      '{
        name: $name,
        workflow: (
          {
            type: "timestamping",
            signatureFormattingConnectorUuid: $timestampFormattingConnUuid,
            signatureFormattingConnectorAttributes: $formattingAttrs,
            qualifiedTimestamp: $qualifiedTimestamp,
            defaultPolicyId: $policyOid,
            allowedPolicyIds: $allowedPolicyIds,
            allowedDigestAlgorithms: $allowedDigestAlgorithms
          }
          | if $timeQualityUuid != "" then
              . + {timeQualityConfigurationUuid: $timeQualityUuid}
            else . end
        ),
        signingScheme: {
          signingScheme: "managed",
          managedSigningType: "static_key",
          certificateUuid: $certUuid,
          signingOperationAttributes: $signingOperationAttrs
        },
        customAttributes: []
      }')")
  _sp_uuid=$(require_uuid "$_resp" "Signing Profile '${sp_name}'")
  ok "Signing Profile  $_sp_uuid"

  log "Enabling Signing Profile..."
  ilm_curl PATCH "/v1/signingProfiles/${_sp_uuid}/enable" >/dev/null
  ok "Signing Profile enabled"

  printf -v "$out_sp_uuid" '%s' "$_sp_uuid"
}

# --- Step 19: Link Signing Profile ↔ TSP Profile (bidirectional) --------------
# Usage: link_tsp_signing_profile <tsp_uuid> <tsp_name> <sp_uuid>
#
# Direction 1: TSP profile → Signing Profile (sets defaultSigningProfileUuid)
# Direction 2: Signing Profile → TSP profile (activates TSP protocol)
link_tsp_signing_profile() {
  local tsp_uuid="$1" tsp_name="$2" sp_uuid="$3"
  local _resp

  # PUT replaces the resource: re-send vaultProfileUuid and the auth methods or they would be stripped.
  log "Linking TSP profile '${tsp_name}' to Signing Profile (setting default)..."
  ilm_curl PUT "/v1/tspProfiles/${tsp_uuid}" -d \
    "$(jq -n \
      --arg name   "$tsp_name" \
      --arg spUuid "$sp_uuid" \
      --arg vaultProfileUuid "$VAULT_PROFILE_UUID" \
      '{name: $name,
        defaultSigningProfileUuid: $spUuid,
        vaultProfileUuid: $vaultProfileUuid,
        allowedAuthenticationMethods: ["clientCertificate", "basicPassword"],
        customAttributes: []}')" \
    >/dev/null
  ok "TSP profile default Signing Profile set"

  log "Activating TSP protocol on Signing Profile for TSP profile '${tsp_name}'..."
  _resp=$(ilm_curl PATCH "/v1/signingProfiles/${sp_uuid}/protocols/tsp/activate/${tsp_uuid}")
  ok "TSP protocol activated  signingUrl=$(echo "$_resp" | jq -r '.signingUrl // "(unknown)"')"
}

# --- Step 20: TSP Basic credential --------------------------------------------
# Usage: setup_tsp_basic_credential <tsp_uuid> <out_cred_uuid_var>
# Creates a username/password credential on the TSP profile, mapped to MAPPED_USER_UUID.
# Idempotent: usernames are unique per profile, so an existing one is reused.
setup_tsp_basic_credential() {
  local tsp_uuid="$1" out_cred_uuid="$2"
  local _creds _existing _resp _cred_uuid

  _creds=$(ilm_curl GET "/v1/tspProfiles/${tsp_uuid}/basicCredentials")
  _existing=$(echo "$_creds" | jq -c --arg u "$TSP_CREDENTIAL_USERNAME" \
    'first(.[] | select(.username==$u)) // empty')
  if [[ -n "$_existing" ]]; then
    _cred_uuid=$(require_uuid "$_existing" "existing Basic credential '${TSP_CREDENTIAL_USERNAME}' on TSP profile ${tsp_uuid}")
    if [[ -n "$JSON_SUMMARY_FILE" ]]; then
      local _existing_user_uuid
      _existing_user_uuid=$(echo "$_existing" | jq -r '.mappedUser.uuid // empty')
      [[ -n "$_existing_user_uuid" && "$_existing_user_uuid" != "$MAPPED_USER_UUID" ]] && die \
        "Existing Basic credential '${TSP_CREDENTIAL_USERNAME}' on TSP profile ${tsp_uuid} is mapped to user ${_existing_user_uuid}, not to '${MAPPED_USER_USERNAME}' (${MAPPED_USER_UUID}); rotating it would re-point a credential owned by someone else - rename it or pass a different --tsp-credential-username and re-run"
      ilm_curl PUT "/v1/tspProfiles/${tsp_uuid}/basicCredentials/${_cred_uuid}" -d \
        "$(jq -n \
          --arg username      "$TSP_CREDENTIAL_USERNAME" \
          --arg password      "$TSP_CREDENTIAL_PASSWORD" \
          --arg mappedUserUuid "$MAPPED_USER_UUID" \
          '{username: $username, password: $password, mappedUserUuid: $mappedUserUuid}')" >/dev/null
      ok "rotated existing Basic credential '${TSP_CREDENTIAL_USERNAME}' (mapped user $MAPPED_USER_USERNAME) on TSP profile ${tsp_uuid}  $_cred_uuid"
    else
      ok "reusing existing Basic credential '${TSP_CREDENTIAL_USERNAME}' on TSP profile ${tsp_uuid}  $_cred_uuid"
    fi
    printf -v "$out_cred_uuid" '%s' "$_cred_uuid"
    return 0
  fi

  log "Creating Basic credential '${TSP_CREDENTIAL_USERNAME}' on TSP profile ${tsp_uuid}..."
  _resp=$(ilm_curl POST "/v1/tspProfiles/${tsp_uuid}/basicCredentials" -d \
    "$(jq -n \
      --arg username      "$TSP_CREDENTIAL_USERNAME" \
      --arg password      "$TSP_CREDENTIAL_PASSWORD" \
      --arg mappedUserUuid "$MAPPED_USER_UUID" \
      '{username: $username, password: $password, mappedUserUuid: $mappedUserUuid}')")
  _cred_uuid=$(require_uuid "$_resp" "Basic credential '${TSP_CREDENTIAL_USERNAME}' on TSP profile ${tsp_uuid}")
  ok "Basic credential created  $_cred_uuid"
  printf -v "$out_cred_uuid" '%s' "$_cred_uuid"
}

# --- Step 21: Object-scoped timestamping permissions --------------------------
# Applied after both TSA sets exist, so every grant targets concrete object UUIDs rather than the
# whole resource. The OPA method policy (auth-opa-policies/policies/method_policy.rego)
# honors object-scoped grants for BOTH request shapes on the timestamp path:
#   - checks that carry the object UUID (tspProfiles/timestamp via SecuredUUID; tokens/detail via the
#     SecuredParentUUID token instance) are matched by the "ActionAllowedForSpecificObject" rule;
#   - name-based checks that carry NO uuid (tspProfiles/detail and signingProfiles/detail load by
#     String name) are matched by the "ActionAllowedForSomeObjects" rule, which grants when the action
#     is allowed for some object under the resource.
# NOTE on keys/sign: the Auth service rejects object-scoped permissions on the 'keys' resource
# (objectAccess=false in the Auth seed -> "Resource 'Keys' does not support object access permissions"),
# so keys/sign must be granted resource-wide as an action, not against any object uuid.
timestamping_permissions() {
  jq -n \
    --arg tspNqUuid "$TSP_PROFILE_UUID_NQ" --arg tspNqName "${TSP_PROFILE_NAME_BASE}-non-qualified" \
    --arg tspQUuid  "$TSP_PROFILE_UUID_Q"  --arg tspQName  "${TSP_PROFILE_NAME_BASE}-qualified" \
    --arg spNqUuid  "$SIGNING_PROFILE_UUID_NQ" --arg spNqName "${SIGNING_PROFILE_NAME_BASE}-non-qualified" \
    --arg spQUuid   "$SIGNING_PROFILE_UUID_Q"  --arg spQName  "${SIGNING_PROFILE_NAME_BASE}-qualified" \
    --arg tokenUuid "$TOKEN_UUID"          --arg tokenName "$TOKEN_NAME" \
    --arg tpUuid    "$TOKEN_PROFILE_UUID"  --arg tpName    "$TOKEN_PROFILE_NAME" \
    '{
      allowAllResources: false,
      resources: [
        {name:"tspProfiles", allowAllActions:false, actions:[], objects:[
          {uuid:$tspNqUuid, name:$tspNqName, allow:["timestamp","detail"], deny:[]},
          {uuid:$tspQUuid,  name:$tspQName,  allow:["timestamp","detail"], deny:[]}
        ]},
        {name:"signingProfiles", allowAllActions:false, actions:[], objects:[
          {uuid:$spNqUuid, name:$spNqName, allow:["detail"], deny:[]},
          {uuid:$spQUuid,  name:$spQName,  allow:["detail"], deny:[]}
        ]},
        {name:"keys", allowAllActions:false, actions:["sign"], objects:[]},
        {name:"tokens", allowAllActions:false, actions:[], objects:[
          {uuid:$tokenUuid, name:$tokenName, allow:["detail"], deny:[]}
        ]},
        {name:"tokenProfiles", allowAllActions:false, actions:[], objects:[
          {uuid:$tpUuid, name:$tpName, allow:["detail"], deny:[]}
        ]}
      ]
    }'
}

# This script is the sole manager of the role, so it grants object-scoped rights and never denies
# or broadens. Anything else in the role was put there from outside and would be merged forward.
# Usage: require_scoped_grants_only <permissions_json>
require_scoped_grants_only() {
  local offenders
  offenders=$(echo "$1" | jq -r '
    [ (select(.allowAllResources == true) | "allowAllResources"),
      (.resources[]? | select(.allowAllActions == true) | "\(.name)/allowAllActions"),
      (.resources[]? as $r | $r.objects[]? | select((.deny // []) | length > 0)
       | "\($r.name)/\(.name // .uuid) deny")
    ] | join(", ")')
  [[ -z "$offenders" ]] && return 0
  die "Role '${MAPPED_USER_ROLE_NAME}' carries grants this script does not manage (${offenders}); it manages that role exclusively. Clear them (or delete the role) and re-run"
}

# savePermissions replaces the role's whole permission set, so the grants have to be merged.
# Only object-scoped allows are carried forward.
# Usage: merge_permissions <existing_json> <desired_json>
merge_permissions() {
  jq -n --argjson existing "$1" --argjson desired "$2" '
    def merged_list(f): (map(f // []) | add // []) | unique;
    {
      allowAllResources: false,
      resources: (
        (($existing.resources // []) + ($desired.resources // []))
        | group_by(.name)
        | map({
            name: .[0].name,
            allowAllActions: false,
            actions: merged_list(.actions),
            objects: (
              (map(.objects // []) | add // [])
              | group_by(.uuid)
              | map({
                  uuid:  .[0].uuid,
                  name:  .[0].name,
                  allow: merged_list(.allow),
                  deny:  []
                })
            )
          })
      )
    }'
}

grant_timestamping_permissions() {
  local desired existing perm_body

  desired=$(timestamping_permissions)
  existing=$(ilm_curl GET "/v1/roles/${MAPPED_USER_ROLE_UUID}/permissions") \
    || die "Could not read the current permissions of role '${MAPPED_USER_ROLE_NAME}'"
  require_scoped_grants_only "$existing"
  perm_body=$(merge_permissions "$existing" "$desired")

  log "Granting object-scoped timestamping permissions to role '${MAPPED_USER_ROLE_NAME}'..."
  ilm_curl POST "/v1/roles/${MAPPED_USER_ROLE_UUID}/permissions" -d "$perm_body" >/dev/null
  ok "object-scoped permissions granted"
}

# --- Per-set orchestration ----------------------------------------------------
# resumable_key_certificate <key_uuid> -> "<uuid>\t<common name>"
# EJBCA binds a key to one end entity only.
resumable_key_certificate() {
  local key_details cert_uuids cert_uuid cert uuid_and_cn
  key_details=$(ilm_curl GET "/v1/keys/$1") || exit 1
  cert_uuids=$(echo "$key_details" | jq -r '.associations[]? | select(.resource == "certificates") | .uuid')
  for cert_uuid in $cert_uuids; do
    cert=$(ilm_curl GET "/v1/certificates/${cert_uuid}") || exit 1
    uuid_and_cn=$(echo "$cert" | jq -r 'def resumable: .state | IN("requested", "pending_approval", "pending_issue", "issued");
      select(resumable) | "\(.uuid)\t\(.commonName)"')
    [[ -n "$uuid_and_cn" ]] && { echo "$uuid_and_cn"; return 0; }
  done
  return 0
}

# setup_tsa_set <suffix> <ejbca_cert_profile> <policy_oid> <time_quality_uuid> <global_suffix>
#
# Idempotent. If the set's Signing Profile already exists the whole set is treated as already configured and reused
# WITHOUT issuing a new certificate: EJBCA binds a key to a single end-entity - reusing keys is rejected.
# Reuse also keeps the profile's signature settings and allowedPolicyIds/allowedDigestAlgorithms, fixed at creation.
# --signature-* and --allowed-* therefore take effect only on a fresh environment, or on a run with new object names.
setup_tsa_set() {
  local suffix="$1" cert_profile="$2" policy_oid="$3" tq_uuid="$4" g="$5"
  local key_name="${KEY_NAME_BASE}-${suffix}"
  local ra_name="${RA_PROFILE_NAME_BASE}-${suffix}"
  local tsp_name="${TSP_PROFILE_NAME_BASE}-${suffix}"
  local sp_name="${SIGNING_PROFILE_NAME_BASE}-${suffix}"
  local key_uuid="" priv_uuid="" ra_uuid="" cert_uuid="" cert_cn="" tsp_uuid="" cred_uuid="" sp_uuid=""
  local set_policy_oid="" set_tq_uuid=""
  local existing_sp _list sp_details resumable_cert key_details

  log "=== Setting up TSA ${suffix} set ==="

  _list=$(list_paginated /v1/signingProfiles/list)
  existing_sp=$(find_named_item "$_list" "$sp_name")
  if [[ -n "$existing_sp" ]]; then
    sp_uuid=$(echo "$existing_sp" | jq -r '.uuid')
    _list=$(ilm_curl GET /v1/keys/pairs)
    key_uuid=$(uuid_of_named "$_list" "$key_name")
    [[ -z "$key_uuid" ]] && die "Reused Signing Profile '${sp_name}' ($sp_uuid) has no matching key pair '${key_name}'; resolve the inconsistency (recreate or rename the key pair) and re-run"
    key_details=$(ilm_curl GET "/v1/keys/${key_uuid}")
    require_key_spec "$key_details" "$key_name" "$key_uuid"
    if [[ "$(echo "$existing_sp" | jq -r '.enabled // false')" != "true" ]]; then
      ilm_curl PATCH "/v1/signingProfiles/${sp_uuid}/enable" >/dev/null
      ok "re-enabled disabled Signing Profile '${sp_name}'"
    fi
    ok "TSA ${suffix} set already configured (Signing Profile '${sp_name}'  $sp_uuid); reusing, no new certificate issued and its stored signature settings and request-validation allow-lists are kept"
    _list=$(ilm_curl GET /v1/raProfiles)
    ra_uuid=$(uuid_of_named "$_list" "$ra_name")
    [[ -z "$ra_uuid" ]] && die "Reused Signing Profile '${sp_name}' ($sp_uuid) has no matching RA profile '${ra_name}'; resolve the inconsistency (recreate or rename the RA profile) and re-run"
    _list=$(list_paginated /v1/tspProfiles/list)
    tsp_uuid=$(uuid_of_named "$_list" "$tsp_name")
    # A reused set with no matching TSP profile is a half-configured state.
    [[ -z "$tsp_uuid" ]] && die "Reused Signing Profile '${sp_name}' ($sp_uuid) has no matching TSP profile '${tsp_name}'; resolve the inconsistency (recreate or rename the TSP profile) and re-run"
    # The detail DTO nests the cert as signingScheme.certificate (CertificateSimpleDto), not certificateUuid.
    sp_details=$(ilm_curl GET "/v1/signingProfiles/${sp_uuid}")
    cert_uuid=$(echo "$sp_details" | jq -r '.signingScheme.certificate.uuid // empty')
    [[ -z "$cert_uuid" ]] && die "Reused Signing Profile '${sp_name}' ($sp_uuid) has no signing certificate; resolve the inconsistency and re-run"
    cert_cn=$(echo "$sp_details" | jq -r '.signingScheme.certificate.commonName // empty')
    [[ -z "$cert_cn" ]] && warn "Reused Signing Profile '${sp_name}' ($sp_uuid) reports no certificate common name; the summary reports it as unknown"
    # A reused profile keeps what an earlier run stored.
    set_policy_oid=$(echo "$sp_details" | jq -r '.workflow.defaultPolicyId // empty')
    set_tq_uuid=$(echo "$sp_details" | jq -r '.workflow.timeQualityConfiguration.uuid // empty')
    setup_tsp_basic_credential "$tsp_uuid" cred_uuid
  else
    setup_key_pair    "$key_name" key_uuid priv_uuid
    setup_ra_profile  "$ra_name" "$cert_profile" ra_uuid
    resumable_cert=$(resumable_key_certificate "$key_uuid")
    if [[ -n "$resumable_cert" ]]; then
      IFS=$'\t' read -r cert_uuid cert_cn <<<"$resumable_cert"
      ok "reusing certificate CN=${cert_cn} of key '${key_name}'  $cert_uuid"
    else
      cert_cn="${CERTIFICATE_CN_PREFIX}-${suffix}"
      issue_certificate "$cert_cn" "$key_uuid" "$priv_uuid" "$ra_uuid" cert_uuid
    fi
    poll_certificate  "$cert_uuid" "$cert_cn"
    trust_certificate_chain "$cert_uuid"
    setup_tsp_profile "$tsp_name" tsp_uuid
    setup_signing_profile "$sp_name" "$cert_uuid" "$policy_oid" "$tq_uuid" "$TIMESTAMP_FORMATTING_CONN_UUID" sp_uuid
    link_tsp_signing_profile "$tsp_uuid" "$tsp_name" "$sp_uuid"
    setup_tsp_basic_credential "$tsp_uuid" cred_uuid
    set_policy_oid="$policy_oid"
    set_tq_uuid="$tq_uuid"
  fi

  printf -v "KEY_UUID_${g}"             '%s' "$key_uuid"
  printf -v "RA_PROFILE_UUID_${g}"      '%s' "$ra_uuid"
  printf -v "ISSUED_CERT_UUID_${g}"     '%s' "$cert_uuid"
  printf -v "ISSUED_CERT_CN_${g}"       '%s' "$cert_cn"
  printf -v "TSP_PROFILE_UUID_${g}"     '%s' "$tsp_uuid"
  printf -v "TSP_CREDENTIAL_UUID_${g}"  '%s' "$cred_uuid"
  printf -v "SIGNING_PROFILE_UUID_${g}" '%s' "$sp_uuid"
  printf -v "POLICY_OID_${g}"           '%s' "$set_policy_oid"
  printf -v "TIME_QUALITY_UUID_${g}"    '%s' "$set_tq_uuid"
}

# --- Summary ------------------------------------------------------------------
print_summary() {
  local nq_key_name="${KEY_NAME_BASE}-non-qualified"
  local q_key_name="${KEY_NAME_BASE}-qualified"
  local nq_ra_name="${RA_PROFILE_NAME_BASE}-non-qualified"
  local q_ra_name="${RA_PROFILE_NAME_BASE}-qualified"
  local nq_tsp_name="${TSP_PROFILE_NAME_BASE}-non-qualified"
  local q_tsp_name="${TSP_PROFILE_NAME_BASE}-qualified"
  local nq_sp_name="${SIGNING_PROFILE_NAME_BASE}-non-qualified"
  local q_sp_name="${SIGNING_PROFILE_NAME_BASE}-qualified"
  local set_name
  set_name=$(recorded_set_name)

  cat <<EOF

Setup complete. Created resources:

  Shared infrastructure:
    connector       $CRED_CONN_NAME                      $CRED_CONN_UUID
    connector       $EJBCA_CONN_NAME                     $EJBCA_CONN_UUID
    connector       $CRYPTO_CONN_NAME                    $CRYPTO_CONN_UUID  (--crypto-provider ${CRYPTO_PROVIDER})
    connector       $TIMESTAMP_FORMATTING_CONN_NAME      $TIMESTAMP_FORMATTING_CONN_UUID
    connector       $VAULT_CONN_NAME                     $VAULT_CONN_UUID
    credential      $CREDENTIAL_NAME                     $CRED_UUID
    authority       $AUTHORITY_NAME                      $AUTH_UUID
    token           $TOKEN_NAME                          $TOKEN_UUID
    token-profile   $TOKEN_PROFILE_NAME                  $TOKEN_PROFILE_UUID
    vault-instance  $VAULT_INSTANCE_NAME                 $VAULT_INSTANCE_UUID
    vault-profile   $VAULT_PROFILE_NAME                  $VAULT_PROFILE_UUID
    mapped-user     $MAPPED_USER_USERNAME                $MAPPED_USER_UUID
    role            $MAPPED_USER_ROLE_NAME               $MAPPED_USER_ROLE_UUID  (object-scoped: tspProfiles, signingProfiles, keys, tokens, tokenProfiles)

  TSA ${set_name} non-qualified set:
    key             $nq_key_name    $KEY_UUID_NQ
    ra-profile      $nq_ra_name     $RA_PROFILE_UUID_NQ
    certificate     CN=${ISSUED_CERT_CN_NQ}   $ISSUED_CERT_UUID_NQ
    tsp-profile     $nq_tsp_name    $TSP_PROFILE_UUID_NQ
    signing-profile $nq_sp_name     $SIGNING_PROFILE_UUID_NQ
    basic-cred      $TSP_CREDENTIAL_USERNAME (mapped user $MAPPED_USER_USERNAME)   $TSP_CREDENTIAL_UUID_NQ

  TSA ${set_name} qualified set:
    time-quality    $TIME_QUALITY_CONFIG_NAME       $TIME_QUALITY_UUID
    key             $q_key_name     $KEY_UUID_Q
    ra-profile      $q_ra_name      $RA_PROFILE_UUID_Q
    certificate     CN=${ISSUED_CERT_CN_Q}   $ISSUED_CERT_UUID_Q
    tsp-profile     $q_tsp_name     $TSP_PROFILE_UUID_Q
    signing-profile $q_sp_name      $SIGNING_PROFILE_UUID_Q
    basic-cred      $TSP_CREDENTIAL_USERNAME (mapped user $MAPPED_USER_USERNAME)   $TSP_CREDENTIAL_UUID_Q
EOF
}

existing_summary_sets() {
  [[ -s "$1" ]] || { echo '{}'; return 0; }
  jq -c 'def named_set_entry: type == "object" and has("nonQualified");
    .sets | if type == "object" then with_entries(select(.value | named_set_entry)) else {} end' "$1" 2>/dev/null || echo '{}'
}

recorded_set_name() {
  echo "${SET_NAME:-$KEY_NAME_BASE}"
}

issued_cn_prefix() {
  local nq_prefix="${ISSUED_CERT_CN_NQ%-non-qualified}" q_prefix="${ISSUED_CERT_CN_Q%-qualified}"
  [[ "$nq_prefix" == "$q_prefix" ]] && echo "$nq_prefix"
  return 0
}

write_json_summary() {
  [[ -z "$JSON_SUMMARY_FILE" ]] && return 0
  [[ -d "$JSON_SUMMARY_FILE" ]] && die "--json-summary target is a directory: $JSON_SUMMARY_FILE"

  local dir; dir=$(dirname "$JSON_SUMMARY_FILE")
  mkdir -p "$dir" || die "Cannot create directory for --json-summary: $dir"

  # The summary carries the TSP Basic credential password.
  local tmp; tmp=$(mktemp "${dir}/.json-summary.XXXXXX") || die "Cannot create a temporary file in $dir"
  TEMP_FILES+=("$tmp")
  chmod 600 "$tmp" || die "Cannot restrict permissions on $tmp"
  local mode
  mode=$(stat -c '%a' "$tmp" 2>/dev/null || stat -f '%Lp' "$tmp" 2>/dev/null || echo "")
  [[ "$mode" == "600" ]] \
    || warn "$JSON_SUMMARY_FILE will hold the TSP Basic credential password at mode ${mode:-unknown}, not 0600; this filesystem does not enforce POSIX permissions - protect the file yourself"

  local set_name cn_prefix existing_sets
  set_name=$(recorded_set_name)
  cn_prefix=$(issued_cn_prefix)
  existing_sets=$(existing_summary_sets "$JSON_SUMMARY_FILE")

  jq \
    --arg ilmHost "$ILM_HOST" \
    --arg connectorHost "$CONNECTOR_HOST" \
    --arg setName "$set_name" \
    --arg cnPrefix "$cn_prefix" \
    --arg cryptoProvider "$CRYPTO_PROVIDER" \
    --arg credConnName "$CRED_CONN_NAME"                        --arg credConnUuid "$CRED_CONN_UUID" \
    --arg ejbcaConnName "$EJBCA_CONN_NAME"                      --arg ejbcaConnUuid "$EJBCA_CONN_UUID" \
    --arg cryptoConnName "$CRYPTO_CONN_NAME"                    --arg cryptoConnUuid "$CRYPTO_CONN_UUID" \
    --arg tfcConnName "$TIMESTAMP_FORMATTING_CONN_NAME"         --arg tfcConnUuid "$TIMESTAMP_FORMATTING_CONN_UUID" \
    --arg vaultConnName "$VAULT_CONN_NAME"                      --arg vaultConnUuid "$VAULT_CONN_UUID" \
    --arg credentialName "$CREDENTIAL_NAME"                     --arg credentialUuid "$CRED_UUID" \
    --arg authorityName "$AUTHORITY_NAME"                       --arg authorityUuid "$AUTH_UUID" \
    --arg tokenName "$TOKEN_NAME"                               --arg tokenUuid "$TOKEN_UUID" \
    --arg tokenProfileName "$TOKEN_PROFILE_NAME"                --arg tokenProfileUuid "$TOKEN_PROFILE_UUID" \
    --arg vaultInstanceName "$VAULT_INSTANCE_NAME"              --arg vaultInstanceUuid "$VAULT_INSTANCE_UUID" \
    --arg vaultProfileName "$VAULT_PROFILE_NAME"                --arg vaultProfileUuid "$VAULT_PROFILE_UUID" \
    --arg mappedUserName "$MAPPED_USER_USERNAME"                --arg mappedUserUuid "$MAPPED_USER_UUID" \
    --arg roleName "$MAPPED_USER_ROLE_NAME"                     --arg roleUuid "$MAPPED_USER_ROLE_UUID" \
    --arg basicUser "$TSP_CREDENTIAL_USERNAME"                  --arg basicPassword "$TSP_CREDENTIAL_PASSWORD" \
    --arg tqName "$TIME_QUALITY_CONFIG_NAME"                    --arg tqUuid "$TIME_QUALITY_UUID" \
    --arg tqAccuracy "$TIME_QUALITY_EFFECTIVE_ACCURACY" \
    --argjson tqNtpServers "$TIME_QUALITY_EFFECTIVE_NTP_SERVERS_JSON" \
    --arg tqMaxDrift "$TIME_QUALITY_EFFECTIVE_MAX_CLOCK_DRIFT" \
    --arg tqCheckInterval "$TIME_QUALITY_EFFECTIVE_NTP_CHECK_INTERVAL" \
    --arg tqCheckTimeout "$TIME_QUALITY_EFFECTIVE_NTP_CHECK_TIMEOUT" \
    --arg tqSamplesPerServer "$TIME_QUALITY_EFFECTIVE_NTP_SAMPLES_PER_SERVER" \
    --arg tqMinReachable "$TIME_QUALITY_EFFECTIVE_NTP_SERVERS_MIN_REACHABLE" \
    --arg tqLeapSecondGuard "$TIME_QUALITY_EFFECTIVE_LEAP_SECOND_GUARD" \
    --arg nqPolicyOid "$POLICY_OID_NQ"                          --arg qPolicyOid "$POLICY_OID_Q" \
    --arg nqTqUuid "$TIME_QUALITY_UUID_NQ"                      --arg qTqUuid "$TIME_QUALITY_UUID_Q" \
    --arg nqKeyName "${KEY_NAME_BASE}-non-qualified"            --arg nqKeyUuid "$KEY_UUID_NQ" \
    --arg nqRaName "${RA_PROFILE_NAME_BASE}-non-qualified"      --arg nqRaUuid "$RA_PROFILE_UUID_NQ" \
    --arg nqCertCn "$ISSUED_CERT_CN_NQ"                         --arg nqCertUuid "$ISSUED_CERT_UUID_NQ" \
    --arg nqTspName "${TSP_PROFILE_NAME_BASE}-non-qualified"    --arg nqTspUuid "$TSP_PROFILE_UUID_NQ" \
    --arg nqCredUuid "$TSP_CREDENTIAL_UUID_NQ" \
    --arg nqSpName "${SIGNING_PROFILE_NAME_BASE}-non-qualified" --arg nqSpUuid "$SIGNING_PROFILE_UUID_NQ" \
    --arg qKeyName "${KEY_NAME_BASE}-qualified"                 --arg qKeyUuid "$KEY_UUID_Q" \
    --arg qRaName "${RA_PROFILE_NAME_BASE}-qualified"           --arg qRaUuid "$RA_PROFILE_UUID_Q" \
    --arg qCertCn "$ISSUED_CERT_CN_Q"                           --arg qCertUuid "$ISSUED_CERT_UUID_Q" \
    --arg qTspName "${TSP_PROFILE_NAME_BASE}-qualified"         --arg qTspUuid "$TSP_PROFILE_UUID_Q" \
    --arg qCredUuid "$TSP_CREDENTIAL_UUID_Q" \
    --arg qSpName "${SIGNING_PROFILE_NAME_BASE}-qualified"      --arg qSpUuid "$SIGNING_PROFILE_UUID_Q" \
    --arg keyAlgorithm "$KEY_ALGORITHM" \
    '. as $existingSets | {
      ilmHost: $ilmHost,
      connectorHost: $connectorHost,
      connectors: {
        credentialProvider:  { name: $credConnName,   uuid: $credConnUuid },
        ejbca:               { name: $ejbcaConnName,  uuid: $ejbcaConnUuid },
        timestampFormatting: { name: $tfcConnName,    uuid: $tfcConnUuid },
        vault:               { name: $vaultConnName,  uuid: $vaultConnUuid }
      },
      credential:    { name: $credentialName,   uuid: $credentialUuid },
      authority:     { name: $authorityName,    uuid: $authorityUuid },
      vaultInstance: { name: $vaultInstanceName, uuid: $vaultInstanceUuid },
      vaultProfile:  { name: $vaultProfileName, uuid: $vaultProfileUuid },
      mappedUser:    { username: $mappedUserName, uuid: $mappedUserUuid },
      role:          { name: $roleName, uuid: $roleUuid },
      timeQuality: {
        name:                   $tqName, uuid: $tqUuid, accuracy: $tqAccuracy,
        ntpServers:             $tqNtpServers, maxClockDrift: $tqMaxDrift,
        ntpCheckInterval:       $tqCheckInterval, ntpCheckTimeout: $tqCheckTimeout,
        ntpSamplesPerServer:    ($tqSamplesPerServer | tonumber? // null),
        ntpServersMinReachable: ($tqMinReachable     | tonumber? // null),
        leapSecondGuard:        (if $tqLeapSecondGuard == "" then null else $tqLeapSecondGuard == "true" end)
      },
      sets: ($existingSets + {
        ($setName): {
          cryptoProvider:      $cryptoProvider,
          connector:           { name: $cryptoConnName,   uuid: $cryptoConnUuid },
          token:               { name: $tokenName,        uuid: $tokenUuid },
          tokenProfile:        { name: $tokenProfileName, uuid: $tokenProfileUuid },
          keyAlgorithm:        $keyAlgorithm,
          certificateDnPrefix: (if $cnPrefix == "" then null else $cnPrefix end),
          nonQualified: {
            qualified: false,
            policyOid:       (if $nqPolicyOid == "" then null else $nqPolicyOid end),
            timeQualityUuid: (if $nqTqUuid == "" then null else $nqTqUuid end),
            key:             { name: $nqKeyName,  uuid: $nqKeyUuid },
            raProfile:       { name: $nqRaName,   uuid: $nqRaUuid },
            certificate:     { commonName: (if $nqCertCn == "" then null else $nqCertCn end), uuid: $nqCertUuid },
            tspProfile:      { name: $nqTspName,  uuid: $nqTspUuid },
            basicCredential: { username: $basicUser, password: $basicPassword, uuid: $nqCredUuid },
            signingProfile:  { name: $nqSpName,   uuid: $nqSpUuid }
          },
          qualified: {
            qualified: true,
            policyOid:       (if $qPolicyOid == "" then null else $qPolicyOid end),
            timeQualityUuid: (if $qTqUuid == "" then null else $qTqUuid end),
            key:             { name: $qKeyName,  uuid: $qKeyUuid },
            raProfile:       { name: $qRaName,   uuid: $qRaUuid },
            certificate:     { commonName: (if $qCertCn == "" then null else $qCertCn end), uuid: $qCertUuid },
            tspProfile:      { name: $qTspName,  uuid: $qTspUuid },
            basicCredential: { username: $basicUser, password: $basicPassword, uuid: $qCredUuid },
            signingProfile:  { name: $qSpName,   uuid: $qSpUuid }
          }
        }
      })
    }' <<<"$existing_sets" > "$tmp" || die "Failed to write JSON summary to $JSON_SUMMARY_FILE"

  mv "$tmp" "$JSON_SUMMARY_FILE" || die "Failed to move the JSON summary into place at $JSON_SUMMARY_FILE"

  ok "JSON summary written to $JSON_SUMMARY_FILE"
}

# --- Main ---------------------------------------------------------------------
main() {
  install_cleanup_traps
  parse_args "$@"
  validate
  setup_connectors
  setup_credential
  setup_authority
  setup_vault_instance
  setup_vault_profile
  setup_token
  setup_token_profile
  setup_time_quality_config
  setup_mapped_user
  setup_timestamping_role
  setup_issuer_ca

  setup_tsa_set "non-qualified" "$EJBCA_CERT_PROFILE"           "$POLICY_ID_NON_QUALIFIED" ""                   NQ
  setup_tsa_set "qualified"     "$EJBCA_CERT_PROFILE_QUALIFIED" "$POLICY_ID_QUALIFIED"     "$TIME_QUALITY_UUID" Q

  grant_timestamping_permissions

  print_summary
  write_json_summary
}

# return succeeds only where the script is sourced, so main runs whenever bash executes it.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
