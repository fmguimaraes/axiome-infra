#!/bin/sh
# Demo backend entrypoint. Runs in /app (the bind-mounted primary checkout).
# - Installs node_modules ONLY if genuinely absent (normal start skips it).
# - INSPECT=1  -> start each Nest service under the Node debugger, one port each:
#     gateway 9229  user-service 9230  event-service 9231  organization-service 9232
# - otherwise  -> the plain `npm run dev` (all four services, no debugger).
set -e

[ -x node_modules/.bin/nest ] || npm install

if [ -n "${INSPECT}" ]; then
  exec npx concurrently \
    "nest start gateway --debug=0.0.0.0:9229 --watch" \
    "nest start user-service --debug=0.0.0.0:9230 --watch" \
    "nest start event-service --debug=0.0.0.0:9231 --watch" \
    "nest start organization-service --debug=0.0.0.0:9232 --watch"
else
  exec npm run dev
fi
