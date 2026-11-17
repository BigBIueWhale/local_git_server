# Local git server: git daemon on 127.0.0.1:9418.
# The repositories live on the USB stick (see README.md); this image holds no data.
# Base pinned by digest (Alpine 3.24.4, pulled 17/11/2026).
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# git + git-daemon only. A fixed user, uid/gid 1000, the same as the host's `user`,
# so the files on the stick belong to the host user too.
RUN apk add --no-cache git git-daemon \
 && addgroup -g 1000 git \
 && adduser -D -H -u 1000 -G git -h /nonexistent -s /sbin/nologin git

# Server-wide git policy: fsync everything, check every pushed object,
# no force-push / branch deletion, no hooks, keep all reflogs and objects.
COPY gitconfig /etc/gitconfig

USER 1000:1000
ENV HOME=/nonexistent

# Listens on 127.0.0.1 only. Serves repositories under /srv/git (the stick's git/ folder);
# no user paths. Push (receive-pack) is enabled, with no authentication: localhost only.
ENTRYPOINT ["git", "daemon", \
  "--listen=127.0.0.1", "--port=9418", "--reuseaddr", \
  "--base-path=/srv/git", "--export-all", \
  "--enable=receive-pack", \
  "--init-timeout=30", "--max-connections=16", \
  "--informative-errors", "--log-destination=stderr", "--verbose", \
  "/srv/git"]
