# Gitlab MR Combiner Helm Chart  

This Helm chart is designed for deploying the **Gitlab MR Combiner** service in a Kubernetes cluster.  

## Installation  

### 1. Add the Helm repository  

To add the repository and update the chart index:  

```sh
helm repo add globalart https://globalartinc.github.io/helm-charts
helm repo update
```

### 2. Retrieve default values  

Download the default configuration to customize before deployment:  

```sh
helm show values globalart/gitlab-mr-combiner > values.yaml
```

### 3. Customize configuration  

Edit `values.yaml` as needed to configure the service.

### 4. Install the release

Deploy the chart using the customized values file:  

```sh
helm upgrade --install gitlab-mr-combiner globalart/gitlab-mr-combiner -n gitlab --create-namespace -f values.yaml
```

### 5. Verify installation  

Check the status of the deployed release:  

```sh
helm list -n gitlab
```

Ensure all pods are running:  

```sh
kubectl get pods -n gitlab
```

## Upgrade  

To upgrade the chart while keeping custom values:  

```sh
helm upgrade gitlab-mr-combiner globalart/gitlab-mr-combiner -n gitlab -f values.yaml
```

## Uninstall  

To remove the release from the cluster:  

```sh
helm uninstall gitlab-mr-combiner -n gitlab
```
