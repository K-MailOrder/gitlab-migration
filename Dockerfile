FROM ubuntu:20.04

ENV SOURCE_GITLAB=git.mycompany.com
ENV SOURCE_PATH="gitlab-migration-source"
ENV TARGET_GITLAB=gitlab.com
ENV TARGET_PATH="gitlab-migration-target"
# setting access token here will have precedence over .secrets file and considered insecure
#ENV TARGET_ACCESS_TOKEN=<target_gitlab_access_token>
#ENV SOURCE_ACCESS_TOKEN=<source_gitlab_access_token>

ENV ARCHIVE_AFTER_MIGRATION="no"
ENV ADD_DESCRIPTION="no"
ENV MIGRATE_ARCHIVED_PROJECTS="no"
ENV MIGRATE_GROUP_VARIABLES="no"
ENV MIGRATE_PROJECT_VARIABLES="no"
ENV MIGRATE_BADGES="no"
ENV MIGRATE_HOOKS="no"

RUN adduser migration

RUN apt-get update && \
    apt-get install jq curl -y

COPY --chown=migration:migration .secrets /home/migration/
COPY --chown=migration:migration migrate.sh /home/migration/
RUN chmod +x /home/migration/migrate.sh

USER migration
WORKDIR /home/migration

ENTRYPOINT ["/bin/bash", "/home/migration/migrate.sh", "-D", "FOREGROUND"]