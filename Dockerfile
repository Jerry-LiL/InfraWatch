# Client image for the toolkit. The database itself is docker-compose.yml
# (or a host Postgres). pg_dump here matches the Postgres 16 server.
FROM postgres:16

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/infrawatch/var/backups \
                /opt/infrawatch/var/log \
                /opt/infrawatch/var/state

COPY bin/ /opt/infrawatch/bin/
COPY config/infrawatch.conf /opt/infrawatch/config/infrawatch.conf
COPY sql/ /opt/infrawatch/sql/
COPY docs/ /opt/infrawatch/docs/

RUN chmod 755 /opt/infrawatch/bin/infrawatch \
    && chown -R postgres:postgres /opt/infrawatch

USER postgres
WORKDIR /opt/infrawatch
ENTRYPOINT ["/opt/infrawatch/bin/infrawatch"]
CMD ["health"]
