# Geofence drawing tool — Lab 11a
#
# Bake the static Leaflet page into the image rather than bind-mounting it.
# A bind mount would make nginx's worker (uid 101) read the files straight
# off the host, which fails when the project lives under a home directory
# that is not world-traversable (mode 0750 — the modern Ubuntu/Pop!_OS
# default), producing a 403 Forbidden.  Copying the files in sidesteps host
# permissions entirely and keeps nginx running as its normal non-root user.
FROM nginx:alpine
COPY www/ /usr/share/nginx/html/
