FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server python3 sudo curl iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd

RUN useradd -m -s /bin/bash ansible \
 && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
 && mkdir -p /home/ansible/.ssh

COPY ssh/authorized_keys /home/ansible/.ssh/authorized_keys
RUN chown -R ansible:ansible /home/ansible/.ssh \
 && chmod 700 /home/ansible/.ssh && chmod 600 /home/ansible/.ssh/authorized_keys \
 && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]