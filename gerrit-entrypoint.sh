#!/usr/bin/env sh
set -e

set_gerrit_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/gerrit.config" "$@"
}

set_secure_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/secure.config" "$@"
}

if [ -n "${JAVA_HEAPLIMIT}" ]; then
  JAVA_MEM_OPTIONS="-Xmx${JAVA_HEAPLIMIT}"
fi

# If we are using MySQL database, check if it's ready or fail
if [ "${DATABASE_TYPE}" = 'mysql' ]; then
  while true; do
    echo "Trying to connect to MySQL database on ${DB_PORT_3306_TCP_ADDR:-127.0.0.1}:${DB_PORT_3306_TCP_PORT:-3306}.."
    mysql -sss -h${DB_PORT_3306_TCP_ADDR:-127.0.0.1} -P${DB_PORT_3306_TCP_PORT:-3306} -u${DB_ENV_MYSQL_USER:-gerrit} -p${DB_ENV_MYSQL_PASSWORD} ${DB_ENV_MYSQL_DB:-gerrit} -e"SELECT 'Successfully connected to MySQL database on ${DB_PORT_3306_TCP_ADDR:-127.0.0.1}:${DB_PORT_3306_TCP_PORT:-3306}';" && break || sleep 5
  done
fi

if [ "$1" = "/gerrit-start.sh" ]; then
  # If you're mounting ${GERRIT_SITE} to your host, you this will default to root.
  # This obviously ensures the permissions are set correctly for when gerrit starts.
  [ ! -d ${GERRIT_SITE}/etc ] && mkdir ${GERRIT_SITE}/etc
  find ${GERRIT_SITE} ! -user $(id -u ${GERRIT_USER}) -exec chown ${GERRIT_USER} {} \;

  # Initialize Gerrit if ${GERRIT_SITE} is empty.
  if [ -z "$(ls -A "$GERRIT_SITE")" ]; then
    echo "First time initialize gerrit..."
    su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch --no-auto-start -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}
    #All git repositories must be removed when database is set as postgres or mysql
    #in order to be recreated at the secondary init below.
    #Or an execption will be thrown on secondary init.
    [ ${#DATABASE_TYPE} -gt 0 ] && rm -rf "${GERRIT_SITE}/git"
  fi

  # Change name of CI user, use separation "|" for several users
  sed -i "s/CI_USER_NAME/${CI_USER_NAME:-mcp-jenkins}/g" ${GERRIT_HOME}/static/hideci.js

  # Install themes
  [ -d ${GERRIT_SITE}/themes ] || su-exec ${GERRIT_USER} mkdir ${GERRIT_SITE}/themes
  su-exec ${GERRIT_USER} cp -rf ${GERRIT_HOME}/themes/* ${GERRIT_SITE}/themes/

  [ -d ${GERRIT_SITE}/static ] || su-exec ${GERRIT_USER} mkdir ${GERRIT_SITE}/static
  su-exec ${GERRIT_USER} cp -rf ${GERRIT_HOME}/static/* ${GERRIT_SITE}/static/

  # XXX: set All-Projects theme globally (should not be needed but is in 2.12)
  [ ! -d ${GERRIT_HOME}/themes/All-Projects ] || cp -f ${GERRIT_HOME}/themes/All-Projects/* ${GERRIT_SITE}/etc/

  # Install external plugins
  [ ! -d ${GERRIT_SITE}/plugins ] && mkdir ${GERRIT_SITE}/plugins && chown -R ${GERRIT_USER} "${GERRIT_SITE}/plugins"
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/delete-project.jar ${GERRIT_SITE}/plugins/delete-project.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/download-commands.jar ${GERRIT_SITE}/plugins/download-commands.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/events-log.jar ${GERRIT_SITE}/plugins/events-log.jar

  # Install the Bouncy Castle
  [ ! -d ${GERRIT_SITE}/lib ] && mkdir ${GERRIT_SITE}/lib && chown -R ${GERRIT_USER} "${GERRIT_SITE}/lib"
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/bcprov-jdk15on-${BOUNCY_CASTLE_VERSION}.jar ${GERRIT_SITE}/lib/bcprov-jdk15on-${BOUNCY_CASTLE_VERSION}.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/bcpkix-jdk15on-${BOUNCY_CASTLE_VERSION}.jar ${GERRIT_SITE}/lib/bcpkix-jdk15on-${BOUNCY_CASTLE_VERSION}.jar

  # Install mysql connector
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/mysql-connector-java-${MYSQL_CONNECTOR_VERSION}.jar ${GERRIT_SITE}/lib/mysql-connector-java-${MYSQL_CONNECTOR_VERSION}.jar

  # Provide a way to customise this image
  echo
  for f in /docker-entrypoint-init.d/*; do
    case "$f" in
      *.sh)    echo "$0: running $f"; source "$f" ;;
      *.nohup) echo "$0: running $f"; nohup  "$f" & ;;
      *)       echo "$0: ignoring $f" ;;
    esac
    echo
  done

  #Customize gerrit.config

  #Section gerrit
  [ -z "${WEBURL}" ] || set_gerrit_config gerrit.canonicalWebUrl "${WEBURL}"
  [ -z "${GITHTTPURL}" ] || set_gerrit_config gerrit.gitHttpUrl "${GITHTTPURL}"
  [ -z "${CANLOADINIFRAME}" ] || set_gerrit_config gerrit.canLoadInIframe "${CANLOADINIFRAME}"

  #Section sshd
  [ -z "${LISTEN_ADDR}" ] || set_gerrit_config sshd.listenAddress "${LISTEN_ADDR}"

  #Section database
  if [ "${DATABASE_TYPE}" = 'postgresql' ]; then
    set_gerrit_config database.type "${DATABASE_TYPE}"
    [ -z "${DB_PORT_5432_TCP_ADDR}" ]    || set_gerrit_config database.hostname "${DB_PORT_5432_TCP_ADDR}"
    [ -z "${DB_PORT_5432_TCP_PORT}" ]    || set_gerrit_config database.port "${DB_PORT_5432_TCP_PORT}"
    [ -z "${DB_ENV_POSTGRES_DB}" ]       || set_gerrit_config database.database "${DB_ENV_POSTGRES_DB}"
    [ -z "${DB_ENV_POSTGRES_USER}" ]     || set_gerrit_config database.username "${DB_ENV_POSTGRES_USER}"
    [ -z "${DB_ENV_POSTGRES_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_POSTGRES_PASSWORD}"
  fi

  #Section database
  if [ "${DATABASE_TYPE}" = 'mysql' ]; then
    set_gerrit_config database.type "${DATABASE_TYPE}"
    [ -z "${DB_PORT_3306_TCP_ADDR}" ] || set_gerrit_config database.hostname "${DB_PORT_3306_TCP_ADDR}"
    [ -z "${DB_PORT_3306_TCP_PORT}" ] || set_gerrit_config database.port "${DB_PORT_3306_TCP_PORT}"
    [ -z "${DB_ENV_MYSQL_DB}" ]       || set_gerrit_config database.database "${DB_ENV_MYSQL_DB}"
    [ -z "${DB_ENV_MYSQL_USER}" ]     || set_gerrit_config database.username "${DB_ENV_MYSQL_USER}"
    [ -z "${DB_ENV_MYSQL_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_MYSQL_PASSWORD}"
  fi

  #Section auth
  [ -z "${AUTH_TYPE}" ]           || set_gerrit_config auth.type "${AUTH_TYPE}"
  [ -z "${AUTH_HTTP_HEADER}" ]    || set_gerrit_config auth.httpHeader "${AUTH_HTTP_HEADER}"
  [ -z "${AUTH_EMAIL_FORMAT}" ]   || set_gerrit_config auth.emailFormat "${AUTH_EMAIL_FORMAT}"
  [ -z "${AUTH_GIT_BASIC_AUTH}" ] || set_gerrit_config auth.gitBasicAuth "${AUTH_GIT_BASIC_AUTH}"

  #Section ldap
  if [ "${AUTH_TYPE}" = 'LDAP' ] || [ "${AUTH_TYPE}" = 'LDAP_BIND' ] || [ "${AUTH_TYPE}" = 'HTTP_LDAP' ]; then
    [ -z "${AUTH_GIT_BASIC_AUTH}" ]           && set_gerrit_config auth.gitBasicAuth true
    [ -z "${LDAP_SERVER}" ]                   || set_gerrit_config ldap.server "${LDAP_SERVER}"
    [ -z "${LDAP_SSLVERIFY}" ]                || set_gerrit_config ldap.sslVerify "${LDAP_SSLVERIFY}"
    [ -z "${LDAP_GROUPSVISIBLETOALL}" ]       || set_gerrit_config ldap.groupsVisibleToAll "${LDAP_GROUPSVISIBLETOALL}"
    [ -z "${LDAP_USERNAME}" ]                 || set_gerrit_config ldap.username "${LDAP_USERNAME}"
    [ -z "${LDAP_PASSWORD}" ]                 || set_secure_config ldap.password "${LDAP_PASSWORD}"
    [ -z "${LDAP_REFERRAL}" ]                 || set_gerrit_config ldap.referral "${LDAP_REFERRAL}"
    [ -z "${LDAP_READTIMEOUT}" ]              || set_gerrit_config ldap.readTimeout "${LDAP_READTIMEOUT}"
    [ -z "${LDAP_ACCOUNTBASE}" ]              || set_gerrit_config ldap.accountBase "${LDAP_ACCOUNTBASE}"
    [ -z "${LDAP_ACCOUNTSCOPE}" ]             || set_gerrit_config ldap.accountScope "${LDAP_ACCOUNTSCOPE}"
    [ -z "${LDAP_ACCOUNTPATTERN}" ]           || set_gerrit_config ldap.accountPattern "$(echo ${LDAP_ACCOUNTPATTERN} | sed -E 's,\{username\},\$\{username\},g')"
    [ -z "${LDAP_ACCOUNTFULLNAME}" ]          || set_gerrit_config ldap.accountFullName "${LDAP_ACCOUNTFULLNAME}"
    [ -z "${LDAP_ACCOUNTEMAILADDRESS}" ]      || set_gerrit_config ldap.accountEmailAddress "${LDAP_ACCOUNTEMAILADDRESS}"
    [ -z "${LDAP_ACCOUNTSSHUSERNAME}" ]       || set_gerrit_config ldap.accountSshUserName "${LDAP_ACCOUNTSSHUSERNAME}"
    [ -z "${LDAP_ACCOUNTMEMBERFIELD}" ]       || set_gerrit_config ldap.accountMemberField "${LDAP_ACCOUNTMEMBERFIELD}"
    [ -z "${LDAP_FETCHMEMBEROFEAGERLY}" ]     || set_gerrit_config ldap.fetchMemberOfEagerly "${LDAP_FETCHMEMBEROFEAGERLY}"
    [ -z "${LDAP_GROUPBASE}" ]                || set_gerrit_config ldap.groupBase "${LDAP_GROUPBASE}"
    [ -z "${LDAP_GROUPSCOPE}" ]               || set_gerrit_config ldap.groupScope "${LDAP_GROUPSCOPE}"
    [ -z "${LDAP_GROUPPATTERN}" ]             || set_gerrit_config ldap.groupPattern "${LDAP_GROUPPATTERN}"
    [ -z "${LDAP_GROUPMEMBERPATTERN}" ]       || set_gerrit_config ldap.groupMemberPattern "${LDAP_GROUPMEMBERPATTERN}"
    [ -z "${LDAP_GROUPNAME}" ]                || set_gerrit_config ldap.groupName "${LDAP_GROUPNAME}"
    [ -z "${LDAP_LOCALUSERNAMETOLOWERCASE}" ] || set_gerrit_config ldap.localUsernameToLowerCase "${LDAP_LOCALUSERNAMETOLOWERCASE}"
    [ -z "${LDAP_AUTHENTICATION}" ]           || set_gerrit_config ldap.authentication "${LDAP_AUTHENTICATION}"
    [ -z "${LDAP_USECONNECTIONPOOLING}" ]     || set_gerrit_config ldap.useConnectionPooling "${LDAP_USECONNECTIONPOOLING}"
    [ -z "${LDAP_CONNECTTIMEOUT}" ]           || set_gerrit_config ldap.connectTimeout "${LDAP_CONNECTTIMEOUT}"
  fi

  #Section OAUTH general
  if [ "${AUTH_TYPE}" = 'OAUTH' ]  ; then
    su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/gerrit-oauth-provider.jar ${GERRIT_SITE}/plugins/gerrit-oauth-provider.jar
    [ -z "${OAUTH_ALLOW_EDIT_FULL_NAME}" ]     || set_gerrit_config oauth.allowEditFullName "${OAUTH_ALLOW_EDIT_FULL_NAME}"
    [ -z "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}" ] || set_gerrit_config oauth.allowRegisterNewEmail "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}"

    # Google
    [ -z "${OAUTH_GOOGLE_RESTRICT_DOMAIN}" ]   || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.domain "${OAUTH_GOOGLE_RESTRICT_DOMAIN}"
    [ -z "${OAUTH_GOOGLE_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-id "${OAUTH_GOOGLE_CLIENT_ID}"
    [ -z "${OAUTH_GOOGLE_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-secret "${OAUTH_GOOGLE_CLIENT_SECRET}"
    [ -z "${OAUTH_GOOGLE_LINK_OPENID}" ]       || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.link-to-existing-openid-accounts "${OAUTH_GOOGLE_LINK_OPENID}"

    # Github
    [ -z "${OAUTH_GITHUB_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-id "${OAUTH_GITHUB_CLIENT_ID}"
    [ -z "${OAUTH_GITHUB_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-secret "${OAUTH_GITHUB_CLIENT_SECRET}"
  fi

  #Section container
  [ -z "${JAVA_HEAPLIMIT}" ] || set_gerrit_config container.heapLimit "${JAVA_HEAPLIMIT}"
  [ -z "${JAVA_OPTIONS}" ]   || set_gerrit_config container.javaOptions "${JAVA_OPTIONS}"
  [ -z "${JAVA_SLAVE}" ]     || set_gerrit_config container.slave "${JAVA_SLAVE}"

  #Section sendemail
  if [ -z "${SMTP_SERVER}" ]; then
    set_gerrit_config sendemail.enable false
  else
    set_gerrit_config sendemail.enable true
    set_gerrit_config sendemail.smtpServer "${SMTP_SERVER}"
    if [ "smtp.gmail.com" = "${SMTP_SERVER}" ]; then
      echo "gmail detected, using default port and encryption"
      set_gerrit_config sendemail.smtpServerPort 587
      set_gerrit_config sendemail.smtpEncryption tls
    fi
    [ -z "${SMTP_SERVER_PORT}" ] || set_gerrit_config sendemail.smtpServerPort "${SMTP_SERVER_PORT}"
    [ -z "${SMTP_USER}" ]        || set_gerrit_config sendemail.smtpUser "${SMTP_USER}"
    [ -z "${SMTP_PASS}" ]        || set_secure_config sendemail.smtpPass "${SMTP_PASS}"
    [ -z "${SMTP_ENCRYPTION}" ]      || set_gerrit_config sendemail.smtpEncryption "${SMTP_ENCRYPTION}"
    [ -z "${SMTP_CONNECT_TIMEOUT}" ] || set_gerrit_config sendemail.connectTimeout "${SMTP_CONNECT_TIMEOUT}"
    [ -z "${SMTP_FROM}" ]            || set_gerrit_config sendemail.from "${SMTP_FROM}"
  fi

  #Section user
    [ -z "${USER_NAME}" ]             || set_gerrit_config user.name "${USER_NAME}"
    [ -z "${USER_EMAIL}" ]            || set_gerrit_config user.email "${USER_EMAIL}"
    [ -z "${USER_ANONYMOUS_COWARD}" ] || set_gerrit_config user.anonymousCoward "${USER_ANONYMOUS_COWARD}"

  #Section plugins
  set_gerrit_config plugins.allowRemoteAdmin true

  #Section plugin events-log
  set_gerrit_config plugin.events-log.storeUrl "jdbc:h2:${GERRIT_SITE}/db/ChangeEvents"

  #Section httpd
  [ -z "${HTTPD_LISTENURL}" ] || set_gerrit_config httpd.listenUrl "${HTTPD_LISTENURL}"

  #Section gitweb
  case "$GITWEB_TYPE" in
     "gitiles") su-exec $GERRIT_USER cp -f $GERRIT_HOME/gitiles.jar $GERRIT_SITE/plugins/gitiles.jar ;;
     "") # Gitweb by default
        set_gerrit_config gitweb.cgi "/usr/share/gitweb/gitweb.cgi"
        export GITWEB_TYPE=gitweb
     ;;
  esac
  set_gerrit_config gitweb.type "$GITWEB_TYPE"

  #Enable JIRA links
  #Delete sectionin gerrit.config to avoid duplicates
  perl -i -pe 'undef $/; s/\[commentlink "jira"\]\n(\s[^\n]*\n)+//igs' "${GERRIT_SITE}/etc/gerrit.config"

  [ -z "${GERRIT_JIRA_URL}" ] || cat <<-EOF >> "${GERRIT_SITE}/etc/gerrit.config"
[commentlink "jira"]
  match = "[Pp][rR][oO][dD]:{1} *#?(\\\d+)"
  link = "https://${GERRIT_JIRA_URL}/browse/PROD-\$1"
EOF

  #Enable display table votes of CI
  #Delete sectionin gerrit.config to avoid duplicates
  perl -i -pe 'undef $/; s/\[commentlink "testresult"\]\n(\s[^\n]*\n)+//igs' "${GERRIT_SITE}/etc/gerrit.config"

  cat <<-EOF >> "${GERRIT_SITE}/etc/gerrit.config"
[commentlink "testresult"]
  match = <li>([^ ]+) <a href=\"[^\"]+\" [^>]*>([^<]+)</a> : ([^ ]+)([^<]*)</li>
  link = ""
  html = "<li class=\"comment_test\"><span class=\"comment_test_name\"><a href=\"\$2\">\$1</a></span> <span class=\"comment_test_result\"><span class=\"result_\$3\">\$3</span>    \$4</span></li>"
EOF


  echo "Upgrading gerrit..."
  su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}
  if [ $? -eq 0 ]; then
    GERRIT_VERSIONFILE="${GERRIT_SITE}/gerrit_version.txt"

    if [ -z "${IGNORE_VERSIONCHECK}" ]; then
      # don't perform a version check and never do a full reindex
      NEED_REINDEX=0
    else
      # check whether it's a good idea to do a full upgrade
      NEED_REINDEX=1
      echo "checking version file ${GERRIT_VERSIONFILE}"
      if [ -f "${GERRIT_VERSIONFILE}" ]; then
        OLD_GERRIT_VER="V"`cat ${GERRIT_VERSIONFILE}`
        GERRIT_VER="V${GERRIT_VERSION}"
        echo " have old gerrit version ${OLD_GERRIT_VER}"
        if [ "${OLD_GERRIT_VER}" == "${GERRIT_VER}" ]; then
          echo " same gerrit version, no upgrade necessary ${OLD_GERRIT_VER} == ${GERRIT_VER}"
          NEED_REINDEX=0
        else
          echo " gerrit version mismatch #${OLD_GERRIT_VER}# != #${GERRIT_VER}#"
        fi
      else
        echo " gerrit version file does not exist, upgrade necessary"
      fi
    fi

    if [ ${NEED_REINDEX} -eq 1 ]; then
      echo "Reindexing all..."
      su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_SITE}"
    else
      echo "Reindexing accounts..."
      su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose --index accounts -d "${GERRIT_SITE}"
    fi
    echo "Upgrading is OK. Writing versionfile ${GERRIT_VERSIONFILE}"
    echo "${GERRIT_VERSION}" > "${GERRIT_VERSIONFILE}"
    echo "${GERRIT_VERSIONFILE} written."
  else
    echo "Something wrong..."
    cat "${GERRIT_SITE}/logs/error_log"
  fi
fi
exec "$@"
