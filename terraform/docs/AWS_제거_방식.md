# AWS 제거 방식 (과금을 멈추려고 내릴 때)

> 2026-10-07. AWS에 올려 둔 sns 실습 환경을 내리는 **방법 두 가지**와 선택 기준, 지우는 것과 못 지우는 것, 지우기 전후 점검을 정리한 문서다.
> **두 방식 모두 실제 삭제를 이 버전으로 실행해 본 적은 없다.** 조회(미리보기)와 문법만 확인했다. 실제로 돌리면서 나온 오류는 이 문서와 `scripts/README.md`에 추가한다.
> 다시 올릴 때는 [재생성_후_세팅_순서.md](재생성_후_세팅_순서.md).

## 1. 지금 AWS에 있는 것 (2026-10-07 기준)

내릴 대상은 두 묶음이다.

| 묶음 | 내용 | 누가 만들었나 |
|---|---|---|
| **새 환경** | EKS `sns-cluster`와 노드 3대, RDS `sns-db`, EFS `sns-efs-volume`, ECR 저장소 6개, IAM Role 4개(`sns-eks-*`, `sns-efs-csi-driver-role`), OIDC 공급자, 보안 그룹 `sns-data`, ALB(Ingress) | `terraform apply`(ALB는 클러스터가 만든 것) |
| **옛 환경 잔여물** | EFS `efs-volume`(이미지 파일 약 202MB), IAM Role 4개(`EKS-Cluster-role`, `eks-node-rule`, `sns-node-rule`, `AmazoneEKS-EFS-CSI-DriverRole`), OIDC 공급자 1개, 기본 보안 그룹에 추가한 규칙 3개(3306, 2049) | 수작업(콘솔·CLI). Terraform은 모른다 |

핵심은 **Terraform state에 있는 것(새 환경)과 없는 것(옛 잔여물, ALB 등)이 섞여 있다**는 점이다. 이 차이가 두 방식의 차이를 만든다.

## 2. 두 방식 한눈에 비교

| | **A. `teardown.sh`** (AWS CLI로 이름 지정) | **B. `terraform destroy`** |
|---|---|---|
| 지우는 범위 | 새 환경 + 옛 잔여물 **전부** | **새 환경만** (state에 있는 것) |
| 클러스터 안(Helm, ALB, PVC) | 스크립트가 먼저 지운다 | **직접 먼저** `helm uninstall` 해야 한다 |
| 옛 잔여물 | 같이 지운다 | 못 지운다 → A의 4, 6, 7단계로 따로 정리 |
| 실행 후 state | 이미 없어진 리소스를 기억한 채 낡는다 → 다시 올릴 때 `rm terraform/aws/terraform.tfstate*` | **깨끗이 비워진다** |
| 안전장치 | 기본이 미리보기, `delete-all` 입력, 덤프 점검, ALB 대기, 로그 파일 | 실행 전 `terraform plan -destroy`로 지울 목록을 본다, `yes` 입력 |
| 한 번에 되는가 | 한 명령으로 1~7단계 | 두 명령 + A의 일부 |
| 단점 | state가 낡는다. 이름으로 지우므로 같은 이름이면 구분 없이 지운다 | 옛 잔여물이 남는다. 클러스터 안 정리를 빼먹으면 ALB가 남아 과금된다 |

### 선택 기준

| 상황 | 권장 |
|---|---|
| **옛 잔여물까지 전부 지우고 싶다** (지금 상태) | **A** (한 번에 끝남) |
| 새 환경만 내리고 state도 깔끔하게 두고 싶다 | B (필요하면 이어서 A의 `--only 4/6/7/8`) |
| 일부만 지운다(예: 옛 IAM Role만) | A의 `--only`로 단계를 고른다 |

## 3. 방식 A: `scripts/teardown.sh`

사용법과 문제 해결은 [../scripts/README.md](../scripts/README.md). 요약은 아래와 같다.

