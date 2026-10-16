## Задача 1: Docker

cd ~/ansible-task
sudo docker compose -f docker/docker-compose.yml up -d --build

## Задача 2: Firewall и SSH hardening

- Роль `ssh_hardening`: drop-in `/etc/ssh/sshd_config.d/00-hardening.conf`
  (root запрещён, пароли запрещены, только publickey, MaxAuthTries 3).
- Роль `firewall`: ufw, default deny incoming, allow outgoing.
  Порты задаются через `firewall_allowed_ports` в `group_vars`.
  - ubu1 (web): 22, 80, 443
  - ubu2 (monitoring): 22, 9090, 3000
- Проверка: `ansible all -b -m command -a "sshd -T"` и `ufw status verbose`.


