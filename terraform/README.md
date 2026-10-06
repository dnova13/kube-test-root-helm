# Terraform: SNS 프로젝트 AWS 인프라 한 번에 만들기

> 2026-10-06 작성. **코드만 작성했고 `init`/`validate`/`plan`/`apply`는 한 번도 실행하지 않았다.** 동작 여부는 아직 모른다. 처음 실행할 때 나오는 오류는 이 문서에 적어 가며 고친다.
> 목적: AWS를 내렸다가 다시 올릴 때 `클러스터_재생성_체크리스트.md`의 수작업 10단계 중 AWS 쪽(1~7단계)을 코드로 대체한다.
> 현재 구성의 근거: [docs/현재_AWS_구성_요약.md](docs/현재_AWS_구성_요약.md). 수작업 순서: `part3-infra/docs/클러스터_재생성_체크리스트.md`.

## 만드는 것 (`aws/`)

| 파일 | 만드는 것 |
|---|---|
| `iam.tf` | 클러스터 Role, Auto Mode 노드 Role, 노드 그룹 Role, EFS CSI Role, **OIDC 공급자** |
| `eks.tf` | EKS 클러스터(Auto Mode), 관리형 노드 그룹, 애드온 6개 |
| `network.tf` | 서브넷 ALB 태그, RDS·EFS용 전용 보안 그룹 |
| `efs.tf` | EFS 파일 시스템과 서브넷별 마운트 대상 |
| `rds.tf` | MariaDB 11.8 `db.t4g.micro` (비공개) |
| `ecr.tf` | ECR 저장소 6개 |
| `outputs.tf` | 이후 단계에서 쓸 값(EFS ID, RDS 주소, ECR 주소, kubeconfig 명령) |

- 수작업의 가장 큰 함정이던 **새 클러스터의 OIDC ID 갱신**(체크리스트 4단계)과 **Access Entry**(3단계)는 코드가 자동으로 처리한다.
- 기본 VPC와 서브넷은 읽어서 쓰고, 기본 보안 그룹은 건드리지 않는다.
- 애드온은 노드가 뜨기 전에 필요한 것(`vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`)과 노드가 있어야 Ready가 되는 것(`coredns`, `metrics-server`, `aws-efs-csi-driver`)으로 나눠 순서를 잡았다.
- `kubecost` 애드온은 Marketplace 구독이 필요해 만들지 않는다.

## 만들지 못하는 것

| 항목 | 방법 |
|---|---|
| RDS 데이터 | 스냅샷 복원(`db_snapshot_identifier`) 또는 `ddl.sql` + 테스트 데이터 생성기 |
| ECR 이미지 | 각 서비스에서 `./gradlew jib` |
| Secret 값(DB·Kafka·SMTP) | `kubectl apply`, 비밀번호는 안전한 곳에 따로 보관 |
| Redis, Kafka, `sns-chart` | `helm` (아래 3단계. 2단계 `k8s/` 코드화는 아직 안 함) |
| StorageClass `efs-sc`, ExternalName `mariadb` | `kubectl apply` (output의 값을 넣는다) |

## AWS를 내리기 전에 (필수)

1. **RDS 데이터는 스냅샷 대신 덤프 파일로 보관한다.** 이미 `terraform/data/sns-dump.sql`에 받아 두었다(2026-10-06, git 제외). 받는 법·복원하는 법·검증 결과는 [docs/DB_덤프_복원_방법.md](docs/DB_덤프_복원_방법.md). 테스트 계정(`test` / `test@test.com` / `1q2w3e4r`)도 이 문서에 있다. (스냅샷 복원 옵션 `db_snapshot_identifier`는 코드에 남아 있지만 쓰지 않는다.)
2. 비밀값(DB 비밀번호, SMTP 계정, Kafka 비밀번호)을 비밀번호 관리자에 보관한다.
3. 차트와 문서를 git에 push해 둔다(`sns-chart/`, 이 `terraform/`).
4. 클러스터의 Ingress(ALB)를 먼저 지운다 — `helm uninstall sns -n sns`. ALB·ENI가 남으면 삭제가 막힌다.

## 사용법

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars      # 필요한 값만 채운다
export TF_VAR_db_password='...'                   # 비밀번호는 환경변수로