```bash
cd terraform/scripts
./teardown.sh                  # 1) 미리보기 (기본). 지울 대상과 명령만 출력하고 아무것도 지우지 않는다
./teardown.sh --execute        # 2) 전부 삭제. 시작 시 delete-all 을 직접 입력, 30~50분
./teardown.sh --only 8         # 3) 끝난 뒤 남은 리소스 점검 (조회만)
```

| 단계 | 지우는 것 | 대기 |
|---|---|---|
| 1 | Helm 릴리스 전부, 남은 Ingress(ALB)와 PVC → ALB가 사라질 때까지 대기 | 수 분 |
| 2 | 노드 그룹 → EKS 클러스터 (`sns-cluster`, `test-cluster`) | 각 10~20분 |
| 3 | RDS `sns-db` (최종 스냅샷 없음) | 수 분 |
| 4 | EFS 마운트 대상 → 파일 시스템 (`sns-efs-volume`, `efs-volume`) | 1~3분 |
| 5 | ECR 저장소 6개 (이미지 포함) | 즉시 |
| 6 | IAM Role 8개(새 4 + 옛 4), 클러스터가 없으면 EKS OIDC 공급자 | 즉시 |
| 7 | 전용 보안 그룹 `sns-data`, 기본 보안 그룹의 옛 규칙 | 즉시 |
| 8 | 남은 리소스 점검 (조회만) | 즉시 |

- 지우지 않는 것: IAM 사용자와 Access Key, SES 설정, 기본 VPC·서브넷, 서브넷의 ALB 태그, 로컬 파일.
- 로그는 `terraform/scripts/logs/`에 남는다(중간에 끊겨도 어디까지 됐는지 알 수 있다).

## 4. 방식 B: `terraform destroy`

```bash
# 1) 클러스터 안 정리 (필수). Terraform은 클러스터 안에서 만들어진 AWS 리소스(ALB, 볼륨)를 모른다
helm uninstall sns -n sns                  # Ingress(ALB)와 이미지 PVC가 함께 지워진다
helm uninstall kafka redis -n infra
kubectl get ingress,pvc -A                 # 비어 있어야 한다
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName'   # k8s- 로 시작하는 ALB 가 없어야 한다

# 2) 지울 목록을 먼저 본다 (조회만)
cd terraform/aws
terraform plan -destroy -var db_password=unused

# 3) 삭제 (직접 실행, 내용 확인 후 yes)
terraform destroy -var db_password=unused  # destroy 는 비밀번호를 쓰지 않지만 필수 변수라 아무 값이나 넘긴다
```

| 구분 | 내용 |
|---|---|
| **지우는 것** (state에 있는 것) | EKS 클러스터·노드 그룹·애드온 6개, EFS(마운트 대상 포함), RDS와 DB 서브넷 그룹(마지막 스냅샷 없음, 기본값 `db_skip_final_snapshot = true`), ECR 저장소 6개(이미지 포함, `force_delete = true`), IAM Role 4개와 OIDC 공급자, 전용 보안 그룹 `sns-data`와 규칙, 서브넷 ALB 태그 |
| **지우지 못하는 것** | ① 1)을 안 했을 때의 **ALB와 볼륨**(과금 계속) ② **옛 환경 잔여물** 전부 ③ IAM 사용자·Access Key·SES 설정 |

- destroy 뒤에는 state가 비어서 **다시 올릴 때 state를 지울 필요가 없다.**
- 옛 잔여물을 이어서 정리하려면: `./teardown.sh --execute --only 4`(옛 EFS), `--only 6`(옛 IAM Role), `--only 7`(옛 보안 그룹 규칙), 옛 OIDC 공급자는 6단계가 지운다(클러스터가 없을 때). 마지막에 `--only 8`로 점검.

## 5. 지우기 전에 확인할 것

