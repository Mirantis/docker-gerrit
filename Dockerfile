FROM openjdk:8-jre-alpine

MAINTAINER zsx <thinkernel@gmail.com>

# Overridable defaults
ARG GERRIT_HOME=/var/lib/gerrit
ARG GERRIT_VERSION=2.14.6
ARG PLUGIN_VERSION=bazel-stable-2.14
ARG GERRIT_INIT_ARGS=""
ARG MYSQL_CONNECTOR_VERSION=5.1.21
ARG GERRIT_OAUTH_VERSION=2.14.3

ARG CI_USER_NAME=mcp-jenkins

ENV \
    GERRIT_HOME=$GERRIT_HOME \
    GERRIT_SITE=$GERRIT_HOME/review_site \
    GERRIT_WAR=$GERRIT_HOME/gerrit.war \
    GERRIT_VERSION=$GERRIT_VERSION \
    GERRIT_USER=gerrit2 \
    GERRIT_INIT_ARGS=$GERRIT_INIT_ARGS \
    GERRITFORGE_URL=https://gerrit-ci.gerritforge.com \
    GERRITFORGE_ARTIFACT_DIR=lastSuccessfulBuild/artifact/bazel-genfiles/plugins \
    MYSQL_CONNECTOR_VERSION=$MYSQL_CONNECTOR_VERSION \
    PLUGIN_VERSION=$PLUGIN_VERSION \
    GERRIT_OAUTH_VERSION=$GERRIT_OAUTH_VERSION \
    CI_USER_NAME=$CI_USER_NAME

VOLUME $GERRIT_SITE

ENTRYPOINT ["/gerrit-entrypoint.sh"]

EXPOSE 8080 29418

CMD ["/gerrit-start.sh"]

# Gerrit WAR
ADD https://gerrit-releases.storage.googleapis.com/gerrit-$GERRIT_VERSION.war \
    $GERRIT_WAR

# Plugins
ADD $GERRITFORGE_URL/job/plugin-delete-project-$PLUGIN_VERSION/$GERRITFORGE_ARTIFACT_DIR/delete-project/delete-project.jar \
    $GERRIT_SITE/plugins/

# XXX - removed plugin_version because target source only have master
ADD $GERRITFORGE_URL/job/plugin-project-download-commands-bazel-master/$GERRITFORGE_ARTIFACT_DIR/project-download-commands/project-download-commands.jar \
    $GERRIT_SITE/plugins/
#ADD $GERRITFORGE_URL/job/plugin-project-download-commands-$PLUGIN_VERSION/$GERRITFORGE_ARTIFACT_DIR/project-download-commands/project-download-commands.jar \
#    $GERRIT_SITE/plugins/

ADD $GERRITFORGE_URL/job/plugin-events-log-$PLUGIN_VERSION/$GERRITFORGE_ARTIFACT_DIR/events-log/events-log.jar \
    $GERRIT_SITE/plugins/

ADD $GERRITFORGE_URL/job/plugin-replication-$PLUGIN_VERSION/$GERRITFORGE_ARTIFACT_DIR/replication/replication.jar \
    $GERRIT_SITE/plugins/

ADD https://repo1.maven.org/maven2/mysql/mysql-connector-java/$MYSQL_CONNECTOR_VERSION/mysql-connector-java-$MYSQL_CONNECTOR_VERSION.jar \
    $GERRIT_SITE/lib/

ADD https://github.com/davido/gerrit-oauth-provider/releases/download/v$GERRIT_OAUTH_VERSION/gerrit-oauth-provider.jar \
    $GERRIT_HOME/gerrit-oauth-provider.jar

ADD $GERRITFORGE_URL/job/plugin-gitiles-$PLUGIN_VERSION/$GERRITFORGE_ARTIFACT_DIR/gitiles/gitiles.jar \
    $GERRIT_HOME/gitiles.jar

# Copy custom gerrit themes
COPY static $GERRIT_SITE/static
COPY themes $GERRIT_SITE/themes

# Copy custom etc
COPY etc $GERRIT_SITE/etc

# Ensure the entrypoint scripts are in a fixed location
COPY gerrit-entrypoint.sh gerrit-start.sh /

SHELL [ "/bin/sh",  "-euxc" ]

# Add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN \
    apk add --update --no-cache git openssh openssl bash perl perl-cgi git-gitweb curl su-exec mysql-client ; \
    adduser -D -h "$GERRIT_HOME" -g "Gerrit User" -s /sbin/nologin "$GERRIT_USER" ; \
    mkdir /docker-entrypoint-init.d ; \
    chmod +x /gerrit*.sh ; \
    chown -R "$GERRIT_USER" "$GERRIT_SITE" "$GERRIT_HOME"
