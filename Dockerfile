FROM quay.io/wakaba/docker-perl-app-base

ADD .git/ /app/.git/
ADD .gitmodules /app/.gitmodules
ADD Makefile /app/
ADD bin/ /app/bin/
ADD config/ /app/config/
ADD modules/ /app/modules/

RUN cd /app && \
    make deps-docker PMBP_OPTIONS=--execute-system-package-installer && \
    mv har /usr/local/bin/ && \
    rm -fr /app/deps /app/t /app/t_deps /app/local/pmbp && \
    rm -rf /var/lib/apt/lists/*

VOLUME /app/data
