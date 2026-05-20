FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
        bzip2 \
        xz-utils \
        qemu-system-x86 \
        qemu-utils \
        ovmf \
        novnc \
        websockify \
        procps \
        iproute2 \
        net-tools \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY docker/steamos-entrypoint.sh /usr/local/bin/steamos-entrypoint
RUN chmod 0755 /usr/local/bin/steamos-entrypoint

WORKDIR /home/container

STOPSIGNAL SIGINT

ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/usr/local/bin/steamos-entrypoint"]
CMD ["start"]
