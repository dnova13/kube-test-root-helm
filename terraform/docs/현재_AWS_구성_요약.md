# 현재 AWS 구성 요약 (Terraform 코드화의 근거)

> 2026-10-06에 `aws` CLI **읽기 명령**(`describe`/`list`/`get`)으로 조회한 `test-cluster` 계정의 실제 구성이다. AWS를 내리기 전에 기록해 두는 것이 목적이다.
> 계정 ID는 `<ACCT>`로, 내 공인 IP는 `<내 공인 IP>`로 가렸다. 비밀값(DB 비밀번호, SMTP 계정)은 조회되지 않아 포함하지 않았다.
> 리전 `ap-northeast-2`(서울), 기본 VPC 사용. Terraform 코드는 `../aws/`.

## 1. EKS 클러스터 `test-cluster`

| 항목 | 값 |
|---|---|
| Kubernetes 버전 | 1.36 (업그레이드 정책 STANDARD) |
| 클러스터 Role | `EKS-Cluster-role` |
| 인증 방식 | `API` (Access Entry) |
| 엔드포인트 | Public + Private, 공개 CIDR `0.0.0.0/0` |
| 컴퓨트 | **Auto Mode 켜짐** (노드 풀 `general-purpose`, `system`), Auto Mode 노드 Role `eks-node-rule` |
| 스토리지 | Auto Mode 블록 스토리지 켜짐 |
| 네트워크 | Service CIDR `10.100.0.0/16`, IPv4, Elastic Load Balancing 켜짐 (ALB 자동 구성) |
| 로깅 | 5종 모두 꺼짐 |
| 서브넷 | 기본 VPC의 서브넷 4개(AZ a·b·c·d), 각 `172.31.{0,16,32,48}.0/20` |

## 2. 노드 그룹 `sns-node` (Auto Mode와 별개의 관리형 노드 그룹)

| 항목 | 값 |
|---|---|
| AMI | `AL2023_x86_64_STANDARD` |
| 용량 | ON_DEMAND, 디스크 20 GiB |
| 인스턴스 | **`c7i-flex.large`** (Free Tier 계정은 `t3.medium` 불가) |
| 크기 | 최소 2 / 최대 6 / **현재 6** (실험으로 늘린 값. 체크리스트의 기본은 3) |
| 노드 Role | `sns-node-rule` (**Auto Mode용 `eks-node-rule`과 달라야 함**) |
| 업데이트 | 한 번에 1대 |

## 3. 애드온

| 애드온 | 상태 | 비고 |
|---|---|---|
| `coredns`, `kube-proxy`, `vpc-cni`, `eks-pod-identity-agent`, `metrics-server` | ACTIVE | 버전 고정 없이 기본값 사용 |
| `aws-efs-csi-driver` | ACTIVE | IAM Role `AmazoneEKS-EFS-CSI-DriverRole` 연결 |
| `kubecost_kubecost` | **CREATE_FAILED** | Marketplace 구독 필요. **코드화하지 않는다** |

## 4. IAM

| Role | 신뢰 대상 | 연결된 관리형 정책 |
|---|---|---|
| `EKS-Cluster-role` | `eks.amazonaws.com` (`sts:AssumeRole` + **`sts:TagSession`**) | `AmazonEKSClusterPolicy`, `AmazonEKSNetworkingPolicy`, `AmazonEKSComputePolicy`, `AmazonEKSBlockStoragePolicy`, `AmazonEKSLoadBalancingPolicy` |
| `eks-node-rule` (Auto Mode 노드) | `ec2.amazonaws.com` | `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKSWorkerNodePolicy` |
| `sns-node-rule` (노드 그룹) | `ec2.amazonaws.com` | 위와 같은 3개 |
| `AmazoneEKS-EFS-CSI-DriverRole` | **IAM OIDC 공급자**(`oidc.eks…/id/<클러스터 ID>`), `AssumeRoleWithWebIdentity`, `StringLike`: `sub=system:serviceaccount:kube-system:efs-csi-*`, `aud=sts.amazonaws.com` | `AmazonEFSCSIDriverPolicy` |