| 확인 | 이유 | 방법 |
|---|---|---|
| **DB 덤프가 최신인가** | RDS를 지우면 데이터가 사라진다. 덤프 이후에 새로 쌓인 데이터는 덤프에 없다 | 덤프 시점 이후 데이터가 있으면 다시 받는다([DB_덤프_복원_방법.md](DB_덤프_복원_방법.md) 3절). `teardown.sh --execute`는 덤프 파일이 없으면 중단한다 |
| SMTP 계정 보관 파일 | 클러스터의 `email-secret`은 클러스터와 함께 사라진다 | `part3-notification-batch/ses-smtp.secret.env`가 있는지 |
| 코드·문서 커밋 | 로컬 파일은 지워지지 않지만 백업을 겸한다 | `terraform/`, `sns-chart/` 등을 커밋·push |
| **옛 EFS의 이미지 파일** | EFS를 지우면 복구할 수 없다(약 202MB) | 필요하면 지우기 전에 따로 백업. 필요 없으면 그대로 진행 |
| IAM 사용자·Access Key | 이것으로 다시 올린다 | **지우지 않는다.** 두 방식 모두 건드리지 않는다. 키 값은 다른 곳에도 보관 |
| ECR 이미지 | 저장소와 함께 사라진다 | 서비스 소스가 있으면 `./gradlew jib`로 다시 만들 수 있다 |

## 6. 지운 뒤 확인

```bash
cd terraform/scripts
./teardown.sh --only 8       # 조회만. 아래가 모두 비어 있어야 과금이 없다
```

| 항목 | 남아 있으면 |
|---|---|
| EKS 클러스터, RDS, EFS, ECR | 해당 단계를 다시 실행하거나 콘솔에서 삭제 |
| 로드밸런서(ALB/NLB) | 콘솔(EC2 > 로드밸런서)에서 삭제. B 방식에서 1)을 빼먹은 경우에 흔하다 |
| 사용 안 하는 EBS 볼륨, ENI, 미연결 탄력적 IP, NAT 게이트웨이 | 콘솔에서 삭제. ENI는 ALB·EFS 삭제 후 몇 분 뒤 사라진다 |
| 실행 중인 EC2 | 노드가 남은 것. 클러스터·노드 그룹 삭제가 끝났는지 확인 |
| EKS OIDC 공급자 | 클러스터가 없는데 남아 있으면 `--only 6` |
| 전용 보안 그룹 `sns-data` | RDS·EFS 삭제가 끝난 뒤 `--only 7` |

마지막에 **AWS Billing 대시보드**에서 과금 항목이 없는지도 본다(반영에는 하루쯤 걸린다).

## 7. 지워지지 않는 것 (남는 것)

| 항목 | 이유 |
|---|---|
| IAM 사용자와 Access Key, SES 설정(SMTP용 IAM 사용자 포함) | 다시 올리거나 메일을 보내는 데 필요. 두 방식 모두 지우지 않는다 |
| 기본 VPC, 서브넷 | 계정 기본 리소스, 비용 없음 |
| 로컬 파일 | `terraform/data/sns-dump.sql`, `ses-smtp.secret.env`, 코드, 문서. 어느 방식도 로컬 파일을 지우는 명령이 없다 |

## 8. 알려진 한계

- **두 방식 모두 실제 삭제는 아직 실행해 보지 않았다.** A는 미리보기에서 지울 대상이 의도와 일치하는 것만 확인했고(EKS, RDS, EFS 2개, ECR 6개, IAM Role 8개, 전용 보안 그룹, 보안 그룹 규칙 3개), B는 실행 자체를 해 본 적이 없다.
- A는 **이름으로 지우므로 같은 이름이면 구분 없이 지운다.** 새 환경의 RDS(`sns-db`)와 ECR도 지운다. 일부만 남기려면 `--only`로 단계를 고른다.
- 지우는 도중(RDS·클러스터는 몇 분~20분)에 실패하면 한 단계씩 다시 실행할 수 있지만, 실패 원인은 실제로 돌려 봐야 안다. 대응 표는 [../scripts/README.md](../scripts/README.md) 8절.
- Kubernetes가 만든 EBS 볼륨이나 ENI는 클러스터 삭제 뒤에도 남을 수 있어 6절 점검이 필요하다.
