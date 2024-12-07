FROM ubuntu:focal

# 
# docker build -t Crumflight/k1-klipper-fw-build:1.0 -f /mnt/d/Git/VScode/K1_Kreality/K1/docker/Dockerfile .
# docker login
# docker push Crumflight/k1-klipper-fw-build
#

ADD ./docker/2004-sources.list /etc/apt/sources.list

RUN apt-get update
RUN apt-get install -y python3 build-essential gcc-arm-none-eabi sudo srecord wget git curl cpio unzip rsync bc 

RUN adduser --disabled-password --gecos "" developer && \
  usermod -a -G sudo developer && \
  echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nopasswd

RUN mkdir /opt/toolchains && \
  wget https://github.com/Crumflight/K1/releases/download/Crum/mips-gcc720-glibc229.tar.gz -O /tmp/mips-gcc720-glibc229.tar.gz && \
  tar -zxf /tmp/mips-gcc720-glibc229.tar.gz -C /opt/toolchains && \
  rm /tmp/mips-gcc720-glibc229.tar.gz

ENV PATH=/opt/toolchains/mips-gcc720-glibc229/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN echo "alias mips-gcc='mips-linux-gnu-gcc'" >> /home/developer/.bashrc

USER developer
WORKDIR /home/developer

