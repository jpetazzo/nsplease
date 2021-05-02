FROM alpine
ARG TARGETOS
ARG TARGETARCH
# If the following step fails, it means that you are building with Docker's classic builder.
# Please use BuildKit (by setting environment var DOCKER_BUILDKIT=1) or set build args
# TARGETOS and TARGETARCH appropriately (for instance, to linux/amd64).
RUN [ -n "$TARGETOS" ] && [ -n "$TARGETARCH" ]
RUN apk add curl gettext jq # gettext is for envsubst
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/$TARGETOS/$TARGETARCH/kubectl" -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl
WORKDIR /opt/nsplease
COPY nsplease.sh .
COPY namespace-template.yaml .
CMD ["./nsplease.sh"]
