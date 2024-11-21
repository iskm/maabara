External DNS with pihole

Make sure to run where `somesecret` will be the password for your pihole
```
kubectl create secret generic external-dns-pihole-password \
  --from-literal EXTERNAL_DNS_PIHOLE_PASSWORD=somesecret
```

Add the annotation `external-dns.alpha.kubernetes.io/hostname:
\ nginx.external-dns-test.homelab.local` to your services, so external dns can
pick up the service and a dns entry in pihole automatically.
