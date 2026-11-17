# local_git_server

A git server for one computer, whose storage is a USB stick. It serves `git://127.0.0.1/<name>.git`, with no password, to that computer only. Pushes land on the stick; the computer's own disk never stores a copy of the server's data.

It's built not to trust the hardware:
- The stick may be missing at boot, pulled out mid-push, or come back with a damaged file system.
- In every one of those cases the server either works correctly or refuses loudly.
- It never silently writes somewhere else.

## What it is

| Part | What it does |
|---|---|
| `srv-gitstick.mount` | Mounts the stick's ext4, by file-system UUID only, at `/srv/gitstick`. The options are `rw,noatime,nodev,nosuid,noexec,errors=remount-ro`. fsck runs before every mount. The mount is pulled in by the stick's device (at boot or when plugged in), and it's bound to that device, so it goes away when the stick does. |
| `/srv/gitstick` underneath | The empty mount point is immutable (`chattr +i`): nothing, not even root, can write there while the stick is absent. |
| `gitstick.service` | Runs `git daemon` in Docker. It's bound to the mount, so it stops when the stick goes away and starts again when it comes back. Before starting, it checks that this UUID's ext4 is what's mounted, read-write, and clears what interrupted pushes left behind. |
| Docker image `local/gitstick:2` | Alpine 3.24.4, pinned by digest, with `git` and `git-daemon` only. |
| `gitstick-cleanup.timer` | Daily. Removes quarantine folders of interrupted pushes that nothing has written to for 24 hours. |
| `99-gitstick.rules` | Hides the stick from udisks/GNOME, so the desktop never mounts it elsewhere or offers to eject it. Keeps its USB power saving off. |

### The server

- **Network:** listens on `127.0.0.1:9418` only, using the host network with `--listen=127.0.0.1`: a plain loopback socket, with no NAT or docker-proxy.
- **Container:** runs as uid 1000, with `--cap-drop=ALL`, `no-new-privileges` and a read-only root. It never pulls images, and its Docker `--mount` fails rather than creating a missing folder.
- **Paths:** serves only `/srv/gitstick/git/*.git`; user paths and paths outside that folder are refused.

### Git policy (`image/gitconfig`)

- **Durability:** `core.fsync=all`, so when a push reports success, it is on the stick.
- **Checks:** every pushed object is checked (`receive.fsckObjects`).
- **Refusals:** force-pushes and branch deletions are refused, so history on the stick only grows.
- **Hooks:** none run.
- **History:** reflogs are kept forever. Pruning stays at git's default of 2 weeks, and with those refusals it can only ever remove debris from failed pushes.

### Interrupted pushes

`git receive-pack` keeps a push's incoming data in `objects/tmp_objdir-incoming-*` until the whole push has arrived and been checked. Only then does it move the data in and update the branch. So an interrupted push never changes a branch. But when the client dies mid-push, git leaves that folder behind; this was seen with git 2.54 and with git 2.43, so it isn't specific to this server. After a power cut or a pulled stick, nothing could clean up on any server. `gitstick-cleanup` handles both cases, so nothing needs to be done by hand.

## Requirements

- Linux with systemd 245 or later, Docker, `util-linux`, `e2fsprogs` and `gdisk` (for `sgdisk`). Tested on Ubuntu 24.04.
- The user who owns the repositories has uid/gid 1000 (the first user on Ubuntu).
- Root, or membership of the `docker` group. `./as-root` uses sudo if it works without a password; otherwise it uses Docker to enter the host's namespaces.

## Setup

```
git clone https://github.com/BigBIueWhale/local_git_server.git && cd local_git_server
cp config.example.env config.env      # set STICK_SERIAL (and STICK_NAME)
./as-root ./format-stick              # ERASES the stick; writes its new UUID into config.env
./as-root ./install                   # installs, enables and starts everything
./add-repo myproject                  # creates myproject.git on the stick
```

If the stick is already ext4, put its UUID in `config.env` and skip `format-stick`.

In a working copy:

```
git remote add origin git://127.0.0.1/myproject.git
git push -u origin master
```

## Keeping it right

- `./as-root ./install --check` changes nothing. It shows, line by line, how this machine differs from the repository (exit status 0 = identical).
- `./as-root ./install` again applies only the differences, and restarts the server only if its unit, image or cleanup script changed. `--rebuild-image` rebuilds without Docker's cache, to pick up Alpine's current git package.
- `./as-root ./run-tests` tests the live installation end to end. Use `--no-replug` to skip the simulated unplug.
  - **Loopback only:** the server is reachable on 127.0.0.1 and nowhere else.
  - **Paths:** paths outside the repositories are refused.
  - **Interrupted pushes:** a push killed mid-transfer changes no branch, and its leftovers are removed.
  - **Missing stick:** with the stick unmounted, or unplugged in software, the server is down and nothing can be written in the stick's place.
  - **Replug:** plugging the stick back in brings everything back by itself.
  - **Read-back:** every repository reads back clean with `git fsck --full --strict`.

## Installed files

- `/opt/gitstick/`: `Dockerfile`, `gitconfig`, `gitstick-cleanup`, this `README.md`, and a copy of `config.env`.
- `/etc/systemd/system/`: `srv-gitstick.mount`, `gitstick.service`, `gitstick-cleanup.service`, `gitstick-cleanup.timer`.
- `/etc/udev/rules.d/99-gitstick.rules`.

## Day to day

- **Status:** `systemctl status srv-gitstick.mount gitstick.service`
- **Logs:** `journalctl -u gitstick.service -u srv-gitstick.mount`
- **Stick missing:** pushes fail with "connection refused". Plug it in, and the server is back within seconds.
- **After a file-system error:** the stick turns read-only and pushes fail loudly. At the next mount, fsck repairs what it safely can; if it can't, the stick isn't mounted at all.

## If the stick dies

Every working copy still holds its full history. To start over on a new stick:
1. Set its serial in `config.env`.
2. Run `./as-root ./format-stick`, then `./as-root ./install`.
3. Run `./add-repo` for each repository.
4. Push from each working copy.

## Security model

- **Not reachable from the network.** Packets for 127.0.0.1 that arrive on another interface are dropped by the kernel, as long as `route_localnet` stays 0.
- **Anything running on this computer can read and push.** That's by design: there's no authentication on localhost.
- **Pushes can't destroy history.** They can't rewrite or delete it.
