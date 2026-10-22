# Task2-BARQ

A PostgreSQL-backed notes API with a local Docker Compose development stack.

```text
localhost:8080 -> Nginx:80 -> app:8000 -> PostgreSQL:5432
                                           |
                                      named data volume
```

- [Local container setup, verification, and troubleshooting](docs/local-development.md)
- [API endpoints, configuration, schema, and tests](app/README.md)
- [Image release workflow, registry access, and troubleshooting](docs/image-release.md)

The local stack runs on one Docker host. AWS deployment uses separate application
and database hosts and is separate work. The API has no end-user authentication;
the local HTTP port is bound to loopback. Image publication, deployed secrets,
AWS storage, backups, and restoration are not provided by this local stack.
