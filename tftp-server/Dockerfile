FROM alpine:latest

RUN apk update && \
    apk add --no-cache tftp-hpa

RUN mkdir -p /var/tftpboot && \
    chmod 777 /var/tftpboot

EXPOSE 69/udp

CMD ["sh", "-c", ". /etc/default/tftpd-hpa && in.tftpd --foreground $TFTP_OPTIONS $TFTP_DIRECTORY"]