terraform init
terraform validate
terraform plan                                    # 무엇이 만들어지는지 확인 (비용 없음)
terraform apply                                   # 비용 발생. 직접 실행 (클러스터 10~20분 + 노드 10분)
```

- **기존 스택이 살아 있는 동안 시험하려면** `terraform.tfvars`에 `name = "sns-tf"`를 준다. 기본값 `sns`는 기존 `sns-db`와 이름이 겹쳐 RDS 생성이 실패한다. 단, 두 벌이 동시에 떠 비용이 두 배다.
- 기존 스택을 지운 뒤에는 기본값(`sns`) 그대로 쓴다.

## apply 이후 (수작업으로 남는 부분)

> **전체 순서와 명령은 [docs/재생성_후_세팅_순서.md](docs/재생성_후_세팅_순서.md)**, 자동으로 하는 스크립트는 `scripts/bootstrap.sh`(미리보기 → `--execute`)다. 아래는 옛 요약이라 문서를 먼저 본다.

```bash
# 1) kubeconfig
$(terraform output -raw kubeconfig_command)
kubectl get nodes

# 2) 공용 자원: 네임스페이스, ExternalName, StorageClass
kubectl create namespace infra && kubectl create namespace sns
#   - ExternalName mariadb: externalName = terraform output -raw rds_address
#   - efs-sc.yaml의 fileSystemId = terraform output -raw efs_file_system_id

# 3) Redis, Kafka (Helm), Secret 3개, 서비스
#    체크리스트 8~9단계 참고. 서비스는: helm upgrade --install sns ./sns-chart -n sns   (Helm_배포_치트시트.md)
#    sns-chart/values.yaml의 global.imageRegistry는 terraform output ecr_registry 와 같아야 한다

# 4) 이미지: 각 서비스 build.gradle의 ECR 주소를 맞춘 뒤 ./gradlew jib

# 5) DB 테이블: ddl.sql 적용 (클러스터 안에서)
```

## 지울 때

> 제거 방식의 비교(`teardown.sh` vs `terraform destroy`), 선택 기준, 지우기 전후 점검은 **[docs/AWS_제거_방식.md](docs/AWS_제거_방식.md)**에 정리했다. 아래는 요약이다.

### 전부 내리기: `scripts/teardown.sh` (AWS CLI로 이름을 지정해 지운다, `terraform destroy`는 쓰지 않는다)

AWS에 떠 있는 환경을 **전부** 내려 과금을 멈춘다. Terraform으로 만든 환경(`sns-cluster` 등)과 수작업으로 만든 옛 환경(`test-cluster`, 옛 IAM Role, 옛 EFS 등)을 모두 지운다. 순서는 Helm 릴리스·ALB → 노드 그룹·클러스터 → RDS → EFS → ECR → IAM Role·OIDC → 보안 그룹이고, 마지막에 남은 리소스를 조회한다. 자세한 사용법은 [scripts/README.md](scripts/README.md).

```bash
cd terraform/scripts
./teardown.sh                    # 미리보기(기본). 지울 대상과 명령만 출력하고 아무것도 지우지 않는다
./teardown.sh --execute          # 전부 삭제. 시작 시 delete-all 을 직접 입력해야 한다
./teardown.sh --only 8           # 점검만 (남은 리소스 조회)
```

- 지우기 전에 확인하는 것: RDS 덤프(`data/sns-dump.sql`), SMTP 계정 보관 파일, 커밋하지 않은 변경. 덤프가 없으면 `--execute`는 중단한다(`ALLOW_NO_DUMP=1`로만 강제 가능). 실행하면 로그가 `scripts/logs/`에 남는다.
- **지우지 않는 것**: IAM 사용자와 Access Key(Terraform 실행에 필요), SES 설정, 기본 VPC·서브넷, 서브넷의 ALB 태그, 로컬 파일.
- 이 버전의 `--execute`는 아직 실제로 실행해 본 적이 없다(미리보기만 확인). 단계마다 실패하면 메시지를 남기고 계속 가므로, 끝난 뒤 8단계 점검 결과를 꼭 본다.
- **다시 올릴 때**: 이 스크립트는 CLI로 지우므로 `terraform/aws/terraform.tfstate`가 이미 없어진 리소스를 기억한 채 남는다. 깔끔하게 하려면 `rm terraform/aws/terraform.tfstate*` 후 `terraform apply`로 새로 시작한다(state 파일은 git에 올라가지 않는다).

### Terraform으로만 내리기: `terraform destroy` (대안)

`teardown.sh` 대신 Terraform으로 지울 수도 있다. **`terraform destroy`만으로는 부족하고, 앞에 클러스터 안 정리가 필요하다.** (이 방법은 아직 한 번도 실행해 보지 않았다.)

```bash
# 1) 클러스터 안 정리 (필수). Terraform은 클러스터 안에서 만들어진 AWS 리소스(ALB, 볼륨)를 모른다
helm uninstall sns -n sns                       # Ingress(ALB)와 이미지 PVC가 함께 지워진다
helm uninstall kafka redis -n infra
kubectl get ingress,pvc -A                      # 비어 있어야 한다
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName'   # k8s- 로 시작하는 ALB 가 없어야 한다

