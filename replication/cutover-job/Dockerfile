# 컷오버 Job 이미지 (인프라 12.2, echo-infra#67): replication/k8s/scripts + kubectl + aws CLI.
# 서울 GKE echo-ops 네임스페이스에서 돈다. B(GKE)는 in-cluster 로, A(EKS)는 Google ID 토큰 → AWS 역할 → EKS 토큰으로 붙는다.
# 빌드(저장소 루트에서): docker build -f replication/cutover-job/Dockerfile --build-arg AWS_ROLE_ARN=<terraform output cutover_role_arn> -t <AR>/cutover:<태그> replication
# 배포에는 digest 를 쓴다(VAP 가 digest 를 고정한다). README.md 참고.
FROM amazon/aws-cli:2.39.4

ARG KUBECTL_VERSION=v1.36.6
ARG TARGETARCH=amd64
RUN dnf install -y --setopt=install_weak_deps=False bc findutils \
 && dnf clean all \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/kubectl

# 비밀이 아닌 고정값. 주소(A_HOST·B_HOST)는 실행할 때 Service 에서 읽는다(Job 환경 변수는 PLAN_ID·KIND·ALLOW_PROMOTE 만 허용).
ARG AWS_ROLE_ARN=""
ENV AWS_ROLE_ARN=${AWS_ROLE_ARN} \
    AWS_REGION=ap-northeast-1 \
    EKS_CLUSTER=echo-dev-eks \
    A_CTX=aws-tokyo \
    B_CTX=gcp-seoul \
    NS=echo-data \
    KUBECONFIG=/tmp/kubeconfig \
    HOME=/tmp

COPY k8s/scripts/*.sh /opt/echo/scripts/
COPY cutover-job/cutover-entry.sh /usr/local/bin/cutover-entry
RUN chmod 0755 /opt/echo/scripts/*.sh /usr/local/bin/cutover-entry

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/cutover-entry"]
