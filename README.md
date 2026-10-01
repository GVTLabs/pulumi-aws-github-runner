# pulumi-aws-github-runner

Pulumi SDKs for [self-hosted GitHub Actions runners on AWS](https://github-aws-runners.github.io/terraform-aws-github-runner/),
generated from the `multi-runner` module of
[`github-aws-runners/terraform-aws-github-runner`](https://github.com/github-aws-runners/terraform-aws-github-runner)
via Pulumi's [Terraform module provider](https://github.com/pulumi/pulumi-terraform-module).

This repository does exactly one thing: it watches the upstream module for new
releases, regenerates the SDKs, and tags and releases the result under the same
version. Tag `v7.11.0` here contains the SDKs generated from upstream `v7.11.0`.
Everything under `sdks/` is generated — never edit it by hand.

Only `modules/multi-runner` is published. The root module provisions a single
runner configuration; multi-runner takes a map of them, so it covers one pool as
well as several.

## Using the SDKs

The supported way to consume the module is to let Pulumi generate the SDK into
your own project, which is the same command this repository automates:

```bash
pulumi package add terraform-module github-aws-runners/github-runner/aws//modules/multi-runner 7.11.0 github-runner
```

The Go SDK is the exception: it is a real module and can be depended on
directly, which spares a consumer from vendoring it behind a `replace`.

```bash
go get github.com/gvtlabs/pulumi-aws-github-runner/sdks/go/v7@v7.11.0
```

```go
import githubrunner "github.com/gvtlabs/pulumi-aws-github-runner/sdks/go/v7/github-runner"
```

The bridge stamps its own canonical path
(`github.com/pulumi/pulumi-terraform-module/sdks/go/github-runner/v7`) into every
Go SDK it generates, which matches no repository and so resolves nowhere. The
sync rewrites it to this one; see below. Go puts the major version in the import
path, so an upstream major release moves the Go SDK to `.../sdks/go/v8` and so
on.

The other four SDKs are not published to PyPI, npm, NuGet, or Maven. For those,
treat this repository as a versioned, reviewable record of what the bridge
produces: useful for diffing the module's inputs and outputs between releases,
auditing what lands in your stack before you upgrade, and vendoring.

## Running the module

The module provider executes the module with OpenTofu or Terraform under the
hood, but state lives in your Pulumi backend and the module is a single Pulumi
resource. It runs `terraform` from the `PATH` by default; set the `executor`
provider option to `opentofu` (or `PULUMI_TERRAFORM_MODULE_EXECUTOR=opentofu`)
and it downloads OpenTofu itself, so nothing needs installing.

The module's own AWS provider is configured through the package's provider, not
through your stack's `aws:` config:

```go
provider, err := githubrunner.NewProvider(ctx, "github-runner", &githubrunner.ProviderArgs{
	Executor: pulumi.String("opentofu"),
	Aws: pulumi.Map{
		"region": pulumi.String("eu-west-2"),
	},
})
```

The module expects its Lambda zips either as local files or as S3 objects. The
module runs in a working directory of its own, so local paths must be absolute;
uploading the [release assets](https://github.com/github-aws-runners/terraform-aws-github-runner/releases)
to S3 and passing `lambda_s3_bucket` and the `*_lambda_s3_key` inputs avoids
that entirely.

See the [upstream documentation](https://github-aws-runners.github.io/terraform-aws-github-runner/)
for the GitHub App setup and the full input reference. Inputs keep their
Terraform names, so `multi_runner_config` stays `Multi_runner_config` in Go.

## How the sync works

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) runs
[`scripts/sync.sh`](scripts/sync.sh) hourly. The script reads the latest upstream
release, exits early if a matching tag already exists, and otherwise regenerates
all five SDKs, commits them, and creates the mirroring tags. The workflow then
publishes a GitHub release for the `v<version>` tag, which is what a consumer
can subscribe to; a tag on its own notifies nobody. Git tags are the only state
the sync decision rests on, so the job is idempotent and needs no external
bookkeeping.

Two steps exist purely to keep the Go SDK consumable. The script rewrites the
bridge's canonical module path to this repository's and fails loudly if any
occurrence survives, so a change in the bridge's layout is caught rather than
silently publishing an unresolvable module. It then writes two tags per release:
`v<version>`, which names the release, and `sdks/go/v<version>`, which is the
only form the Go module proxy accepts for a module in a subdirectory. Without
the second, `go get` can see the module but resolve no versions of it.

GitHub does not allow one repository to subscribe to another repository's release
events, so polling is the only trigger available to us without cooperation from
the upstream maintainers. The workflow also accepts a `repository_dispatch` event
of type `upstream-release` if you ever want to wire up a relay and skip the
polling delay:

```bash
gh api repos/gvtlabs/pulumi-aws-github-runner/dispatches \
  -f event_type=upstream-release \
  -F 'client_payload[version]=7.11.0'
```

One wrinkle the script handles: the bridge resolves the module from
`registry.opentofu.org`, which can lag a GitHub release by minutes or hours. When
the release exists upstream but is not yet resolvable, the script exits `75` and
the workflow reports a neutral notice instead of a failure, leaving the next
scheduled run to pick it up. The script also verifies that the SDK it generated
reports the module and version that were asked for, so a registry fallback can
never be committed under the wrong tag.

## Running it locally

```bash
./scripts/sync.sh                      # sync the latest upstream release
./scripts/sync.sh --version 7.10.2     # backfill a specific version
./scripts/sync.sh --no-commit          # regenerate without committing
./scripts/sync.sh --force              # regenerate even if the tag exists
```

Requires the [Pulumi CLI](https://www.pulumi.com/docs/install/); no language
toolchains are needed, since the SDKs are generated but never built, and the
module provider fetches OpenTofu on its own.

## License

MIT, matching the upstream module. See [LICENSE](LICENSE).
