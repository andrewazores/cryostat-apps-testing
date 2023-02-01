#!/bin/sh
# shellcheck disable=SC3043

set -x
set -e

if [ -z "${MVN}" ]; then
    MVN="$(which mvn)"
fi

runCryostat() {
    local DIR; local host; local datasourcePort; local grafanaPort;
    DIR="$(dirname "$(readlink -f "$0")")"
    host="0.0.0.0"
    datasourcePort="8080"
    grafanaPort="3000"

    JDBC_URL="jdbc:h2:mem:cryostat;DB_CLOSE_DELAY=-1;INIT=create domain if not exists jsonb as varchar"
    JDBC_DRIVER="org.h2.Driver"
    JDBC_USERNAME="cryostat"
    JDBC_PASSWORD=""
    HIBERNATE_DIALECT="org.hibernate.dialect.H2Dialect"
    HBM2DDL="create"

    if [ -z "$CRYOSTAT_AUTH_MANAGER" ]; then
        CRYOSTAT_AUTH_MANAGER="io.cryostat.net.NoopAuthManager"
    fi

    GRAFANA_DATASOURCE_URL="http://${host}:${datasourcePort}" \
        GRAFANA_DASHBOARD_URL="http://${host}:${grafanaPort}" \
        CRYOSTAT_RJMX_USER=smoketest \
        CRYOSTAT_RJMX_PASS=smoketest \
        CRYOSTAT_ALLOW_UNTRUSTED_SSL=true \
        CRYOSTAT_AUTH_MANAGER="$CRYOSTAT_AUTH_MANAGER" \
        CRYOSTAT_JDBC_URL="$JDBC_URL" \
        CRYOSTAT_JDBC_DRIVER="$JDBC_DRIVER" \
        CRYOSTAT_HIBERNATE_DIALECT="$HIBERNATE_DIALECT" \
        CRYOSTAT_JDBC_USERNAME="$JDBC_USERNAME" \
        CRYOSTAT_JDBC_PASSWORD="$JDBC_PASSWORD" \
        CRYOSTAT_JMX_CREDENTIALS_DB_PASSWORD="smoketest" \
        CRYOSTAT_HBM2DDL="$HBM2DDL" \
        CRYOSTAT_DEV_MODE="true" \
        exec "$DIR/run.sh"
}

runDemoApps() {
    local webPort="8181";
    local protocol="https"

    podman run \
        --name quarkus-test-ssl \
        --pod cryostat-pod \
        --env JAVA_OPTS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager -Dcom.sun.management.jmxremote.port=9097 -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false -javaagent:/deployments/app/cryostat-agent.jar -Djavax.net.ssl.trustStore=/deployments/app/ssl/cacerts -Dhavax.net.ssl.trustStorePassword=changeit" \
        --env QUARKUS_HTTP_PORT=10010 \
        --env ORG_ACME_CRYOSTATSERVICE_ENABLED="false" \
        --env CRYOSTAT_AGENT_APP_NAME="quarkus-test-agent" \
        --env CRYOSTAT_AGENT_WEBCLIENT_SSL_TRUST_ALL="false" \
        --env CRYOSTAT_AGENT_WEBCLIENT_SSL_VERIFY_HOSTNAME="true" \
        --env CRYOSTAT_AGENT_WEBSERVER_HOST="localhost" \
        --env CRYOSTAT_AGENT_WEBSERVER_PORT="9977" \
        --env CRYOSTAT_AGENT_CALLBACK="http://localhost:9977/" \
        --env CRYOSTAT_AGENT_BASEURI="${protocol}://localhost:${webPort}/" \
        --env CRYOSTAT_AGENT_AUTHORIZATION="Basic $(echo user:pass | base64)" \
        --env CRYOSTAT_AGENT_HARVESTER_PERIOD_MS=60000 \
        --env CRYOSTAT_AGENT_HARVESTER_MAX_FILES=10 \
        --rm -d quay.io/andrewazores/quarkus-test:latest
}

runJfrDatasource() {
    local stream; local tag;
    stream="quay.io/cryostat/jfr-datasource"
    tag="latest"
    podman run \
        --name jfr-datasource \
        --pull always \
        --pod cryostat-pod \
        --rm -d "${stream}:${tag}"
}

runGrafana() {
    local stream; local tag; local host; local port;
    stream="quay.io/cryostat/cryostat-grafana-dashboard"
    tag="latest"
    host="0.0.0.0"
    port="8080"
    podman run \
        --name grafana \
        --pull always \
        --pod cryostat-pod \
        --env GF_INSTALL_PLUGINS=grafana-simple-json-datasource \
        --env GF_AUTH_ANONYMOUS_ENABLED=true \
        --env JFR_DATASOURCE_URL="http://${host}:${port}" \
        --rm -d "${stream}:${tag}"
}

createPod() {
    local jmxPort; local webPort; local datasourcePort; local grafanaPort;
    jmxPort="9091"
    webPort="8181"
    datasourcePort="8080"
    grafanaPort="3000"
    podman pod create \
        --replace \
        --hostname cryostat \
        --name cryostat-pod \
        --publish "${jmxPort}:${jmxPort}" \
        --publish "${webPort}:${webPort}" \
        --publish "${datasourcePort}:${datasourcePort}" \
        --publish "${grafanaPort}:${grafanaPort}" \
        --publish 10000:10000 \
        --publish 10001:10001 \
        --publish 10010:10010
    # 10010: quarkus-test-agent-1 HTTP
    # 10011: quarkus-test-agent-2 HTTP
}

destroyPod() {
    podman pod stop cryostat-pod
    podman pod rm cryostat-pod
}
trap destroyPod EXIT

createPod
if [ "$1" = "postgres" ]; then
    runPostgres
elif [ "$1" = "postgres-pgcli" ]; then
    runPostgres
    PGPASSWORD=abcd1234 pgcli -h localhost -p 5432 -U postgres
    exit
fi

podman build . -t quay.io/andrewazores/quarkus-test-ssl:latest
podman image prune -f

runDemoApps
runJfrDatasource
runGrafana
runCryostat "$1"
