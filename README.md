<h1>
  <img src=".github/logo.webp" alt="" height="116">
  <br>
  tortoise-deploy
</h1>

[![Lint status][badge-lint-status]][badge-lint-status-url]
[![Build status][badge-build-status]][badge-build-status-url]  
[![Latest Tortoise-WoW build][badge-latest-tortoise-build]][badge-latest-tortoise-build-url]
[![Latest build date][badge-latest-build-date]][badge-latest-build-date-url]

---

> [!WARNING]
> tortoise-deploy was relaunched on 2026-10-04 with major changes that require
> adjusting your configuration. If you used it before this date, work through
> the [breaking changes](docs/breaking-changes.md) before you update.

---

> [!TIP]
> Also check out my similar Docker setups:
>
> - [vmangos-deploy][vmangos-deploy] for [VMaNGOS][vmangos], a progressive
>   Vanilla server emulator that aims to eventually support all versions from
>   `1.2.4.4222` to `1.12.1.5875`.
> - [cmangos-deploy][cmangos-deploy] for [CMaNGOS][cmangos], a server emulator
>   that supports Vanilla (which CMaNGOS calls Classic), TBC, and WotLK.

tortoise-deploy is a Docker-based solution for running
[Tortoise-WoW][tortoise-wow]. It offers:

- __Prebuilt Docker images for both `amd64` and `arm64`, built with GitHub
  Actions__: simply pull the images for your architecture and get started.
- __Multiple variants to choose from__: the `base` images contain Tortoise-WoW
  alone, while the `modules` images add a curated set of modules on top.
  `modules-bots` adds [TortoiseBots][tortoisebots], a Playerbot module, to that
  set.
- __Automated database migrations__: when you pull the latest Docker images and
  re-create the containers, the migrations are applied automatically to keep
  your databases up to date at all times.

> [!NOTE]
> The Docker images are built daily when Tortoise-WoW or a bundled module has
> had new commits since the last build. Additionally, every Monday, the latest
> images are rebuilt to keep their system packages up to date, even if neither
> Tortoise-WoW nor a bundled module has changed.

## Quick start

