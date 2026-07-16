import-lorawan-devices:
	docker compose run --rm --entrypoint sh --user root chirpstack -c '\
		set -e && \
		apk add --no-cache git && \
		git clone https://github.com/chirpstack/lorawan-device-profiles /tmp/lorawan-device-profiles && \
		chirpstack -c /etc/chirpstack import-device-profiles -d /tmp/lorawan-device-profiles && \
		rm -rf /tmp/lorawan-device-profiles'
