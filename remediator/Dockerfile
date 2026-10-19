# Komodor's generic agent image plus kubectl, so a KAOP agent can change the cluster.
FROM curlimages/curl:8.23.0 AS kubectl
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.36.3
RUN curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
 && echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c - \
 && chmod +x /tmp/kubectl

FROM ghcr.io/komodorio/agentops-agent-base:0.1.2202
COPY --from=kubectl /tmp/kubectl /usr/local/bin/kubectl
