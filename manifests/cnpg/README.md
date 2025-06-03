longhorn is the default storage provider in this cluster. By default, its
replicates storage 3 times which is redundant as the postgresql does
application level replication.

cnpg will create secrets containing login passwords in the same namespace it
was deployed
