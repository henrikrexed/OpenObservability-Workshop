#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### dttoken : Dynatrace Data ingest Api token ( Required)
### dturl: Dynatrace url including https ( Required)
### oteldemo_version: Otel-demo version ( not manadatory , default value: v1.0.0
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
  --dttoken)
    DTTOKEN="$2"
   shift 2
    ;;
  --dturl)
    DTURL="$2"
   shift 2
    ;;
  --clustername)
    CLUSTERNAME="$2"
   shift 2
    ;;
  --oteldemo_version)
    VERSION="$2"
   shift 2
    ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
if [ -z "$CLUSTERNAME" ]; then
  echo "Error: clustername not set!"
  exit 1
fi

if [ -z "$VERSION" ]; then
  VERSION=v1.0.0
  echo "Deploying the Otel demo version $VERSION"
fi

if [ -z "$DTURL" ]; then
  echo "Error: environment-url not set!"
  exit 1
fi

if [ -z "$DTTOKEN" ]; then
  echo "Error: api-token not set!"
  exit 1
fi

###### DEploy Nginx
echo "start depploying Nginx"
kubectl create ns nginx
helm repo add nginx-stable https://helm.nginx.com/stable
helm install -n nginx nginx nginx-stable/nginx-ingress --set controller.enableLatencyMetrics=true --set prometheus.create=true --set controller.config.name=nginx-config


### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc nginx-nginx-ingress -n nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to use the dns entry /ELB/ALB
sed -i "s,IP_TO_REPLACE,$IP," kubernetes-manifests/K8sdemo.yaml
sed -i "s,IP_TO_REPLACE,$IP," grafana/ingress.yaml

##Updating deployment files
sed -i "s,VERSION_TO_REPLACE,$VERSION," kubernetes-manifests/K8sdemo.yaml


### Depploy Prometheus
echo "start depploying Prometheus"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack --set sidecar.datasources.enabled=true --set sidecar.datasources.label=grafana_datasource --set sidecar.datasources.labelValue="1" --set sidecar.dashboards.enabled=true
##wait that the prometheus pod is started
kubectl wait pod --namespace default -l "release=prometheus" --for=condition=Ready --timeout=2m
PROMETHEUS_SERVER=$(kubectl get svc -l app=kube-prometheus-stack-prometheus -o jsonpath="{.items[0].metadata.name}")
echo "Prometheus service name is $PROMETHEUS_SERVER"
GRAFANA_SERVICE=$(kubectl get svc -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")
echo "Grafana service name is  $GRAFANA_SERVICE"
ALERT_MANAGER_SVC=$(kubectl get svc -l app=kube-prometheus-stack-alertmanager -o jsonpath="{.items[0].metadata.name}")
echo "Alertmanager service name is  $ALERT_MANAGER_SVC"

#update the configuration of prometheus
kubectl apply -f prometheus/PrometheusRule.yaml
kubectl create secret generic addtional-scrape-configs --from-file=prometheus/additionnalscrapeconfig.yaml
kubectl apply -f prometheus/Prometheus.yaml

## Adding the grafana Helm Repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

sed -i "s,API_TOKEN_TO_REPLACE,$DTTOKEN," kubernetes-manifests/openTelemetry-manifest_dynatrace_metrics.yaml
sed -i "s,TENANT_TO_REPLACE,$DTURL," kubernetes-manifests/openTelemetry-manifest_dynatrace_metrics.yaml
sed -i "s,API_TOKEN_TO_REPLACE,$DTTOKEN," kubernetes-manifests/openTelemetry-manifest_dynatrace.yaml
sed -i "s,TENANT_TO_REPLACE,$DTURL," kubernetes-manifests/openTelemetry-manifest_dynatrace.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," kubernetes-manifests/openTelemetry-sidecar.yaml
sed -i "s,CLUSTER_ID_TOREPLACE,$CLUSTERID," hipster-shop/openTelemetry-sidecar.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME," kubernetes-manifests/openTelemetry-sidecar.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  hipster-shop/openTelemetry-sidecar.yaml

#Deploying the fluent operator
echo "Deploying FluentOperator"
helm install fluent-operator --create-namespace -n kubesphere-logging-system https://github.com/fluent/fluent-operator/releases/download/v1.0.0/fluent-operator.tgz


#Deploy applicatoin
kubectl create ns otel-demo
kubectl apply -f kubernetes-manifests/openTelemetry-sidecar.yaml -n otel-demo
kubectl apply -f kubernetes-manifests/K8sdemo.yaml -n otel-demo
sed -i "s,PROM_SVC_TO_REPLACE,$PROMETHEUS_SERVER," hipster-shop/k8Sdemo-nootel.yaml

# Deploy the fluent agents
sed -i "s,API_TOKEN_TO_REPLACE,$DTTOKEN," fluent/cluster_output_http.yaml
sed -i "s,TENANT_TO_REPLACE,$DTURL," fluent/cluster_output_http.yaml
sed -i "s,CLUSTER_ID_TO_REPLACE,$CLUSTERID," fluent/clusterfilter.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME," fluent/clusterfilter.yaml
kubectl apply -f fluent/fluentbit_deployment.yaml  -n kubesphere-logging-system

# Deploy the Kubecost
kubectl apply -f grafana/ingress.yaml
if [ $K3d_mode -eq 1 ]
then
  PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d)
  USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 -d)
else
  PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
  USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 --decode)
fi


#Deploy the OpenTelemetry Collector
echo "Deploying Otel Collector"
kubectl apply -f kubernetes-manifests/rbac.yaml
kubectl apply -f kubernetes-manifests/openTelemetry-manifest.yaml
kubectl apply -f grafana/ServiceMonitor.yaml
# Deploy Kubecost
kubectl create namespace kubecost
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer --namespace kubecost --set kubecostToken="aGVucmlrLnJleGVkQGR5bmF0cmFjZS5jb20=xm343yadf98" --set prometheus.kube-state-metrics.disabled=true --set prometheus.nodeExporter.enabled=false --set ingress.enabled=true --set ingress.hosts[0]="kubecost.$IP.nip.io" --set global.grafana.enabled=false --set global.grafana.fqdn="http://$GRAFANA_SERVICE.default.svc" --set prometheusRule.enabled=true --set global.prometheus.fqdn="http://$PROMETHEUS_SERVER.default.svc:9090" --set global.prometheus.enabled=false --set serviceMonitor.enabled=true
kubectl apply -f kubecost/PrometheusRule.yaml
kubectl create secret generic addtional-scrape-configs --from-file=kubecost/additionnalscrapeconfig.yaml



# Echo environ*
echo "==============Grafana============================="
echo "Environment fully deployed "
echo "Grafana url : http://grafana.$IP.nip.io"
echo "Grafana User: $USER_GRAFANA"
echo "Grafana Password: $PASSWORD_GRAFANA"
echo "--------------Demo--------------------"
echo "url of the demo: "
echo "Otel demo url: http://demo.$IP.nip.io"
echo "Locust: http://locust.$IP.nip.io"
echo "FeatureFlag : http://featureflag.$IP.nip.io"
echo "========================================================"


