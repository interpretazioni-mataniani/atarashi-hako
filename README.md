# Atarashi Hako
Atarashi Hako (新しい箱 - 'new box' in Japanese) is a Docker container update script which uses [Skope](https://github.com/containers/skopeo) to update containers in a less aggressive way than existing tools, imported from my home system.
Atarashi writes the output to a Prometheus file (`atarashi-hako.prom`), which can then be picked up by a Prometheus instance to notify when containers are updated\fail to update. An example alert (`prometheus-alert.yaml`) is included.

It currently update Docker.io images. New repositories will be added in the future as needed.

**This is a sanitized, non-functional template** you can modify and use as you see fit.

This repository consists of:
- `atarashi-hako.sh` - the update script itself
- `atarashi-hako.service.j2` - systemd service template, configured via Ansible
- `atarashi-hako.timer.j2` - systemd timer template, configured via Ansible
- `./gitea/workflows/atarashi-hako.yaml` - Gitea Actions CI workflow which installs Ansible, and runs the `atarashi-hako.yaml` playbook to configure Atarashi Hako.

# Usage
Atarashi Hako relies on two environment variables:
- `HAKO_USER` - your docker.io user
- `B2_ACCOUNT_KEY` - your docker.io password

## As standalone script
Once previous requirements are met, Atarashi Hako can run as-is, given that `skopeo`, and of course `docker` are installed.

## As Ansible pipeline
To deploy Atarashi Hako over multiple systems, you'll need to provide several secrets:
1. A valid SSH key for Ansible to use to connect to target systems (`{{ SSH_PRIVATE_KEY }}`)
2. A sudo password for elevated privledges, if needed. If not - you'll need to set `become` to `no` in `atarashi-hako.yaml`
3. An Ansible inventory file. I'm cloning it from another repository via an access token - you can do the same or simply provide it.
