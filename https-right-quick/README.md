## What this image does

Creates a python web server container secured by TLS.  This container is meant for ***very temporary*** use as a way to securely retrieve files from a remote device.

> [!Note]
> Docker is required.

Example use-case: You have SSH key files you want to copy to your phone but don't want to mess with moving keys to SD cards or some other transfer technique.

***

## How to Use

1. Clone this repo to the computer from which you want to copy files.
2. Change to the repo directory.
3. Edit hidden `.env` with a username and password of your choosing.
4. Place files you want to access/download in `www-data/`.
5. Run `docker compose up -d`.
6. Browse to this device via https to the device IP on port 9443.  Example: `https://192.168.44.200:9443`
   * Accept the security warnings about the certificate not being trusted.  See the note below for more info.

***

## Shutting Down
1. Run `docker compose down`
2. Delete the image if you are truly done. Probably: `docker image rm python-www-server`

***

## Notes

Keys are generated during image creation.  You can edit `-subj "/C=US/ST=VA/L=VaBeach/O=DojoLabs/OU=Training/CN=dojolabs"` in the `Dockerfile` if you want to have different values associated with your certificate.  I recommend doing this as it allows you to some measure of "poor man's" validation of the certificate (certificate is self-signed).
