# DO Install Button

This is an **experimental** installer for getting apps running quickly on DigitalOcean. **NO LONGER MAINTAINED**

This tool is written by DO fans, and is not affiliated with DigitalOcean Inc.

## Run this tool yourself

```
git clone git@github.com:seven1m/do-install-button.git
cd do-install-button
cp config.yml{.example,}
# edit config.yml appropriately
bundle
rackup
```

## app.yml config format:

```yaml
name: MyApp
image: ubuntu-14-04-x64
min_size: 1gb
config:
  #cloud-config
  users:
    - name: deploy
      groups: sudo
      shell: /bin/bash
      sudo: ['ALL=(ALL) NOPASSWD:ALL']
  packages:
    - git
  runcmd:
    - cd /home/deploy && git clone git://github.com/foo/bar.git && cd bar && bash provision.sh
```

## Copyright

Copyright (c) Tim Morgan. See LICENSE file in this directory.
