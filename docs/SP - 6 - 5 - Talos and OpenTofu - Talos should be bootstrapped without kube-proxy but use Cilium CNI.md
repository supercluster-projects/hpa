To bootstrap Talos Linux without kube-proxy and use Cilium in **Kube-Proxy-Free Mode**, you must prevent Talos from deploying its native proxy and configure Cilium to handle all Kubernetes service routing using eBPF. \[1, 2\]

Because you are operating in an offline environment, you must also pass the path of your local image cache registry to Cilium during the installation.

## **1\. Disable kube-proxy in Talos MachineConfig**

You must instruct Talos to skip deploying kube-proxy during cluster initialization. Add the following blocks to your control plane machineconfig.yaml or pass them via an inline OpenTofu template:

`cluster:`  
  `network:`  
    `cni:`  
      `name: none # Tells Talos not to deploy a default CNI (like Flannel)`  
  `proxy:`  
    `disabled: true # Completely prevents kube-proxy from being deployed`

## **2\. OpenTofu Integration**

Ensure your OpenTofu templates inject this specific machine configuration block into your Talos control plane nodes.

`resource "talos_machine_configuration_apply" "control_plane" {`  
  `client_configuration = talos_machine_secrets.this.client_configuration`  
  `machine_configuration_input = templatefile("${path.module}/templates/control-plane.yaml.tmpl", {`  
    `# Pass variables if needed`  
  `})`  
  `node = libvirt_domain.talos_master.network_interface[0].addresses[0]`  
`}`

## **3\. Fetch and Prepare Cilium Offline Images**

Before deploying, download the [Cilium Helm chart](https://github.com/cilium/cilium/blob/main/install/kubernetes/cilium/values.yaml) and pull its container images on an internet-connected system, then push them to your internal offline network registry.

1. **Pull the Helm chart:**  
   `helm repo add cilium https://cilium.io`  
   `helm repo update`  
   `helm pull cilium/cilium --version 1.17.0 # Use your targeted version`  
   \[3, 4\]  
2. **Transfer images to your offline registry** (your-local-registry.internal):  
   * quay.io/cilium/cilium:v1.17.0  
   * quay.io/cilium/operator-generic:v1.17.0  
   * quay.io/cilium/cilium-envoy:v1.17.0

## **4\. Deploy Cilium in Kube-Proxy-Free Mode**

Once Talos has completed its initial bootstrap sequence, use Helm to deploy Cilium from your transferred .tgz file. The crucial configurations here are enabling kubeProxyReplacement, matching the Talos Kubelet path, and pointing to your offline container cache. \[5, 6\]

Create a cilium-values.yaml file: \[7\]

*`# Point to your local registry cache`*  
`image:`  
  `repository: your-local-registry.internal/cilium/cilium`  
  `tag: v1.17.0`  
  `useDigest: false`

`operator:`  
  `image:`  
    `repository: your-local-registry.internal/cilium/operator`  
    `tag: v1.17.0`  
    `useDigest: false`

*`# Kube-Proxy-Free explicit settings`*  
`kubeProxyReplacement: true`

*`# Provide explicit routing hints since kube-proxy is absent`*  
`k8sServiceHost: 127.0.0.1 # Point to Talos' internal local load balancer`  
`k8sServicePort: 7445       # Talos default internal API port`

*`# Critical directory mounts for Talos compatibility`*  
`cni:`  
  `binPath: /var/libexec/cni`  
  `confPath: /etc/cni/net.d`

`cgroupsPath: /run/current-system/cgroup`

Install the chart targeting your offline cluster:

`helm install cilium ./cilium-1.17.0.tgz \`  
  `--namespace kube-system \`  
  `-f cilium-values.yaml`

## **5\. Verify the eBPF Setup**

Once the Cilium pods initialize, verify that kube-proxy is missing and that Cilium has taken over routing: \[8\]

`kubectl get pods -n kube-system # Ensure no kube-proxy pods exist`  
`kubectl exec -n kube-system ds/cilium -- cilium status --compact`

The status output should explicitly state: KubeProxyReplacement: True. \[9\]

To refine the final configuration, please let me know:

* **The IP address or DNS endpoint of your Control Plane load balancer** (so we can precisely map k8sServiceHost).  
* **The specific Cilium version** you plan to mirror to your offline host.

I can write out the exact script to automate the image mirroring or generate the complete Helm manifest template.

\[1\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-disable-default-cni-flannel-in-talos-linux/view)  
\[2\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-03-replace-kube-proxy-with-cilium-on-talos-linux/view)  
\[3\] [https://support.crusoecloud.com](https://support.crusoecloud.com/hc/en-us/articles/40734739774491-How-To-Configure-Proxy-Load-Balancing-for-Kubernetes-Services-Using-Cilium-CNI)  
\[4\] [https://picluster.ricsanfre.com](https://picluster.ricsanfre.com/docs/cilium/)  
\[5\] [https://carlosperello.blog](https://carlosperello.blog/tag/cilium/)  
\[6\] [https://medium.com](https://medium.com/@vvimal44/set-up-k3s-with-cilium-as-core-networking-0ea110210592)  
\[7\] [https://docs.siderolabs.com](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)  
\[8\] [https://picluster.ricsanfre.com](https://picluster.ricsanfre.com/docs/cilium/)  
\[9\] [https://docs.cilium.io](https://docs.cilium.io/en/stable/operations/troubleshooting/)