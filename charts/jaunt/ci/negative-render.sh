#!/bin/sh
if [ -n "$1" ]; then CHART=$1; elif [ -f Chart.yaml ]; then CHART=.; else CHART=charts/jaunt; fi
HELM=${HELM:-helm}; BASE="-f $CHART/ci/minimal-values.yaml"
GATE="--set sshGate.enabled=true --set gateEndpoint=gate.example.org:22"
pass=0; fail=0
run() { $HELM template jaunt "$CHART" -n jaunt $BASE "$@" 2>&1; }
neg() { n=$1; want=$2; shift 2; out=$(run "$@"); rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qF -- "$want"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL neg: $n (rc=$rc, wanted: $want)"; fi; }
pos() { n=$1; shift; out=$(run "$@"); rc=$?
  if [ $rc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL pos: $n: $(printf '%s' "$out" | head -2)"; fi; }
for f in "$CHART"/ci/*-values.yaml; do
  $HELM lint --strict "$CHART" -f "$f" >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL lint: $f"; }
done
neg "replicas 2" "schema" --set replicaCount=2
neg "gate without agents" "agents.enabled is off" $GATE --set agents.enabled=false
neg "proxyProtocol without proxies" "trustedProxies is empty" $GATE --set sshGate.proxyProtocol=true
neg "proxies without proxyProtocol" "proxyProtocol is off" $GATE --set-json 'sshGate.trustedProxies=["10.0.0.0/8"]'
neg "extraEnv CA key" "extraEnv sets JAUNT_CA_KEY" --set-json 'extraEnv=[{"name":"JAUNT_CA_KEY","value":"x"}]'
neg "publicUrl trailing slash" "public_url" --set publicUrl=https://jaunt.example.org/
neg "ca.init without persistence" "persistence.enabled is off" --set ca.init.enabled=true --set persistence.enabled=false
neg "hostnames > 64" "hostnames" $GATE --set-json "sshGate.hostnames=[\"gate.example.org\"$(i=1; while [ $i -le 64 ]; do printf ',"h%d.example.org"' $i; i=$((i+1)); done)]"
neg "hostnames duplicate" "hostnames" $GATE --set-json 'sshGate.hostnames=["gate.example.org","gate.example.org"]'
neg "gate endpoint IPv6" "IPv6" --set sshGate.enabled=true --set 'gateEndpoint=[2001:db8::1]:22'
neg "agentEndpoint IP literal" "agentEndpoint" --set agentEndpoint=10.0.0.1:443
neg "agentEndpoint port 0" "agentEndpoint" --set agentEndpoint=agents.example.org:0
neg "sshSuffix uppercase" "sshSuffix" --set sshSuffix=SSH.Example.org
for p in 0.0.0.0/0 ::/0 10.0.0.0/7 2001::/15 ::ffff:10.0.0.0/104 10.0.0.1 nonsense; do
  neg "trustedProxies $p" "trustedProxies" $GATE --set sshGate.proxyProtocol=true --set-json "sshGate.trustedProxies=[\"$p\"]"
done
neg "ports collide" "ports" --set ports.agents=8443
neg "config overrides listen" "config" --set config.listen=127.0.0.1:8443
neg "config overrides ssh_gate trust" "config" $GATE --set sshGate.proxyProtocol=true --set-json 'sshGate.trustedProxies=["10.42.0.0/16"]' --set-json 'config.ssh_gate.trusted_proxies=["10.0.0.0/8"]'
neg "secret in config" "config" --set config.oidc.client_secret=x
neg "route host != publicUrl host" "publicUrl" --set route.gateway.name=gw --set route.tls.secretName=t --set route.http.enabled=true --set route.http.host=other.example.org
neg "tcp route without sectionName (no ListenerSet)" "sectionName" $GATE --set route.gateway.name=gw --set route.listenerSet.enabled=false --set route.ssh.enabled=true
neg "publicUrl upper-case host" "upper-case" --set publicUrl=https://Jaunt.example.org
neg "sshSuffix wildcard" "sshSuffix" --set 'sshSuffix=*.example.org'
neg "sshSuffix with space" "sshSuffix" --set 'sshSuffix=ssh example.org'
neg "agentEndpoint label starting with hyphen" "agentEndpoint" --set agentEndpoint=-agents.example.org:443
neg "agentEndpoint port 65536" "agentEndpoint" --set agentEndpoint=agents.example.org:65536
neg "agentEndpoint ends in a number" "agentEndpoint" --set agentEndpoint=agents.example.1:443
neg "hostnames empty name" "hostnames" $GATE --set-json 'sshGate.hostnames=["gate.example.org",""]'
neg "hostnames not a DNS name" "hostnames" $GATE --set-json 'sshGate.hostnames=["gate.example.org","a b"]'
neg "agents host differs" "route.agents.host" --set route.gateway.name=gw --set route.agents.enabled=true --set route.agents.host=other.example.org
neg "ingress host differs" "publicUrl" --set ingress.enabled=true --set ingress.host=other.example.org
neg "config secret key at depth" "secret" --set-json 'config={"a":{"b":{"my_Secret_thing":"x"}}}'
neg "config data_dir" "data_dir" --set config.data_dir=/elsewhere
neg "config oidc extra roots" "extra_root_certificates_file" --set config.oidc.extra_root_certificates_file=/x
neg "config ssh_gate without sshGate" "sshGate.enabled is off" --set config.ssh_gate.max_unauthenticated=10
neg "tls secretNamespace with certificate" "secretNamespace" --set route.gateway.name=gw --set route.http.enabled=true --set route.tls.certificate.enabled=true --set route.tls.certificate.issuer=i --set route.tls.secretNamespace=certs
neg "ssh NodePort with TCPRoute" "use one" $GATE --set route.gateway.name=gw --set route.ssh.enabled=true --set service.ssh.type=NodePort
neg "ssh nodePort on ClusterIP" "service.ssh.nodePort" $GATE --set service.ssh.nodePort=30022
neg "image repository empty" "image.repository" --set image.repository=
pos "gate endpoint IPv4 literal" $GATE --set gateEndpoint=192.0.2.10:22 --set-json 'sshGate.hostnames=["192.0.2.10"]'
pos "ssh NodePort with PROXY v2" $GATE --set sshGate.proxyProtocol=true --set-json 'sshGate.trustedProxies=["192.0.2.10/32"]' --set service.ssh.type=NodePort --set service.ssh.nodePort=30022
pos "config ssh_gate limits" $GATE --set config.ssh_gate.max_unauthenticated=10 --set config.ssh_gate.write_stall_secs=60
pos "IPv6 trusted proxy" $GATE --set sshGate.proxyProtocol=true --set-json 'sshGate.trustedProxies=["2001:db8::/32"]'
pos "single-label sshSuffix" --set sshSuffix=corp
pos "https URL with port" --set publicUrl=https://jaunt.example.org:8443
echo "pass=$pass fail=$fail"; [ $fail -eq 0 ]
