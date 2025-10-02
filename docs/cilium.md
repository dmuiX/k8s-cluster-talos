# some setttings

deploy cilium

cilium install \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=127.0.0.1 \
    --set k8sServicePort=7445 \ # kubeprism! 
    --set envoy.enabled=true \
    --set envoyConfig.enabled=true \
    --set envoyConfig.secretsNamespace.name=cilium \
    --set gatewayAPI.enabled=true \
    --set gatewayAPI.secretsNamespace.name=cilium \
    --set sysctlfix.enabled=false \
    --set ingressController.enabled=false \
    --set ingressController.loadbalancerMode=dedicated \
    --set externalIPs.enabled=true \
    --set l2announcements.enabled=true \
    --set l2podAnnouncements.enabled=true \
    --set l2podAnnouncements.interface=eth1 \
    --set loadBalancer.l7.backend=envoy \
    --set debug.enabled=true \
    --set debug.verbose=flow \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true

or patch the talos controlplane.yml to add haproxy.k8sdev.cloud 6443 to the cert!