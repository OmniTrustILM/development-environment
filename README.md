# CZERTAINLY-Docker-Develop-Environment

This repository contains Docker Compose files and scripts that can be used to streamline development of the CZERTAINLY platform.
There are couple of microservices that need to be running for the development. Depending on the service that is going to be developed, the compose will run the services.

## Source repository directory naming

The `build:` paths in `czertainly-compose.yml` reference source directories under `${CZERTAINLY_SOURCES_BASE_DIR}` using their lowercase repository names (matching the `OmniTrustILM/<repo>` GitHub convention) — for example `${CZERTAINLY_SOURCES_BASE_DIR}/auth`, `${CZERTAINLY_SOURCES_BASE_DIR}/scheduler`, `${CZERTAINLY_SOURCES_BASE_DIR}/ejbca-ng-connector`.

> [!IMPORTANT]
> If you previously cloned the sources under their old mixed-case names (e.g. `CZERTAINLY-Auth`, `CZERTAINLY-Scheduler`), rename the directories to the lowercase form before running `docker compose up`, otherwise the build will fail with `path not found`. Example one-liner:
>
> ```bash
> for d in "$CZERTAINLY_SOURCES_BASE_DIR"/CZERTAINLY-*; do
>   new="$(basename "$d" | sed 's/^CZERTAINLY-//' | tr '[:upper:]' '[:lower:]')"
>   mv "$d" "$(dirname "$d")/$new"
> done
> ```

## Setup the environment variables

Create a `.env` file in the root of the repository and update values. The `.env.example` file can be used as a template with the following values:

| Variable                    | Description                                                                                             |
|-----------------------------|---------------------------------------------------------------------------------------------------------|
| CZERTAINLY_SOURCES_BASE_DIR | Path to the directory where the CZERTAINLY sources are located for building the images.                 |
| DB_HOST                     | Hostname of the PostgreSQL database. Keep the default value if you are using the PostgreSQL in Docker.  |
| DB_PORT                     | Port of the PostgreSQL database. Keep the default value if you are using the PostgreSQL in Docker.      |
| DB_USERNAME                 | Username for the PostgreSQL database. Keep the default value if you are using the PostgreSQL in Docker. |
| DB_PASSWORD                 | Password for the PostgreSQL database. Keep the default value if you are using the PostgreSQL in Docker. |
| DB_NAME                     | Name of the PostgreSQL database. Keep the default value if you are using the PostgreSQL in Docker.      |
| SMTP_HOST                   | Hostname of the SMTP server. Used with the `email-notification-provider` service.                       |
| SMTP_USERNAME               | Username for the SMTP server. Used with the `email-notification-provider` service.                      |
| SMTP_PASSWORD               | Password for the SMTP server. Used with the `email-notification-provider` service.                      |
| GITHUB_USERNAME             | Username for the GitHub account to get the packages, if necessary.                                      |
| GITHUB_PASSWORD             | Password for the GitHub account to get the packages, if necessary.                                      |

### Trusted CA certificates

If you are using the self-signed or not publicly trusted certificates, you should add the CA certificate to the trusted certificates in the Docker. You can add the CA certificate to the `./secrtes/trusted_certificates.pem` file and it will be automatically mounted to the Docker containers.

The file contains the CA certificate in the PEM format. You can add multiple certificates to the file.

## Quick start

Copy the `.env.example` file to `.env` and update the `CZERTAINLY_SOURCES_BASE_DIR` with the path to the CZERTAINLY sources on your local.
For a quick start, you can use the following command to start the environment for the core services using the PostgreSQL database in docker:

```bash
docker-compose -f czertainly-compose.yml -f postgres-compose.yml --profile database --profile core up
```

This should merge both `czertainly-compose.yml` and `postgres-compose.yml` compose file and start the PostgreSQL database and the core services according to the profiles `database` and `core`.

To stop the services, you can use the following command:

```bash
docker-compose -f czertainly-compose.yml -f postgres-compose.yml --profile database --profile core down
```

## RabbitMQ

The `rabbitmq` service mounts `./rabbitmq/definitions.json` and `./rabbitmq/rabbitmq.conf` into the container. On boot the broker imports the topology (vhost, `czertainly` exchange, `core.*` queues, bindings, and the `guest` admin user) from `definitions.json`. The data directory is bind-mounted at `./data/rabbitmq/data` so broker state persists across restarts.

