Add the repo `https://mojo2600.github.io/pihole-kubernetes/` from `mojo 2600`
Edit the values by pulling the chart(if desired)
```
helm repo add mojo2600 https://mojo2600.github.io/pihole-kubernetes/

helm install pihole mojo2600/pihole --values values.yaml
```

NOTE: if you want to install pihole solo, you must edit the network policy to
allow external internal traffic to the pod. See
[externalNetworkpolicy](https://github.com/ahmetb/kubernetes-network-policy-recipes/blob/master/08-allow-external-traffic.md)

