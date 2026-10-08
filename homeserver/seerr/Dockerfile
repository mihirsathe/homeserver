# Seerr, with one local patch: a Plex Watchlist add requests ONE season.
#
# Built by compose (`build:` on the seerr service) FROM upstream's :latest.
# update-stack.sh runs `compose build --pull seerr` every month so the base
# is re-pulled and the patch re-applied on top of each release; if upstream
# moves the code the patch anchors on, the build fails and the previous
# patched image keeps running. The patch itself, and why it exists, is in
# patch-watchlist-one-season.js next to this file.
FROM ghcr.io/seerr-team/seerr:latest

USER root
COPY patch-watchlist-one-season.js /opt/homeserver/patch-watchlist-one-season.js
RUN node /opt/homeserver/patch-watchlist-one-season.js /app/dist/entity/MediaRequest.js \
 && node --check /app/dist/entity/MediaRequest.js
# Back to the image's own user; compose pins user: ${PUID}:${PGID} on top anyway.
USER node:node