- 인라인 정책은 없다.
- IAM OIDC 공급자 1개(클러스터의 OIDC 발급자 주소). **새 클러스터는 이 주소가 달라져서 수작업으로는 가장 놓치기 쉬운 부분**이다. Terraform은 새 클러스터 값을 참조해 자동으로 맞춘다.
- `EKS-Cluster-role`의 `sts:TagSession`은 Auto Mode에서 ALB를 만들 때 필요하다(`part3-infra/docs/Ingress_ALB_세팅_이슈_가이드.md`).
- Role 이름의 철자(`rule`, `Amazone`)는 수작업 때의 것이다. Terraform 코드는 `sns-*` 이름으로 새로 만든다.

## 5. Access Entry (클러스터 접근 권한)

`AWSServiceRoleForAmazonEKS`, `eks-node-rule`, `sns-node-rule`, 계정 root, `user/test`(CLI 사용자). 앞의 셋은 EKS가 자동으로 만들고, **`user/test`는 클러스터를 만든 주체라 새 클러스터에서는 `bootstrap_cluster_creator_admin_permissions`로 자동 부여**된다(수작업 3단계의 `create-access-entry` 불필요).

## 6. 네트워크와 보안 그룹

- 기본 VPC `172.31.0.0/16`, 서브넷 4개 모두 `kubernetes.io/role/elb=1` 태그(ALB가 서브넷을 찾는 용도).
- **기본 보안 그룹**에 인바운드를 추가해 썼다.

  | 규칙 | 원본 |
  |---|---|
  | 전체 | 자기 자신(같은 그룹) |
  | TCP 3306 (MySQL) | 클러스터 보안 그룹, `<내 공인 IP>/32`(PC에서 직접 접속용) |
  | TCP 2049 (NFS) | VPC 전체 `172.31.0.0/16` |

- Terraform은 기본 보안 그룹을 고치지 않고 **전용 보안 그룹**을 새로 만든다(남의 설정을 건드리지 않고 `destroy`로 깔끔히 지우기 위해).

## 7. EFS `efs-volume`

| 항목 | 값 |
|---|---|
| 성능 | generalPurpose, 처리량 **elastic**, 암호화 켜짐 |
| 마운트 대상 | 서브넷 4개 모두 |
| 용도 | StorageClass `efs-sc` → Image 서버 PVC(RWX 5Gi) |

## 8. RDS `sns-db`

| 항목 | 값 |
|---|---|
| 엔진 | MariaDB **11.8.8** |
| 클래스 | `db.t4g.micro` (**`max_connections` 약 28~30** → 서비스의 DB 연결 풀을 3으로 제한한 이유) |
| 스토리지 | 20 GiB gp2, 암호화 켜짐 |
| 마스터 사용자 | `admin` (비밀번호는 조회 불가), **초기 DB 없음** |
| 공개 | **아니오**(PubliclyAccessible=false). VPC 밖에서 접속 불가 |
| Multi-AZ | 아니오, 백업 보존 1일 |
| 파라미터 그룹 | `default.mariadb11.8` |
| 테이블 | 클러스터 안에서 `part3-infra/ddl.sql`로 생성 (`sns` DB) |

## 9. ECR 저장소 6개

`sns-frontend`, `image-server`, `timeline-server`, `feed-server`, `notification-batch`, `user-server`. 태그 변경 가능(MUTABLE), push 시 스캔 꺼짐. **저장소를 지우면 이미지도 사라지므로** 다시 만들면 각 서비스에서 `./gradlew jib`로 다시 push해야 한다.

## 10. Terraform이 만들지 않는 것 (코드화에서 제외)

| 항목 | 이유 |
|---|---|
| `kubecost` 애드온 | CREATE_FAILED, 구독 필요 |
| ALB, ENI 등 Kubernetes가 만든 리소스 | 클러스터가 만들고 지운다. `destroy` 전에 `helm uninstall`로 먼저 지운다 |
| RDS·EFS의 **데이터** | 코드가 아니라 데이터. 스냅샷 복원 또는 `ddl.sql`·테스트 데이터 생성기로 채움 |
| ECR **이미지** | `jib`로 다시 push |
| 비밀번호, Secret 값 | 변수(`TF_VAR_*`)와 별도 보관 |
| Redis, Kafka, `sns-chart` | 2단계(`../k8s/`)에서 Helm으로 |
