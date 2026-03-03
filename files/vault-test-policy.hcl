# Allow read/write/list on KV v2 secrets
path "secret/data/*" {
  capabilities = ["create", "update", "read", "delete"]
}

path "secret/metadata/*" {
  capabilities = ["list", "read", "delete"]
}

path "common/version2/data/*" {
  capabilities = ["create", "update", "read", "delete"]
}

path "common/version2/metadata/*" {
  capabilities = ["list", "read", "delete"]
}

# Allow read/write/list on KV v1 secrets
path "common/version1/*" {
  capabilities = ["create", "update", "read", "delete"]
}

path "legacy/*" {
  capabilities = ["create", "update", "read", "delete"]
}

# Allow listing mounts
path "sys/mounts" {
  capabilities = ["read"]
}

# Allow reading specific mount configuration (optional but useful)
path "sys/mounts/*" {
  capabilities = ["read"]
}