> [!IMPORTANT]
> If you upgrade an existing dev environment that already has data in `./data/rabbitmq/data` and the broker logs `PRECONDITION_FAILED` errors during definitions import (typically because previously-created queues have different attributes than the new declarations), wipe the persisted state and restart:
>
> ```bash
> docker compose -f czertainly-compose.yml down
> rm -rf ./data/rabbitmq/data
> docker compose -f czertainly-compose.yml --profile core up
> ```
>
> The next boot will import `definitions.json` against an empty Mnesia store and the topology will match the file exactly.

## Database

CZERTAINLY requires a PostgreSQL database to store the data. The database can be started in Docker using the `postgres-compose.yml` file or you can use your own database.
The database access is configured using [environment variables](#setup-the-environment-variables) in the `.env` file.

### Using the PostgreSQL in Docker

The `postgres-compose.yml` file contains the PostgreSQL database service. The database is used by the core services and the services that require the database.
By default the database will mount the `./data` directory to store the data. The data will be persisted even if the database is stopped. If the `./data` folder does not exists, it will be created.

To start the PostgreSQL database in Docker, you can use the following command:

```bash
docker-compose -f postgres-compose.yml --profile database up
```

To stop the PostgreSQL database, you can use the following command:

```bash
docker-compose -f postgres-compose.yml --profile database down
```

To remove the data and start the database from scratch, you should remove the `./data` directory.

> [!IMPORTANT]  
> The `./data` directory contains the data of the PostgreSQL database. Removing the directory will remove all data stored in the database. Make sure to back up the data before removing the directory, if necessary.

## Profiles

The `czertainly-compose.yml` file contains profiles that can be used to start the required services based on what you are going to work on. The profiles are:

| Profile    | Services                                                                                                                                                                                                                                                                                                  | Description                                                              |
|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| `core`     | `opa` `rabbitmq` `auth` `opa-bundle-server` `scheduler` `core`                                                                                                                                                                                                                                            | Starts the core services of the CZERTAINLY platform.                     |
| `database` | `postgres`                                                                                                                                                                                                                                                                                                | Starts the PostgreSQL database.                                          |
| `core-dev` | `opa` `rabbitmq` `auth` `opa-bundle-server` `scheduler`                                                                                                                                                                                                                                                   | Starts services that are needed for the development of the Core service. |
| `all`      | `opa` `rabbitmq` `auth` `opa-bundle-server` `scheduler` `core` `postgres` `common-credential-provider` `ejbca-ng-connector` `keystore-entity-provider` `software-cryptography-provider` `ip-discovery-provider` `cryptosense-discovery-provider` `x509-compliance-provider` `email-notification-provider` | Starts all services.                                                     |

Each service can be started separately using the profile with name `[service name]-standalone`.

### Running service for development of the Core service

To start the services that are needed for the development of the Core service, you can use the `core-dev` profile:

```bash
docker-compose -f czertainly-compose.yml --profile core-dev up
```

Once the services are started, you can start the Core service in your favorite IDE and connect to the running services.

## Authentication

CZERTAINLY authenticate the users using the client certificate on the mTLS enabled port. For the development purposes, you can use non-TLS port and simulate the authenticated user, you can send the `X-APP-CERTIFICATE` header with the Base64 encoded certificate.

You can register the certificate for the first administrator using the [`Local API`](https://docs.czertainly.com/api/core-local/#tag/Local-operations/operation/addAdmin). For the development purposes, you can use the [`CZERTAINLY Administrator`](https://github.com/CZERTAINLY/CZERTAINLY-Helm-Charts/blob/main/dummy-certificates/certs/admin.cert.pem) certificate.

To create the administrator, follow [Create Super Administrator](https://docs.czertainly.com/docs/certificate-key/installation-guide/create-super-administrator).

Additional user and roles can be added using the CZERTAINLY API or Administator UI.

## Administrator frontend

To run the Administrator frontend and use the backend services for the development, you can start the development server in [CZERTAINLY-FE-Administrator](https://github.com/3KeyCompany/CZERTAINLY-FE-Administrator) repository.

Create a `./src/setupProxy.cjs` file in the root of the repository with the following content:

```javascript
const proxyConfig = {
    server: {
        proxy: {
            '/api': {
                target: 'http://localhost:8280',
                changeOrigin: true,
                secure: false,
                headers: {
                    // Base64Url encoded certificate of the CZERTAINLY Administrator
                    'ssl-client-cert': 'MIIEtDCCApygAwIBAgIVAP15kVt62m8a4p52xmbCcNCiSx8qMA0GCSqGSIb3DQEBDQUAMCMxITAfBgNVBAMMGENaRVJUQUlOTFkgRHVtbXkgUm9vdCBDQTAeFw0yMjA4MDQwODEzMzFaFw00MjA3MzAwODEzMzFaMCMxITAfBgNVBAMMGENaRVJUQUlOTFkgQWRtaW5pc3RyYXRvcjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAL%2FPWoJN2ieDZkp1JggrXjhDm%2FxrqX6acAmyqzBQujCUrbjFF8l1qdtI0fZyFrZBLeVHCwqQUz0Afjzj7FBMNP2ljVLrQbMfyjJG10NvuPOa9dP%2FVolgF4CRRg0Ebg5CCd0s3yZR%2FgIc6cl9x0Ruk8uRCpM4jZ7Y%2B%2F7jhf4%2Bc8mBlp2aRlAJtV3JOYQlux17IpJdJrngX%2FlKoZcp4zU9kQwunVxz5GBWhXGqMEcV6b7lGF5ocSlnrR3cUKZbdGbXcfK75%2BW4%2FLB6v6y9bR40R%2BIUd%2FmOuByQvqWyTCk5d2YWBmg%2FddPVFynb5a2%2BxjhJxBI%2B28iGXq6iroQrPouacv8CAwEAAaOB3jCB2zAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB%2FwQEAwIF4DATBgNVHSUEDDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUrUOz2v0EvBSHyemGXPnt7HaghBgwHwYDVR0jBBgwFoAU0%2FBNVjrmoD8XW%2FNVXeoxTIkD59YwZgYDVR0gBF8wXTBbBgRVHSAAMFMwUQYIKwYBBQUHAgIwRRpDVVRGODpUaGlzIGlzIGEgZHVtbXkgYWRtaW5pc3RyYXRvciBjZXJ0aWZpY2F0ZSBmb3IgdGVzdGluZyBwdXJwb3NlczANBgkqhkiG9w0BAQ0FAAOCAgEAWYlpEI8SCOnhKYpcp3n%2BBtaAoUrcwIckpzPPxNf%2B9LSKhPp4NEs%2BEGsfflz33IeEojck%2Bx%2FwBqggJdp7WrUsHz%2F0sAwCkrVjbh3Lx75msAqVqFUaX0gYbqstmbnHxqgcmseVkWmEHEOmdz0%2B%2FB0XrGagzQNW8EGW3PEv4yOCeqdgRt9Nyh%2BGUtVkavy%2BCkYRaIEHDGjtxJTMakXOaEU0tNmDoMBDQzLsqc75AYEeqlKvQs6vZICf%2BRltDaDgriSelE04PtjnIr6aKmWipFN2Wu8Zgi3qt7SSiMwk0OIvG4NGkOKckf5kRWlA6aLtkY2ABHObknIlJhfpU%2FsNN%2F5ma0c%2BrSXK2%2BPyDStxALMzM54GVfGpXmdR3fkEQ8mS35BU2l8Gp0mA%2FXi55eqWVXgxEDXph487O20HjGh%2BxHcI40ZObBIKvfD0kCi1sQcINpK6CGm0Jb1ojU%2BxFwgq2IhdJPrC7quEW3wEHCRQKGaTbSm6CfMdf3YOKgpIUrX5Da2wJN04RTOLxUvpQss%2Frup49Uq2pMGBPtAvtTzXyTJrw22bgBjJV%2Bjt60ZB0PVqRbaPa52hUMl7ewCGpVO2ByAcxoQ1%2BEnb28%2FSwDnW3rgsaCHOB0AzqzaQAwEbgAeUKDBxKwm0GqLIgMtGs7CaG58%2FKqZsMj8ADqqItY3XXAlhjb4%3D',
                },
            },
        },
    },
};

module.exports = proxyConfig;
```

This will proxy the requests from the frontend to the backend services authenticated and authorized with the certificate in the `ssl-client-cert` header.

> [!IMPORTANT]  
> Change the values in the middleware according to your setup and desired configuration. For example, it is important to add certificates that should be trusted by services (e.g. Auth service) to `trusted_certificates.pem` secret.

## Connectors and technologies

To have a complete setup, you will need to have a technology available for the connectors. For example, if you would like to work with the Authority Provider functions, you should have appropriate connector running that is able to communicate with the target technology.
