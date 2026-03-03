#!/bin/bash

set -e

# create kv v1 and v2 mounts, together with the default `secret/` kv v2 mount
# there'll be two kv mounts for each version and one pair of v1 and v2 versions
# will have a common path prefix
vault secrets enable -path=legacy kv
vault secrets enable -path=common/version1 kv
vault secrets enable -path=common/version2 kv-v2

# create a policy `test-policy`
vault policy write test-policy vault-test-policy.hcl

# enable approle
vault auth enable approle

# create named role
vault write auth/approle/role/ilm-connector \
    token_policies="test-policy" \
    token_type=default \
    secret_id_ttl=365d \
    token_ttl=365d \
    token_max_ttl=365d \
    secret_id_num_uses=4000 \
    token_num_uses=0

# verify policy
vault read auth/approle/role/ilm-connector