The steps below get a local installation running quickly, for playing on the
same machine. You need [Docker][docker] with [Docker Compose][docker-compose].
The steps set up the `base` variant. For `modules` or `modules-bots`, which the
[variants section](docs/usage.md#variants) describes, follow the notes in steps
1 and 2.

1. Clone the repository and copy the example configuration files:

   ```sh
   git clone https://github.com/mserajnik/tortoise-deploy.git
   cd tortoise-deploy
   cp config/mangosd.conf.example config/mangosd.conf
   cp config/realmd.conf.example config/realmd.conf
   ```

   For `modules` and `modules-bots`, also copy each `.conf.example` file in
   `config/modules/` to a `.conf` file, and for `modules-bots`, each one in
   `config/modules-bots/` as well. Then adjust the copies to your liking, for
   example the `GameType` or the `RealmZone` in your `config/mangosd.conf`. The
   files describe most of their options. Some options are set by the image and
   cannot be configured in the files. A comment at the top of your
   `mangosd.conf` and `realmd.conf` lists them.

2. Copy the example Compose file:

   ```sh
   cp compose.yaml.example compose.yaml
   ```

   For `modules` or `modules-bots`, copy `compose-modules.yaml.example` or
   `compose-modules-bots.yaml.example` instead.

3. Adjust your `compose.yaml`: set `TZ` to your time zone in every service, and
   change the database passwords. On Linux, set `TORTOISE_UID` and
   `TORTOISE_GID` to your user's UID and GID. The
   [Docker Compose reference](docs/compose.md) explains every setting.

4. Copy the contents of your client directory into
   `storage/mangosd/client-data/`, and extract the client data:

   ```sh
   docker compose run --rm extract-client-data
   ```

   Extracting can take many hours, and the
   [extracting the client data section](docs/usage.md#extracting-the-client-data)
   names the supported client and describes the details.

5. Start Tortoise-WoW and follow its output:

   ```sh
   docker compose up -d
   docker compose logs -f mangosd
   ```

   The first start takes longer, because it creates the databases. Do not
   interrupt it, or you may have to remove the database volume and start over.
   The server is ready when it prints `World server is up and running!`.

6. Create your first account. To do that, attach to the server console:

   ```sh
   docker compose attach mangosd
   ```

   Then create the account:

   ```text
   account create <account-name> <password>
   ```

   If you want to give the account Game Master permissions, for example, the
   [accounts section](docs/usage.md#accounts) explains the account levels. To
   leave the console again, press <kbd>Ctrl</kbd>+<kbd>P</kbd> and then
   <kbd>Ctrl</kbd>+<kbd>Q</kbd>.

7. Adjust the `realmlist.wtf` in the client directory to point the client at
   the local server:

   ```text
   set realmlist 127.0.0.1
   ```

   Then start the client and log in with the account you created.

For the full instructions, see the [usage documentation](docs/usage.md).

### Using a coding agent

A coding agent such as [Claude Code][claude-code] or [Codex][codex] can walk
you through the setup. Try a prompt like this one:

```text
Help me install and set up https://github.com/mserajnik/tortoise-deploy.
First, clone the repository and read the README and every file under docs/
carefully.
Then guide me through the installation process step by step, following the
documentation closely.
Do as much of the setup yourself as you safely can so that I only have to step
in when a manual action or personal preference is required.
Ask me about my preferences whenever a choice has to be made, explain the
relevant options clearly, and tailor your instructions to the OS I am using.
Assume that I am not familiar with Tortoise-WoW or Docker and that I have not
read the documentation myself.
For steps that I need to perform manually, give me clear instructions and exact
commands where appropriate.
Do not assume user-facing choices such as the image variant, optional services,
or networking-related preferences.
Ask me whenever the documentation presents a meaningful choice.
For settings and options that the documentation or the Tortoise-WoW example
configuration files indicate should generally be left alone, keep the defaults
unless I explicitly ask for something else.
Do not change settings and options that the documentation or the Tortoise-WoW
example configuration files indicate should not be changed.
```

The prompt that works best depends on the agent and the model.

> [!CAUTION]
> You use coding agents at your own risk, and you are responsible for the
> access you give them. The maintainer of this project is not liable for any
> damage or data loss they cause. Take precautions such as sandboxed access and
> limited permissions, and do not run them with `--yolo` or similar options
> that bypass their safety checks.

## Documentation

- [Usage](docs/usage.md): choosing images, the client data, running and
  updating Tortoise-WoW, backups, and database access.
- [Docker Compose reference](docs/compose.md): every setting in the Compose
  files.
- [Breaking changes](docs/breaking-changes.md): the changes you have to act on
  when you update.

## Modifications

The server images contain [Tortoise-WoW][tortoise-wow] with the patches from
[`docker/patches/`](docker/patches). A patch exists for one of these reasons:

- It corrects a problem that breaks the build or the running server.
- It adapts the code to how the images are built and run.
- It changes an upstream default to a value that gives objectively better
  results.

Every patch adds a comment to the code it changes, which explains what the
change does and why. A patch is removed once it is no longer needed, so the
directory can be empty at times.

The patches are `GPL-2.0-or-later`, like the Tortoise-WoW code from before its
move to `AGPL-3.0-only` in May 2026, which covers only the later contributions.
A patch that changes later code is also under `AGPL-3.0-only`.

## Maintainer

[Michael Serajnik][maintainer]

## Contribute

You are welcome to help out!

[Open an issue][issues] or [make a pull request][pull-requests].

## Licenses

- [`AGPL-3.0-or-later`][license-agpl-3.0-or-later] (Code)
- [`AGPL-3.0-only`][license-agpl-3.0-only] (Some patches)
- [`GPL-2.0-only`][license-gpl-2.0-only] (Database entrypoint script, based on
  MariaDB's)
- [`GPL-2.0-or-later`][license-gpl-2.0-or-later] (Patches)
- [`CC-BY-SA-4.0`][license-cc-by-sa-4.0] (Documentation, graphic assets, and
  issue templates)
- [`CC0-1.0`][license-cc0-1.0] (Configuration files)

This project follows the [REUSE specification][reuse-spec].

## Disclaimer

tortoise-deploy is an independent, community-made Docker setup for the
open-source [Tortoise-WoW][tortoise-wow] project. It is not affiliated with,
endorsed by, or sponsored by Blizzard Entertainment, Inc., and it is not an
official Tortoise-WoW project.

This project includes no game client data or other copyrighted game assets. You
must supply your own legitimate game client, from which the required data is
extracted locally on your own machine. It is intended for private,
non-commercial use only and comes with no warranty.

[badge-build-status]: https://github.com/mserajnik/tortoise-deploy/actions/workflows/build-docker-images.yaml/badge.svg
[badge-build-status-url]: https://github.com/mserajnik/tortoise-deploy/actions/workflows/build-docker-images.yaml
[badge-latest-build-date]: https://img.shields.io/endpoint?url=https%3A%2F%2Fscripts.mser.at%2Ftortoise-deploy-badges%2Fdate-badge.json
[badge-latest-build-date-url]: https://github.com/mserajnik?tab=packages&repo_name=tortoise-deploy
[badge-latest-tortoise-build]: https://img.shields.io/endpoint?url=https%3A%2F%2Fscripts.mser.at%2Ftortoise-deploy-badges%2Fbuild-badge.json
[badge-latest-tortoise-build-url]: https://scripts.mser.at/tortoise-deploy-latest-build/
[badge-lint-status]: https://github.com/mserajnik/tortoise-deploy/actions/workflows/lint.yaml/badge.svg
[badge-lint-status-url]: https://github.com/mserajnik/tortoise-deploy/actions/workflows/lint.yaml
[claude-code]: https://www.anthropic.com/product/claude-code
[cmangos]: https://github.com/cmangos
[cmangos-deploy]: https://github.com/mserajnik/cmangos-deploy
[codex]: https://openai.com/codex
[docker]: https://docs.docker.com/get-docker/
[docker-compose]: https://docs.docker.com/compose/install/
[issues]: https://github.com/mserajnik/tortoise-deploy/issues
[license-agpl-3.0-only]: LICENSES/AGPL-3.0-only.txt
[license-agpl-3.0-or-later]: LICENSES/AGPL-3.0-or-later.txt
[license-cc-by-sa-4.0]: LICENSES/CC-BY-SA-4.0.txt
[license-cc0-1.0]: LICENSES/CC0-1.0.txt
[license-gpl-2.0-only]: LICENSES/GPL-2.0-only.txt
[license-gpl-2.0-or-later]: LICENSES/GPL-2.0-or-later.txt
[maintainer]: https://github.com/mserajnik
[pull-requests]: https://github.com/mserajnik/tortoise-deploy/pulls
[reuse-spec]: https://reuse.software/spec/
[tortoise-wow]: https://github.com/tortoise-wow/tortoise-wow
[tortoisebots]: https://github.com/Sagiroth/TortoiseBots
[vmangos]: https://github.com/vmangos/core
[vmangos-deploy]: https://github.com/mserajnik/vmangos-deploy
