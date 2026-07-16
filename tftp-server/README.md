# A simple, containerized, tftp-server

For those rare occasions you need a TFTP server.

## Usage

1. Clone this repo to the computer you want to be the tftp server.

```shell
git clone https://github.com/itdojo/tftp-server.git
```

2.  Place files you wish to be accessible via tftp in `./files` folder.
3.  Run a tftp daemon container.

```shell
docker compose up -d
```

3.  From your client, upload/download files as desired.  See [**Client Syntax**](#client-syntax).
4.  Stop and remove the container when done.

```shell
docker compose down
```

***

## Setting TFTP Variables

* You can modify TFTP variables by editing `./config/tftp-hpa.conf`.  For general usage, you should not need to modify any settings.  Refer to the [tftp-hpa manpage](https://manpages.debian.org/testing/tftpd-hpa/tftpd.8.en.html) for variable options.

***

## Client Syntax

For MacOS and Debian/Ubuntu

- [ ] Install `tftp-hpa` on client (or whatever tftp client you prefer).  TFTP client is built-in on MacOS.

```shell
# Debian/Ubuntu
sudo apt update && sudo apt install -y tftp-hpa
```

***

### Downloading

Syntax:

```shell
# Connet to tftp server
tftp <server-ip>

# Get single file
get <filename>

# Get <remotefile> file, rename to <localfile>
get <remotefile> <localfile>

# Get multiple files
get file1 file2 file3.. fileN

# Exit
quit
```

Or, all on one line:

```shell
tftp -v <server-ip> -c get <filename>
```

***

### Uploading

Syntax:

```shell
# Connect to tftp server
tftp <server-ip>

# Upload a single file
put <filename>

# Upload <localfile>, rename to <remotefile>
put <localfile> <remotefile>

# Upload multiple files
put file1 file2 file3...

# Exit
quit
```

Or, all on one line:

```shell
tftp -v <server-ip> -c put <filename>
```

***

## TFTP Mode

If you are using Windows you might need to specify the mode (`-m mode`) in order to preserve carriage returns, etc. for text files.  
You will know this if your uploaded/downloaded file are corrupted or lose their basic formatting.  
If that happens, visit https://manpages.debian.org/bookworm/tftp-hpa/tftp.1.en.html for additional info.