# 2) Terraform 이 만든 것 전부 삭제 (직접 실행, 내용 확인 후 yes)
cd terraform/aws
terraform destroy -var db_password=unused       # destroy 는 비밀번호를 쓰지 않지만 필수 변수라 아무 값이나 넘긴다
```

| 구분 | 내용 |
|---|---|
| **destroy가 지우는 것** (state에 있는 것) | EKS 클러스터·노드 그룹·애드온, EFS(마운트 대상 포함), RDS(마지막 스냅샷 없음, 기본값 `db_skip_final_snapshot = true`), ECR 저장소 6개(이미지 포함, `force_delete = true`), IAM Role 4개와 OIDC 공급자, 전용 보안 그룹 `sns-data`, 서브넷 ALB 태그 |
| **destroy가 지우지 못하는 것** | ① **1)을 안 했을 때의 ALB·볼륨**(클러스터가 만든 것이라 state에 없어서 과금이 계속됨) ② **옛 환경 잔여물**(옛 EFS, 옛 IAM Role, 옛 OIDC, 기본 보안 그룹의 옛 규칙)은 state에 없다 → `teardown.sh --only 4`, `--only 6`, `--only 7` 또는 콘솔로 정리 ③ IAM 사용자와 Access Key, SES 설정(원래 지우지 않는 것) |
| 지워지지 않는 로컬 파일 | `terraform/data/sns-dump.sql`, `ses-smtp.secret.env`, 코드, 문서 |

- 끝난 뒤 `./teardown.sh --only 8`로 남은 리소스(특히 ALB, 미사용 EBS·ENI)를 점검한다.
- `teardown.sh`와 달리 destroy 뒤에는 state가 비어서 **다시 올릴 때 state를 지울 필요가 없다.**
- 지우기 전에 새로 쌓인 DB 데이터가 있으면 덤프를 다시 받는다(`docs/DB_덤프_복원_방법.md` 3절).

## 첫 `apply`에서 실제로 나온 오류와 해결 (2026-10-07)

기존 환경을 내린 직후 처음 `terraform apply`를 실행했다. IAM, EKS 클러스터, 노드 그룹, 애드온 6개, EFS, OIDC는 **오류 없이 만들어졌다**(애드온 순서 설계가 맞았다). 아래 두 가지만 실패했다.

| 오류 | 원인 | 해결 |
|---|---|---|
| `Security Group ... Character sets beyond ASCII are not supported` | 보안 그룹 `description`에 한글을 썼다. AWS는 이 필드에 ASCII만 허용한다 | `network.tf`의 description을 영어로 수정. **AWS로 전달되는 문자열(이름, 설명, 태그)에는 한글을 쓰지 않는다.** `outputs.tf`·`variables.tf`의 description은 Terraform 내부용이라 한글이어도 된다 |
| `RepositoryAlreadyExistsException` (ECR 6개) | 기존 환경의 ECR 저장소가 아직 남아 있었다(**이미지 2~4개씩 보존 중**) | 지우지 않고 **import**: `terraform import 'aws_ecr_repository.this["feed-server"]' feed-server` 등 6개. 이미지가 그대로 유지된다 |

- 보안 그룹이 실패해서 그것에 의존하는 RDS, EFS 마운트 대상, 보안 그룹 규칙은 만들어지지 않았다. 수정 후 `plan`은 **9개 추가, 6개 변경(ECR 설정), 0개 삭제**로 오류 없이 통과했다.
- 새로 처음부터 만드는 환경(모든 것을 지운 뒤)에서는 ECR도 import 없이 그냥 만들어진다. import는 옛 저장소가 남아 있던 이번에만 필요했다.
- 기존 환경과 **나란히** 만들면 ECR(이름 고정)과 RDS(`sns-db`)가 충돌한다. 기존 것을 먼저 지우거나 import한다.

## 재생성 후 이어서 실제로 한 순서와 결과 (2026-10-07)

`terraform apply`가 끝난 뒤 아래 순서로 클러스터를 채웠고 모두 성공했다. 새 환경에서 서비스가 정상 동작하고 복원한 데이터가 조회되는 것까지 확인했다.

| 순서 | 한 일 | 결과 |
|---|---|---|
| 1 | `aws eks update-kubeconfig` → `kubectl get nodes` | 노드 3대 Ready |
| 2 | 네임스페이스 `infra`·`sns`, ExternalName `mariadb`(`terraform output rds_address`), StorageClass `efs-sc`(`terraform output efs_file_system_id`) | 생성 |
| 3 | Secret 3개(`mysql`·`kafka`는 저장소 YAML, `email`은 `ses-smtp.secret.env`에서 `--from-env-file`), IngressClass `alb`, Redis·Kafka(Helm) | Pod 모두 Running |
| 4 | RDS 복원: **마스터(`admin`)로 `sns-server` 계정 생성 → 덤프 복원** ([docs/DB_덤프_복원_방법.md](docs/DB_덤프_복원_방법.md)) | 행 수가 원본과 같음 |
| 5 | `helm upgrade --install sns ./sns-chart -n sns` | Pod 모두 Running, 헬스체크 `ready`, PVC Bound, 이미지는 ECR에 보존된 것을 그대로 사용 |

- **`efs-sc.yaml`의 `fileSystemId`는 저장소에 자리표시자(`fs-000000000000`)로 있다.** 새 EFS ID로 바꾼 **사본**을 만들어 적용하고 저장소 파일은 건드리지 않았다(`sed`로 임시 폴더에 생성).
- **마스터 비밀번호와 `sns-server`(서비스 계정) 비밀번호는 별개다.** 마스터(`TF_VAR_db_password`)는 복원·계정 생성에만 쓰고, 서비스는 `mysql-secret`의 `sns-server` 계정을 쓴다.
- 복원 후 **Timeline 화면은 비어 있다**(Redis·Kafka가 새로 생겨서). `GET /api/feeds`(DB 조회)는 1,003개가 나온다.
- 이 순서는 아직 스크립트로 묶지 않았다. 수작업이 남아 있는 부분이다.

## 알려진 위험 (아직 검증하지 못함)

- **Kubernetes 1.36 + AL2023 조합과 `c7i-flex.large`가 시점에 따라 막힐 수 있다.** `plan`/`apply`로 확인한다. 안 되면 `kubernetes_version`, `node_instance_type`을 바꾼다.
- AWS provider 버전은 `~> 6.0`으로 적었다. `init`에서 받는 버전과 `aws_eks_cluster`(Auto Mode) 인수 이름이 어긋나면 `validate`가 알려 준다.
- Auto Mode와 관리형 노드 그룹을 함께 쓰는 현재 구성을 그대로 옮겼다. 처음 생성 시 애드온 순서(`early` → 노드 그룹 → `late`)가 맞는지 `apply`로만 확인할 수 있다.
- Terraform 상태(`terraform.tfstate`)는 **로컬 파일**이다. 지우면 만든 리소스를 Terraform이 잊는다. 비밀번호가 들어 있어 git에 올리지 않는다(`.gitignore` 등록됨).
- `ignore_changes`로 노드 수(`desired_size`)와 DB 비밀번호는 콘솔에서 바꿔도 되돌리지 않게 했다.

## 다음 할 일

- [ ] `terraform init` / `validate` / `plan` 실행과 오류 수정
- [ ] 시험 `apply`(기존 스택과 나란히 또는 삭제 후)로 실제 생성 검증
- [ ] 2단계 `k8s/`: Redis, Kafka, `sns-chart`를 `helm_release`로 코드화
- [ ] 검증이 끝나면 `클러스터_재생성_체크리스트.md`의 1~7단계를 이 코드로 대체했다고 표시
