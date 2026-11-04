# 11/2 에 CLI 로 만든 ALB 컨트롤러 자원을 state 로 가져온다. apply 한 번 뒤에는 이 파일을 지워도 된다(인프라 3.3 과 같은 방식).
import {
  to = aws_iam_policy.lbc
  id = "arn:aws:iam::706878591119:policy/echo-was-lbc-policy"
}

import {
  to = aws_iam_role.lbc
  id = "echo-was-lbc"
}

import {
  to = aws_iam_role_policy_attachment.lbc
  id = "echo-was-lbc/arn:aws:iam::706878591119:policy/echo-was-lbc-policy"
}

import {
  to = aws_eks_pod_identity_association.lbc
  id = "echo-dev-eks,a-oft2qy6efx5upkol0"
}
