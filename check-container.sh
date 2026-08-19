#!/bin/sh
# check-container.sh - build the image, run it, and prove it satisfies Cloud Run
# Copyright (c) AI2ORBIT Co. 2026
#
# Every assertion here is about the CONTAINER, not about the folder. A static site that
# opens correctly from a file manager tells you nothing about whether the platform will
# start it.
#
# The check that matters most is the port. Cloud Run picks the port, hands it over in
# $PORT, and kills the revision if nothing answers there. So this script deliberately runs
# the image on a port that is NOT 8080: an image with the port hard-wired passes every
# casual test and then fails on the platform with a log line about the PORT variable.
#
# Usage:  sh check-container.sh          (needs podman or docker, and curl)

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
IMG=ai2orbit-site-check
CPORT=9137           # deliberately not 8080
HPORT=8137
NAME=ai2orbit-site-check-run
PASS=0
FAIL=0

if command -v docker >/dev/null 2>&1; then OCI=docker
elif command -v podman >/dev/null 2>&1; then OCI=podman
else echo "no docker and no podman on this machine"; exit 2; fi

chk() {  # chk <1|0> <description>
  if [ "$1" = "1" ]; then PASS=$((PASS+1)); echo "  ok    $2"
  else FAIL=$((FAIL+1)); echo "  FAIL  $2"; fi
}

