# Usage

With tortoise-deploy, you choose Docker images for a variant, extract the
client data, run Tortoise-WoW with Docker Compose, and update it to get the
latest Tortoise-WoW changes. The sections below describe each step in detail,
and the tasks around them, such as backups. The
[Docker Compose reference](compose.md) explains the settings.

## Choosing images

### Variants

tortoise-deploy builds three variants from the same Tortoise-WoW commit, the
tip of the `main` branch. Each variant contains the one before it.

| Variant        | Server image                                     | Database image                                     |
| -------------- | ------------------------------------------------ | -------------------------------------------------- |
| `base`         | `ghcr.io/mserajnik/tortoise-server:base`         | `ghcr.io/mserajnik/tortoise-database:base`         |
| `modules`      | `ghcr.io/mserajnik/tortoise-server:modules`      | `ghcr.io/mserajnik/tortoise-database:modules`      |
| `modules-bots` | `ghcr.io/mserajnik/tortoise-server:modules-bots` | `ghcr.io/mserajnik/tortoise-database:modules-bots` |

`base` contains Tortoise-WoW alone. `modules` adds a curated set of modules
from [Tortoise-WoW's module system][tortoise-wow-modules]:

| Module                               | Enabled by default |
| ------------------------------------ | ------------------ |
| [tw-mod-autoscale][tw-mod-autoscale] | No                 |
| [tw-mod-leech][tw-mod-leech]         | No                 |

`modules-bots` adds [TortoiseBots][tortoisebots] to that set, a Playerbot
module. It can add computer-controlled players to the world that level, quest,
group up, run dungeons, and trade in the auction house.

| Module                       | Enabled by default |
| ---------------------------- | ------------------ |
| [TortoiseBots][tortoisebots] | No                 |

Each module has its own configuration file under `config/modules/` or
`config/modules-bots/`. The server reads them after `config/mangosd.conf`, so
an option in a module's file overrides the same one in your `mangosd.conf`.
TortoiseBots reads two files: `tortoise_bots.conf` holds the module's own
options, which work as they are, and `aiplayerbot.conf` holds the bot behavior.
[TortoiseBots' documentation][tortoisebots-docs] describes what the module can
do and how to set it up. tortoise-deploy leaves out the optional TortoiseBots
tools, such as the observability dashboard.

A missing module configuration file stops `mangosd` during startup with the
file's name, and Docker restarts it into the same failure. When a variant gains
a module, you have to copy one more file, and the
[breaking changes documentation](breaking-changes.md) lists every such
addition.

> [!WARNING]
> Switching an existing setup to another variant is untested and unsupported,
> and it may stop working at any time. If you try it anyway: `base` and
> `modules` use the same database today, so a switch between them should work
> in both directions. A switch from `base` or `modules` to `modules-bots`
> should work as well. `modules-bots` adds its own migrations to the databases,
> so the way back needs manual database edits, if it works at all.

### Pinning a specific Tortoise-WoW commit

Each image also has a tag with its variant and the full Tortoise-WoW commit it
contains, such as
`ghcr.io/mserajnik/tortoise-server:base-5fafe43b576116c3aecde435c41c87a47864f943`.
Use such a tag to pin your setup to a specific commit. You have to give the
server and the database image the same commit, so the code and the data match.
The databases apply new migrations on start, so an image older than the ones
you ran before cannot work with them.

Since the Docker images are generally built only once a day, there is likely no
build for every single Tortoise-WoW commit. Older images are deleted
automatically after 14 days, so do not rely on the registry keeping a specific
image after you first pulled it. If you need images based on a specific
Tortoise-WoW commit, you can build them yourself. The registry lists the
current [server images][image-tortoise-server-versions] and
[database images][image-tortoise-database-versions].

## Client data

The server needs data extracted from the game client for handling movement and
line of sight.

> [!WARNING]
> Tortoise-WoW supports exactly one client: an unmodified copy of the final
> Turtle WoW client `1.18.1.7272` with the 2026-04-12 hotfixes. Data from
> another version causes gameplay problems that look like Tortoise-WoW bugs.
> tortoise-deploy stops an extraction from another client version, and the
> server refuses to start with such data.

### Extracting the client data

Copy the contents of your client directory into `storage/mangosd/client-data/`.
Then, to extract the data, run:

```sh
docker compose run --rm extract-client-data
```

The command runs the image of the `mangosd` service as its user (see the
[`extract-client-data` section](compose.md#extract-client-data)).

The extraction can take many hours, and it prints some notices and errors while
it runs that are normal as long as the command does not end with an error. It
checks the client version within the first minutes, before the long steps, and
stops for an unsupported client without touching
`storage/mangosd/extracted-data/`. The data ends up in
`storage/mangosd/extracted-data/`.

If you already have extracted data from another source, put it into
`storage/mangosd/extracted-data/` and verify it, as the
[verifying extracted data section](#verifying-extracted-data) describes. You
can then skip the extraction.

To extract again later, for example after Tortoise-WoW improves the movement
data, run the same command. It asks before it overwrites the old data. To skip
the question, add `--force` at the end of the command.

### Verifying extracted data

An extraction that completed checks its own data. For data you extracted
earlier or got elsewhere, run:

```sh
docker compose run --rm verify-client-data
```

### Warden and anticheat

The images contain no anticheat. Warden depends on module files that
Tortoise-WoW does not distribute and that are not maintained for its client, so
it cannot work reliably. The movement checks may come to a later image, once an
upstream problem that affects them is fixed.

## Running Tortoise-WoW

To start Tortoise-WoW, run:

```sh
docker compose up -d
```

The first start takes longer, because it creates the databases.

> [!WARNING]
> Do not interrupt the first start. If it stops early and the next start of the
> `database` service fails, remove the database volume with
> `docker compose down -v`, and start again.

To follow the server output, run:

```sh
docker compose logs -f mangosd
```

The server is ready when it prints `World server is up and running!`.

To stop Tortoise-WoW, run:

```sh
docker compose down
```

## Accounts

To create an account, attach to the server console once the server is ready:

```sh
docker compose attach mangosd
```

Then create the account and give it an account level:

```text
account create <account-name> <password>
account set gmlevel <account-name> <level>
```

| Level | Type                                                     |
| ----- | -------------------------------------------------------- |
| `0`   | Player                                                   |
| `1`   | Observer                                                 |
| `2`   | Moderator                                                |
| `3`   | Developer                                                |
| `4`   | Administrator                                            |
| `5`   | SigmaChad, Tortoise-WoW's name for a super administrator |

To leave the console again, press <kbd>Ctrl</kbd>+<kbd>P</kbd> and then
<kbd>Ctrl</kbd>+<kbd>Q</kbd>. You can then log in with the account you created.

> [!NOTE]
> A level above `0` grants Game Master permissions, and characters on such an
> account behave like Game Master characters: they start at level 60 on GM
> Island, among other things. The `GM.*` options in your `config/mangosd.conf`
> adjust some of it. These characters are also invulnerable to damage.
> `.god off` turns that off until the next login, and there is no option to
> turn it off permanently. For regular play, use a level `0` account.

## Connecting a client

The game client reads the address of the login server from `realmlist.wtf` in
the client directory. To play on the host itself, set it to:

```text
set realmlist 127.0.0.1
```

To connect from another machine, use the host's LAN address, WAN address, or
domain name instead. Set `TORTOISE_REALMLIST_ADDRESS` in your `compose.yaml` to
the same address, because the client receives the address of the world server
from the realm list.

## Updating

To update, pull the new images and check them:

```sh
docker compose pull
docker compose run --rm check-deploy-version
```

When the new images need configuration adjustments due to a
[breaking change](breaking-changes.md), the check fails and names the version
they expect. Make those adjustments first. The check reads
`TORTOISE_DEPLOY_VERSION` of `mangosd`, so keep the number the same in every
service.

If the check passes and prints that the variable matches, re-create the
containers:

```sh
docker compose up -d
```

If you pinned your setup to a specific commit, the update only takes effect
once you set newer tags.

On the first start after an update, `mangosd` applies the new migrations to the
databases.

### Updating your clone

Update your clone of this repository regularly with `git pull`, and always
before you apply a breaking change, so you have the updated example Compose
files to compare with.

> [!IMPORTANT]
> The relaunch replaced the history of this repository, so `git pull` fails in
> a clone from before 2026-10-04. To update such a clone once, run `git fetch`
> and then `git reset --hard origin/master` in it. That keeps your
> `compose.yaml`, `config/`, and `storage/`, which Git ignores, but discards
> any edit you made to the repository's own files. Afterwards, `git pull` works
> again.

Most other changes are maintenance or new Tortoise-WoW options that you may
want in your configuration.

## Migration edits

Sometimes, upstream edits a migration that your databases have already applied.
The server cannot apply such a change again, so tortoise-deploy detects these
edits and acts on them.

- For the world database, the `database` service re-creates it from the new
  image. Changes you made directly in the world database are lost, such as your
  own NPCs or `npc_vendor` edits. Keep such changes as
  [custom SQL](#custom-sql), which the database runs again after the
  re-creation.
- A database with player data cannot be re-created. For those, the start halts
  and asks you to apply the change by hand, as the next section describes.

The [`database` section](compose.md#database) of the Docker Compose reference
describes the two variables that control this.

### Applying changes by hand

When the start halts, the `database` service prints the affected databases and
the link to each upstream commit. `realmd` and `mangosd` wait for the database,
so `docker compose up -d` keeps waiting too. Read the message from a second
terminal:

```sh
docker compose logs database
```

The container waits as long as you need. To resolve the halt:

1. Open each linked commit and read its changes to the SQL files.
2. Apply the same changes to each affected database, with the name in
   parentheses in the message. To open a database, run:

   ```sh
   docker compose exec database mariadb -u root -p <database>
   ```

   The password is `MARIADB_ROOT_PASSWORD` from your `compose.yaml`.
3. Once you have applied every change, confirm:

   ```sh
   docker compose exec database tortoise-confirm-changes
   ```

The start then records the commits as applied and continues. To give up on the
start, run `docker compose down`.

> [!WARNING]
> The confirmation marks the listed commits as applied without checking your
> database. If your change is wrong or incomplete, the database stays
> inconsistent, and Tortoise-WoW may fail to start. Matching what the commits
> do is your responsibility.

## Custom SQL

To make your own changes to the world database, put them into `.sql` files in
`storage/database/custom-sql/`. The `database` service runs every file there in
alphabetical order on every start, and after a re-creation of the world
database too. So the statements have to be idempotent: running them twice has
to give the same result as running them once.

## Backups

Back up the databases regularly, especially before updating. The
`database-backup` service in your `compose.yaml` does it daily once you
uncomment it (see the
[`database-backup` section](compose.md#database-backup-optional)).

> [!NOTE]
> The Compose file leaves the world and logs databases out of the
> `database-backup` service, because most personal setups likely do not care
> enough about their contents to accept much larger backups. Apart from changes
> you make to it yourself, the image can re-create the world database. The logs
> database stores what the servers log to it. To back up either, add `tw_world`
> or `tw_logs` to `DB_DUMP_INCLUDE`.

To create a backup right away, run:

```sh
docker compose run --rm -e DB_DUMP_CRON= -e DB_DUMP_ONCE=true database-backup
```

The empty `DB_DUMP_CRON` is needed, because the service cannot combine a
schedule with a one-off run.

### Restoring a backup

A restore drops and re-creates the tables of each database in the backup. To
restore one:

1. Stop the servers, which would otherwise read and write the tables while they
   change:

   ```sh
   docker compose stop realmd mangosd
   ```

2. Restore the backup, with its file name from `storage/database/backups/`:

   ```sh
   docker compose run --rm database-backup restore --target /backup \
     <backup-file>
   ```

3. Restart the database, which writes the realm entry again, then start the
   servers:

   ```sh
   docker compose restart database
   docker compose start realmd mangosd
   ```

   If the backup is older than a migration edit, the restart handles the edit
   again, as the [migration edits section](#migration-edits) describes.

## Database access

Some tasks, such as managing accounts or changing the realm entry, need a
MariaDB client. The `phpmyadmin` service in your `compose.yaml` provides one in
the browser once you uncomment it (see the
[`phpmyadmin` section](compose.md#phpmyadmin-optional)).

### Database security

Do not expose the database to the internet, whether through a port mapping, a
phpMyAdmin instance, or anything else. If you expose it anyway, you are
responsible for securing it. tortoise-deploy does not support such a setup.

> [!CAUTION]
> The `root` user and the user from `MARIADB_USER` have full access to all
> Tortoise-WoW data, from any address.

[image-tortoise-database-versions]: https://github.com/mserajnik/tortoise-deploy/pkgs/container/tortoise-database/versions?filters%5Bversion_type%5D=tagged
[image-tortoise-server-versions]: https://github.com/mserajnik/tortoise-deploy/pkgs/container/tortoise-server/versions?filters%5Bversion_type%5D=tagged
[tortoise-wow-modules]: https://github.com/tortoise-wow/tortoise-wow/blob/main/modules/README.md
[tortoisebots]: https://github.com/Sagiroth/TortoiseBots
[tortoisebots-docs]: https://github.com/Sagiroth/TortoiseBots/tree/main/docs
[tw-mod-autoscale]: https://github.com/Penqle/tw-mod-autoscale
[tw-mod-leech]: https://github.com/Penqle/tw-mod-leech
