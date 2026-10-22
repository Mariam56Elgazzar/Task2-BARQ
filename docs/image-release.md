# Application image releases

The `Test and release notes image` workflow packages the API for the AMD64 EC2
instances. The image name is `ghcr.io/<repository-owner>/notes-api` with a lowercase
owner. In this repository that resolves to `ghcr.io/mariam56elgazzar/notes-api`.
An image reference is not evidence of publication: the first version must complete
the release workflow before deployment can use it.

## What happens

1. Pull requests to `main` run the API unit/integration tests against disposable
   PostgreSQL, build the image, and exercise the packaged API with a second
   disposable database. Tests never use the development database.
2. Grype scans operating-system and Python packages. High or critical findings
   fail the workflow, including findings without an available fix. The JSON report
   is retained for seven days. Scanner/download failures also stop publication.
3. A pushed `vMAJOR.MINOR.PATCH` tag runs those same checks. The tag's commit must
   already be in `main`; review and merge the PR before tagging.
4. The verified image is saved and transferred to the publication job. That job
   loads and pushes the same image, without rebuilding it, using the workflow's
   short-lived `GITHUB_TOKEN` with `packages: write`.
5. Publication creates the version tag and a full `sha-<commit>` tag. An existing
   version is rejected. Deploy with the `@sha256:...` digest printed in the job
   summary: registry tags are names, while a digest identifies exact content.
6. A separate fresh runner pulls that digest with read-only package permission and
   verifies UID 10001. This proves authenticated pull access, not anonymous access
   or successful deployment to AWS.

PR verification has only `contents: read`. Registry write permission is limited
to the publishing job on version-tag pushes. Third-party Actions are pinned to
reviewed commit hashes. No personal access token or database secret is required
in repository secrets for the workflow. Test passwords are generated per run.

The image uses Python 3.11.17 on digest-pinned Debian 13 (Trixie). The first scan
identified vulnerable Debian 12 libraries and old packages vendored in setuptools.
The newer base supplies updated system libraries; setuptools/wheel are removed
after dependency installation because the API does not need build tools at runtime.
`pip check` and the packaged-image test verify the remaining dependencies work.
The vulnerability threshold remains unchanged; each build must pass a fresh scan.

## First release

Agree the package owner/name and visibility with the repository owner before
publishing. Public packages allow anonymous pulls; private packages require
deployment credentials. GitHub initially creates a new package as private, even
for a public repository. The workflow does not change package visibility.

After teammate approval and merge, run from a clean checkout (example first
version; check that it has not already been used):

```bash
git switch main
git pull --ff-only origin main
git tag -a v1.0.0 -m "Release notes API v1.0.0"
git push origin v1.0.0
```

Open GitHub Actions and inspect all three jobs. Copy the digest from the publish
summary only after the workflow succeeds. Never move a published release tag.
After a code correction, merge it and publish a new patch version.

For public delivery, the package owner changes the package visibility to Public
in GitHub's package settings after the first publication. Then prove anonymous
access using a fresh Docker credential directory on Linux/WSL:

```bash
export DOCKER_CONFIG="$(mktemp -d)"
# Replace the digest with the actual successful release output.
docker pull ghcr.io/mariam56elgazzar/notes-api@sha256:REPLACE_WITH_RELEASE_DIGEST
```

For private delivery, supply a read-only `read:packages` credential through Vault
and use Ansible's `community.docker.docker_login` before deployment. Do not put
registry tokens in Compose, Git, command arguments, or shared logs. This deployment
credential integration belongs with the secrets/application roles.

Give the deployment owner the successful run URL, version, immutable digest,
platform (`linux/amd64`), and proven pull method. The app still needs `DB_HOST`,
`DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD` at runtime. Publishing an image
does not create the database or apply its schema.

## Local verification and troubleshooting

After building the image as described in the local development guide, run:

```bash
python scripts/verify-image.py notes-api:local
```

Python 3.11+ and Docker are required. The script checks the running UID,
authenticated readiness, restricted database role, real HTTP CRUD with an
independent SQL read, and absence of temporary build certificates/admin credentials
in the app. It publishes no ports and removes only its uniquely named test
containers/network. Its database uses temporary storage and is disposable.

| Failure | Action |
| --- | --- |
| API/image test fails | Fix the test failure before creating a release tag; inspect local logs without sharing credentials |
| Vulnerability scan fails | Read `image-scan`; update the affected base/dependency, rerun tests, and review the change. Do not silently lower the threshold or suppress findings |
| Tag/ancestry check fails | Use a full numeric version and a commit already merged into `main` |
| GHCR push denied | Check package ownership, repository Actions access to an existing package, and permission policies |
| Version already exists | Do not overwrite it; use its verified digest or release a new version |
| Pull denied | Confirm package visibility, package access, and the private pull credential if applicable |

The GitHub-hosted runner builds using standard public certificate authorities.
The optional local antivirus CA is not uploaded or needed in Actions. This
workflow publishes the application image only; AWS deployment, Vault configuration,
backups, and restore testing are separate tasks.

References: [GitHub Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
and [Anchore scan action](https://github.com/anchore/scan-action).
