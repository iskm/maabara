On a fresh cluster, the order of installation is usually `metallb` -> `pihole`
-> your favorite ingress controller->  external-dns -> longhorn(install
pre-reqs) -> cert-manager -> other services 


Installing `pihole` via helm, it will look for its password in a secret named
`pihole-dashboard-password` in the same namespace. You can create it like so
```
kubectl create secret generic pihole-dashboard-password
--from-literal=password=XXXXXXXXX

```
Of course, substituting XXXXXX for your actual password. If you care, make sure
actual encryption at rest is enabled for your passwords.

Make sure to update your main LAN dns servers to point to pihole. 2 instances
for redundancy are highly encouraged

Installing externaldns via manifests, it will look for its password in a secret named
`pihole-externaldns-password` in the same namespace. You can create it like so
```
kubectl create secret generic pihole-dashboard-password
--from-literal=EXTERNAL_DNS_PIHOLE_PASSWORD=XXXXXXXXX

```


If possible, create a secret resource during setup rather than hardcoding
passwords otherwise there's a good chance of it being committed unawares
