FROM alpine:3.20

LABEL org.opencontainers.image.title="EasyPhone Orchestrator Bundle" \
      org.opencontainers.image.description="Arquivos do orquestrador EasyPhone para instalação on-premise" \
      org.opencontainers.image.source="https://github.com/nncs-easyphone/easyphone-orquestrator" \
      org.opencontainers.image.licenses="Proprietary"

WORKDIR /bundle

COPY --chown=0:0 .env.example docker-compose.yml VERSION README.md whitelist.conf.example /bundle/
COPY --chown=0:0 *.sh /bundle/
COPY --chown=0:0 scripts /bundle/scripts
COPY --chown=0:0 systemd /bundle/systemd
COPY --chown=0:0 traefik /bundle/traefik
COPY --chown=0:0 coturn /bundle/coturn
COPY --chown=0:0 host-info /bundle/host-info
COPY --chown=0:0 docker-proxy /bundle/docker-proxy
COPY --chown=0:0 doc /bundle/doc

RUN find /bundle -type f -name '*.sh' -exec chmod 755 {} + \
    && find /bundle -type f ! -name manifest.txt | sed 's|^/bundle/||' | sort > /bundle/manifest.txt \
    && chmod 644 /bundle/manifest.txt \
    && test -f /bundle/scripts/init.sh \
    && test -f /bundle/scripts/run.sh \
    && test -f /bundle/scripts/update.sh \
    && test -f /bundle/docker-compose.yml

CMD ["true"]
