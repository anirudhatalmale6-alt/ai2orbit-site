# Dockerfile - the AI2ORBIT site on Cloud Run
# Copyright (c) AI2ORBIT Co. 2026
#
# The whole site is four files, so the container is a web server with those four files in
# it and nothing else. No build step, no node_modules, no framework: whatever is in this
# folder is exactly what gets served.
#
# THE ONE RULE CLOUD RUN ENFORCES is that the container listens on the port named in the
# PORT environment variable, on 0.0.0.0, and answers before the start timeout. Nearly every
# failed Cloud Run deploy is that single sentence - the log line reads "container failed to
# start and listen on the port defined by the PORT environment variable". check-container.sh
# in this folder runs the image on a NON-default port for exactly that reason: a container
# hard-wired to 8080 passes every casual test and then fails on the platform.

FROM docker.io/library/nginx:1.27-alpine

# Only used when the image is run by hand. Cloud Run overrides it, and 8080 is what it sets.
ENV PORT=8080

# The stock nginx entrypoint runs envsubst over /etc/nginx/templates before starting, so
# ${PORT} below becomes a number without any script of ours. The filter pins the
# substitution to that one name: without it every ${...} in the file is fair game, and a
# variable meant for nginx itself would be replaced with an empty string at build time.
ENV NGINX_ENVSUBST_FILTER=^PORT$

COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
# Not a template - it is included verbatim by the server block and by every location that
# sets a header of its own. The note at the top of it says why that repetition is required.
COPY nginx/headers.conf          /etc/nginx/headers.conf
COPY index.html /usr/share/nginx/html/index.html
COPY img/       /usr/share/nginx/html/img/

# Documentation only - Cloud Run ignores EXPOSE and goes by PORT.
EXPOSE 8080
