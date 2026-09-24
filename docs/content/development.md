+++
title = "Development"
weight = 11
description = "Building the sidecar, formatting, and previewing this site."
+++

## The dev shell

```sh
nix develop
```

That gives you Node, Neovim, stylua and zola — everything the repository builds.

## The sidecar

`dist/sidecar.mjs` is **committed**, so that installing the plugin needs no build step. It has to be
rebuilt and committed whenever `sidecar/src/` changes.

```sh
cd sidecar
npm ci
npm run typecheck
npm run build   # writes ../dist/sidecar.mjs — commit it
```

`build` bundles `src/index.ts` with esbuild: ESM, targeting node18, with a `createRequire` banner. The
Agent SDK itself is a dev dependency — it is bundled in, but its per-platform Claude binaries are not,
since the sidecar runs your installed `claude` instead.

`typecheck` is `tsc --noEmit`.

## Lua formatting

```sh
stylua lua plugin
```

`.stylua.toml` sets a 120-column width, spaces, and an indent of 2.

## This site

The documentation site is a [Zola](https://www.getzola.org/) site under `docs/`, deployed to GitHub Pages
by `.github/workflows/pages.yml` on every push to `main`.

For the fast loop, with live reload:

```sh
zola serve --root docs
```

> [!NOTE]
> `zola serve` overrides `base_url` with `127.0.0.1:1111`, so it cannot tell you whether a link works at
> the site's real sub-path. Use `nix build .#docs` for that.

To build it exactly as CI does:

```sh
nix build .#docs --print-build-logs
nix flake check --print-build-logs
```

`checks.docs` is the same derivation, so a broken template or a dead `@/` link fails `nix flake check`.

> [!WARNING]
> The flake's source is `git+file://`, which means Nix does not see untracked files. A newly added page
> must be `git add`-ed — staging is enough, no commit needed — before `nix build .#docs` can see it.
> Otherwise it fails with a confusing "path does not exist" error.

### Writing pages

Pages are flat markdown files in `docs/content/`, ordered by `weight` in their front matter:

```toml
+++
title = "Configuration"
weight = 2
description = "Every option, its default, and what it changes."
+++
```

`description` does double duty: the `<meta name=description>` and the visible tagline under the page's
heading. The sidebar builds itself from the section's pages, so adding a file is all that's needed to add
a nav entry.

Internal links **must** use Zola's `@/` form, because the site is served from a sub-path:

```markdown
[Configuration](@/configuration.md)
[a specific option](@/configuration.md#transport)
```

A hand-written `/configuration/` would resolve against the domain root and 404. A dead `@/` link fails the
build, which is the point.

## Layout

| Path | |
|---|---|
| `lua/claude-code/` | The plugin |
| `lua/claude-code/ui/` | Everything that draws |
| `lua/claude-agent-sdk/` | The [standalone Agent SDK port](@/agent-sdk.md) |
| `plugin/claude-code.lua` | The `:Claude` command |
| `sidecar/src/` | The Node sidecar |
| `dist/sidecar.mjs` | Its committed build output |
| `nix/` | The plugin and docs derivations |
| `docs/` | This site |
