FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    apt-transport-https \
    gnupg \
    lsb-release \
    software-properties-common \
    unixodbc-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - \
    && curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list > /etc/apt/sources.list.d/mssql-release.list

RUN apt-get update \
    && ACCEPT_EULA=Y apt-get install -y mssql-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="$PATH:/opt/mssql-tools/bin"

WORKDIR /app

COPY mssql_dumps.sh /app/

WORKDIR /app

RUN chmod +x /app/mssql_dumps.sh

RUN mkdir -p /app/output

VOLUME /app/output

ENTRYPOINT ["bash", "-c"]

CMD ["exec ./mssql_dumps.sh"]

