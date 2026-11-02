# alb-controller-iam

AWS Load Balancer Controller 가 ALB 를 만들 때 쓰는 IAM 정책·역할과 EKS Pod Identity 연결이다.

- 정책 본문 `policy.json` 은 컨트롤러 v3.6.2 의 `docs/install/iam_policy.json` 이다([aws-load-balancer-controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller), Apache-2.0). 컨트롤러 버전을 올리면 이 파일도 같은 버전으로 바꾼다.
- 컨트롤러(Helm 차트 `eks/aws-load-balancer-controller`)는 이 모듈이 만들지 않는다. 클러스터에 따로 설치한다.

```bash
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --version 3.6.2 \
  --set clusterName=<eks_cluster_name> --set region=<region> --set vpcId=<vpc_id> \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller
```

- 퍼블릭 서브넷에 `kubernetes.io/role/elb=1`, 프라이빗 서브넷에 `kubernetes.io/role/internal-elb=1` 태그가 있어야 ALB 가 서브넷을 찾는다.
