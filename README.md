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

If you are using the self-signed or not publicly trusted certificates, you should add the CA certificate to the trusted certificates in the Docker. You can add the CA certificate to the `./secrets/trusted_certificates.pem` file and it will be automatically mounted to the Docker containers.

The file contains the CA certificate in the PEM format. You can add multiple certificates to the file.

> [!IMPORTANT]
> The `./secrets/trusted_certificates.pem` file must exist before starting the services, otherwise Docker will fail to mount it. Create it before the first `docker compose up`, even if it is empty:
> ```bash
> touch secrets/trusted_certificates.pem
> ```
> If you are using the dummy certificates for development (see [Authentication](#authentication)), add the [ILM Dummy Root CA](https://github.com/OmniTrustILM/helm-charts/blob/main/dummy-certificates/certs/root-ca.cert.pem) to this file and restart the `auth` service:
> ```bash
> docker compose -f czertainly-compose.yml -f postgres-compose.yml --profile core restart auth
> ```

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

CZERTAINLY authenticate the users using the client certificate on the mTLS enabled port. For the development purposes, you can use non-TLS port and simulate the authenticated user by sending the `ssl-client-cert` header with the URL-encoded Base64 certificate.

> [!IMPORTANT]
> The certificate value must be **URL-encoded** (e.g. `+` → `%2B`, `=` → `%3D`). Sending a plain Base64 value will cause the `+` characters to be interpreted as spaces, resulting in an authentication error.

You can register the certificate for the first administrator using the [`Local API`](https://docs.czertainly.com/api/core-local/#tag/Local-operations/operation/addAdmin). For the development purposes, you can use the [`ILM Administrator`](https://github.com/OmniTrustILM/helm-charts/blob/main/dummy-certificates/certs/admin.cert.pem) certificate.

> [!IMPORTANT]
> The Local API listens only on the container's internal port `8080` and requires no authentication. The externally-mapped port `8280` exposes the regular API, which requires client-cert auth and returns HTTP 401 without one. Use `docker exec` to call the Local API from inside the container:
> ```bash
> docker exec core curl -X POST \
>   -H 'content-type: application/json' \
>   -d @first-admin.json \
>   http://localhost:8080/api/v1/local/admins
> ```

To create the administrator, follow [Create Super Administrator](https://docs.czertainly.com/docs/certificate-key/installation-guide/create-super-administrator).

Additional user and roles can be added using the CZERTAINLY API or Administrator UI.

## Administrator frontend

To run the Administrator frontend and use the backend services for the development, you can start the development server in [fe-administrator](https://github.com/OmniTrustILM/fe-administrator) repository.

Create a `./src/setupProxy.js` file in the root of the repository with the following content:

```javascript
const proxyConfig = {
    server: {
        proxy: {
            '/api': {
                target: 'http://localhost:8280',
                changeOrigin: true,
                secure: false,
                headers: {
                    // URL-encoded Base64 certificate of the ILM Administrator
                    'ssl-client-cert': 'MIIEmDCCAoCgAwIBAgIUSpLD/%2BgTWhMxIlMog2Bdlm3CDjUwDQYJKoZIhvcNAQENBQAwGDEWMBQGA1UEAwwNRHVtbXkgUm9vdCBDQTAeFw0yNjA0MjAxNDQyMTdaFw00NjA0MTUxNDQyMTdaMBgxFjAUBgNVBAMMDUFkbWluaXN0cmF0b3IwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC00ipGosoB9c%2BJ0xNOZxeCBzVCO14OvQ1Wx1apYy6mIb9prbW%2BJDzzC9PV/Vq/3jARGe7n1nCklzGWESfGzBB%2BDXRO0z1A%2BBRJ2jDh6/wym4atB45R9dkfDbhTFmWVmNPVrc5qYkC3JJhmeuhJcz71XBsSL7l9/3qdruXB/ZeBHSkJLkHVoEviacejKGi9ajuNY0Oo4wY7GDN%2BS8RQP4X84kKxzJRSwcT883/kHq2b83pwSygxfLUcz0FLfJeGNf0NtD%2BACurznbUELrNDF/xYGJeCnxssmTOyx4BtzA0RLINw4ews8%2BmPW0frBoCmx7KpQheT7hWYTGZaumVCVCMbAgMBAAGjgdkwgdYwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBeAwEwYDVR0lBAwwCgYIKwYBBQUHAwIwHQYDVR0OBBYEFKP9zS5hQtIMB4Xhm3asjv/ZC0QpMB8GA1UdIwQYMBaAFKrDVRKMwNLPigRWgvEnfgyfERiyMGEGA1UdIARaMFgwVgYEVR0gADBOMEwGCCsGAQUFBwICMEAMPlRoaXMgaXMgYSBkdW1teSBhZG1pbmlzdHJhdG9yIGNlcnRpZmljYXRlIGZvciB0ZXN0aW5nIHB1cnBvc2VzMA0GCSqGSIb3DQEBDQUAA4ICAQBfCGjQPlYTy1J3o94tGlE26Jwy8b3z/x3zNjztZ4QX5wAIkiUoT24DcZsZp9rlKMHsr4Dcv/JcBKnNrfYD%2BESCEXcZcuUIBbv4oErY%2BfAsmp6gW62gQnDF6GZCfz%2BKiTy%2BvtB493yvbKFepNfI5lgnVh443iD3TSbFmQYfeWLYYyqwjgNxFnPffPZ6w2cV7xw5pmF3FI5RM5SBhSEl0U3Aqbvnklw3A5mHis4t4joaptksg%2ByVExt38azhS34eIkGUbiGKsfbgr7%2BqaaqX1MRSrjE5FVh9uCs5ALmHBiZ5iEX1i3NwmLoqth71%2BAD11yUgX6LGp/kc85OIk1mjkom27ncY%2BwQ5lSZKuK8Ts1zQSD8iGalL7RSNnRALr%2B97mDBeZJYBBGPiEYj7UUC0NKw7qcLQ5bowfHnBZUAZbXWdR5AJa7VsPDH6k9Cvy/R9h0miyQF2QMs3%2BmYHLNdLTzqSkUq9XYnZWbm7CwprH1dW2iW78PdfOtDl90MhbGkVR50xpHNC3hwdBe0hV9RIw46Qtwb8PZSJq8EFlNrSK0J7882JwG8CDhOBxgzQGAahv3wb0B1/W3LRVbR1D9UyvDKN121uw025lJ%2BrCTUJ5T%2BfepyQxdvkH%2BIrmNvkh0kcZISG1If4HASDWFN9OMjvNesiRFHgpNZ26Xh347DfNvNrXQ%3D%3D',
                },
            },
        },
    },
};

export default proxyConfig;
```

This will proxy the requests from the frontend to the backend services authenticated and authorized with the certificate in the `ssl-client-cert` header.

> [!IMPORTANT]
> The `src/setupProxy.js` file is gitignored — each developer creates their own local copy. Do not commit this file.
> The certificate value must be URL-encoded. To generate the value for your own certificate, use `node -e "console.log(encodeURIComponent('<base64_cert>'))"`.
> It is important to add certificates that should be trusted by the Auth service to `trusted_certificates.pem` (see [Trusted CA certificates](#trusted-ca-certificates)).

## Connectors and technologies

To have a complete setup, you will need to have a technology available for the connectors. For example, if you would like to work with the Authority Provider functions, you should have appropriate connector running that is able to communicate with the target technology.
