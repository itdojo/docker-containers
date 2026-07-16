#!/bin/sh
mosquitto_pub -h localhost -t health/check -m "ok" -u "$MQTT_USER" -P "$MQTT_PASSWORD"