cleanup() { $OCI rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

echo "container checks - $OCI"
echo

cleanup
if $OCI build -t "$IMG" "$DIR" >"$DIR/build.log" 2>&1; then
  chk 1 "the image builds from the Dockerfile in this folder"
else
  chk 0 "the image builds from the Dockerfile in this folder"
  tail -20 "$DIR/build.log"; exit 1
fi

# PORT is passed the way Cloud Run passes it, and it is not the default.
$OCI run -d --name "$NAME" -e PORT=$CPORT -p $HPORT:$CPORT "$IMG" >/dev/null 2>&1
up=0
i=0
while [ $i -lt 30 ]; do
  if curl -fsS -m 2 "http://127.0.0.1:$HPORT/healthz" >/dev/null 2>&1; then up=1; break; fi
  i=$((i+1)); sleep 1
done
chk "$up" "it starts and answers on the port given in PORT ($CPORT), not on 8080"
if [ "$up" != "1" ]; then $OCI logs "$NAME" 2>&1 | tail -20; exit 1; fi

B="http://127.0.0.1:$HPORT"

# --- the port substitution, read out of the running server ---------------------------
conf=$($OCI exec "$NAME" nginx -T 2>/dev/null)
chk "$(echo "$conf" | grep -q "listen  *$CPORT;" && echo 1 || echo 0)" \
    "the running config listens on $CPORT, so \${PORT} really was substituted"
# If envsubst were left unfiltered it would replace every $name in the template, including
# nginx's own variables, and try_files would silently lose its argument.
chk "$(echo "$conf" | grep -q 'try_files \$uri' && echo 1 || echo 0)" \
    "and nginx's own \$uri survived the substitution untouched"

# --- what it serves -------------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' "$B/")
chk "$([ "$code" = "200" ] && echo 1 || echo 0)" "GET / answers 200"

# Byte for byte the file on disk, not a re-rendered copy of it.
a=$(curl -s -H 'Accept-Encoding: identity' "$B/" | md5sum | cut -d' ' -f1)
b=$(md5sum "$DIR/index.html" | cut -d' ' -f1)
chk "$([ "$a" = "$b" ] && echo 1 || echo 0)" "and the bytes are identical to index.html on disk"

chk "$(curl -s "$B/" | grep -q '<title>AI2ORBIT - NetSwitch Industry</title>' && echo 1 || echo 0)" \
    "the page that comes back is the AI2ORBIT page"

for f in hmi menu football; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$B/img/$f.png")
  len=$(curl -s -o /dev/null -w '%{size_download}' "$B/img/$f.png")
  disk=$(wc -c < "$DIR/img/$f.png")
  ct=$(curl -s -o /dev/null -w '%{content_type}' "$B/img/$f.png")
  chk "$([ "$code" = "200" ] && [ "$len" = "$disk" ] && [ "$ct" = "image/png" ] && echo 1 || echo 0)" \
      "img/$f.png is served whole ($disk bytes) as image/png"
done

chk "$([ "$(curl -s "$B/healthz")" = "ok" ] && echo 1 || echo 0)" "/healthz says ok"
chk "$([ "$(curl -s -o /dev/null -w '%{http_code}' "$B/nothing-here")" = "404" ] && echo 1 || echo 0)" \
    "a path that does not exist gets 404, not the page"

# --- headers ---------------------------------------------------------------------------
H=$(curl -sI "$B/")
chk "$(echo "$H" | grep -qi "default-src 'none'" && echo 1 || echo 0)" \
    "the content security policy is sent, and its default is to allow nothing"
chk "$(echo "$H" | grep -qi "img-src 'self'" && echo 1 || echo 0)" \
    "images may come from this host and nowhere else"
# The embed route has to survive the policy, or a Google Sites page shows an empty box.
chk "$(echo "$H" | grep -qi 'frame-ancestors.*sites.google.com' && echo 1 || echo 0)" \
    "and the page may still be embedded in a Google Sites page"
chk "$(echo "$H" | grep -qi 'x-content-type-options: nosniff' && echo 1 || echo 0)" \
    "the browser is told not to guess content types"
chk "$(echo "$H" | grep -qi 'cache-control: no-cache' && echo 1 || echo 0)" \
    "the page itself is not cached, so a redeploy is seen at once"
chk "$(curl -sI "$B/img/hmi.png" | grep -qi 'cache-control: public, max-age=3600' && echo 1 || echo 0)" \
    "the screenshots are cached for an hour"
# THE HEADER TRAP. nginx drops every inherited add_header the moment a block sets one of
# its own, so the two blocks that set their own caching are exactly the two that lose the
# policy. Both levels are asserted, or the fix rots the first time somebody edits caching.
chk "$(curl -sI "$B/img/hmi.png" | grep -qi "default-src 'none'" && echo 1 || echo 0)" \
    "and an image still carries the policy, though its block sets its own cache header"

# --- compression -----------------------------------------------------------------------
chk "$(curl -sI -H 'Accept-Encoding: gzip' "$B/" | grep -qi 'content-encoding: gzip' && echo 1 || echo 0)" \
    "the page is compressed when the browser asks for it"
chk "$(curl -sI -H 'Accept-Encoding: gzip' "$B/img/hmi.png" | grep -qi 'content-encoding: gzip' && echo 0 || echo 1)" \
    "and the png is not, because compressing it would only make it bigger"

# --- the claim the page makes about itself ----------------------------------------------
# Anything fetched from another host would break the "one file, no external requests"
# property. Anchor links to another site are not fetches and are allowed; src= and
# rel=stylesheet are.
ext=$(grep -oE '(src|href)="https?://[^"]+"' "$DIR/index.html" | grep -v '^href=' | wc -l)
chk "$([ "$ext" = "0" ] && echo 1 || echo 0)" \
    "nothing on the page is loaded from another host ($ext external subresources)"
chk "$(grep -q '<script' "$DIR/index.html" && echo 0 || echo 1)" "there is no script on the page at all"

# --- the log ------------------------------------------------------------------------------
lg=$($OCI logs "$NAME" 2>&1)
chk "$(echo "$lg" | grep -qi '\[emerg\]\|\[alert\]' && echo 0 || echo 1)" \
    "nginx logged no emergency or alert while starting"

# --- the build context ----------------------------------------------------------------------
chk "$(grep -q '^\.git/' "$DIR/.gcloudignore" && echo 1 || echo 0)" \
    "the git history is kept out of the build context"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
