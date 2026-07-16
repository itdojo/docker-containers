> [!Warning]
> Kismet config files come from different locations depending on how it is installed.

When installing from **repo**, the Kismet config files are stored in /etc/kismet.
When installing from **source**, the Kismet config files are stored in /usr/local/etc.

---

These differences need to be reflected in your docker compose.yaml file.

## compose.yaml when installing from Kismet source

```yaml
    volumes:
      - ./kismet_config/kismet_site.conf:/usr/local/etc/kismet_site.conf
    environment:
      - KISMET_CONF_DIR=/usr/local/etc
```

---

## compose.yaml when installing from Kismet repo

```yaml
    volumes:
      - ./kismet_config/kismet_site.conf:/usr/local/etc/kismet_site.conf
    environment:
      - KISMET_CONF_DIR=/usr/local/etc
```
