FROM python:3.9

ENV DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /mnt/vlan-ip /root/.linode-cli

RUN apt-get update && apt-get install -y \
    jq curl parallel net-tools apt-transport-https \
    ca-certificates iproute2 bash gnupg \
    iputils-ping dnsutils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip && \
    pip install linode-cli flask flask-cors etcd3 requests filelock aiohttp psutil kubernetes pyyaml 'protobuf<4.0.0,>=3.20.0' 

RUN curl -L https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz -o etcd.tar.gz && \
    tar xzf etcd.tar.gz --strip-components=1 -C /usr/local/bin etcd-v3.5.12-linux-amd64/etcdctl && \
    chmod +x /usr/local/bin/etcdctl && rm -f etcd.tar.gz

RUN curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

CMD ["bash"]
