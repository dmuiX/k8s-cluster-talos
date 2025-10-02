# need to set pod-security to privileged

'''bash
kubectl label namespace NAMESPAC    E-NAME pod-security.kubernetes.io/enforce=privileged
'''

https://www.talos.dev/v1.6/kubernetes-guides/configuration/pod-security/

# & some extensions


'''
The most straightforward method is patching the extensions onto existing Talos Linux nodes.

customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools

'''

https://longhorn.io/docs/1.9.0/advanced-resources/os-distro-specific/talos-linux-support/

and some more stuff

machine:
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw