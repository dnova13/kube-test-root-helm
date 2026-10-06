#!/usr/bin/env bash
# ============================================================
# AWS 전체 정리 스크립트: sns 실습 환경을 의존성 역순으로 전부 내려 과금을 멈춘다.
# AWS CLI로 이름을 지정해 지운다 (terraform destroy는 쓰지 않는다).
# Terraform으로 만든 환경(sns-cluster 등)과 수작업으로 만든 옛 환경(test-cluster 등)을 모두 지운다.
#
#   ./teardown.sh                  # 미리보기(기본). 지울 대상과 실행할 명령만 출력하고 아무것도 지우지 않는다
#   ./teardown.sh --execute        # 실제로 전부 삭제. 시작 전에 delete-all 을 직접 입력해야 한다
#   ./teardown.sh --only 3         # 한 단계만 (미리보기든 실행이든 함께 쓴다)
#   ./teardown.sh --execute --only 8   # 8단계는 조회만 하므로 언제 실행해도 안전하다
#
# 단계: 1 클러스터 안(Helm, Ingress/ALB, PVC)  2 노드 그룹·클러스터  3 RDS  4 EFS  5 ECR  6 IAM(Role, OIDC)
#       7 보안 그룹(전용 그룹 sns-data, 기본 그룹의 옛 규칙)  8 남은 리소스 점검(조회만)
#
# 지우지 않는 것: IAM 사용자와 Access Key(Terraform·CLI 실행에 필요), SES 설정, 기본 VPC/서브넷, 로컬 파일
# 삭제는 되돌릴 수 없다. 먼저 미리보기를 읽는다. 실행하면 로그가 terraform/scripts/logs/ 에 남는다.
# 다시 올릴 때: terraform/aws 의 state 파일이 이미 지운 리소스를 기억하고 있다. terraform apply가 알아서 다시 만들지만
#   깔끔하게 하려면 terraform/aws/terraform.tfstate* 를 지우고 시작한다 (README 참고).
# ============================================================
set -uo pipefail

REGION="ap-northeast-2"
# EKS 클러스터: Terraform으로 만든 것(sns-cluster)과 수작업 옛 환경(test-cluster)
CLUSTERS="sns-cluster test-cluster"
DB_IDS="sns-db"
# EFS 이름: Terraform으로 만든 것(sns-efs-volume)과 옛 것(efs-volume)
EFS_NAMES="sns-efs-volume efs-volume"
ECR_REPOS="feed-server user-server image-server timeline-server notification-batch sns-frontend"
# Terraform 환경(sns-eks-*, sns-efs-*)과 옛 환경(철자가 다른 이름)의 Role. 이미 없으면 건너뛴다
IAM_ROLES="sns-eks-cluster-role sns-eks-auto-node-role sns-eks-node-role sns-efs-csi-driver-role EKS-Cluster-role eks-node-rule sns-node-rule AmazoneEKS-EFS-CSI-DriverRole"
# Terraform이 만든 RDS·EFS용 전용 보안 그룹 이름
DATA_SG_NAME="sns-data"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TF_DIR/.." && pwd)"
DUMP="$TF_DIR/data/sns-dump.sql"
SES_FILE="$REPO_ROOT/part3-notification-batch/ses-smtp.secret.env"

EXECUTE=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $1 (-h 로 도움말)"; exit 2 ;;
  esac
  shift
done

# 실행 모드는 화면 출력을 로그 파일에도 남긴다 (중간에 끊겨도 어디까지 됐는지 알 수 있다)
if [ "$EXECUTE" = 1 ]; then
  mkdir -p "$SCRIPT_DIR/logs"
  LOG="$SCRIPT_DIR/logs/teardown-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  echo "로그: $LOG"
fi

step_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
title() { echo; echo "=== $*"; }
note()  { echo "  - $*"; }
# 명령을 보여 주고, --execute일 때만 실제로 실행한다
run() {
  local shown="$*"
  echo "  \$ ${shown//aws_ /aws --region $REGION }"
  if [ "$EXECUTE" = 1 ]; then "$@" || echo "  ! 실패(종료 코드 $?): 위 명령 확인 후 다시 실행하세요"; fi
}
aws_() { aws --region "$REGION" "$@"; }

cluster_exists() { aws_ eks describe-cluster --name "$1" >/dev/null 2>&1; }

if [ "$EXECUTE" = 1 ]; then echo "[실행 모드] 실제로 삭제합니다."; else echo "[미리보기 모드] 아무것도 지우지 않습니다. 실제 삭제는 --execute"; fi

# ------------------------------------------------------------
# 사전 점검
# ------------------------------------------------------------
title "사전 점검"
ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT" ]; then echo "  AWS 자격 증명을 확인할 수 없습니다(aws configure). 중단합니다."; exit 1; fi
note "AWS 계정 ${ACCOUNT:0:4}****${ACCOUNT: -2}, 리전 $REGION"

DUMP_OK=0
if [ -s "$DUMP" ] && tail -1 "$DUMP" | grep -q "Dump completed"; then
  DUMP_OK=1; note "RDS 덤프 정상: $DUMP ($(wc -c < "$DUMP") bytes)"
else
  echo "  ! RDS 덤프가 없거나 끝까지 받지 못했습니다: $DUMP"
fi
[ -f "$SES_FILE" ] && note "SMTP 계정 보관 파일 있음: part3-notification-batch/ses-smtp.secret.env (삭제하지 마세요)" \
                   || echo "  ! SMTP 계정 보관 파일이 없습니다. 클러스터의 email-secret에만 값이 있다면 지우기 전에 따로 보관하세요"
if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "  ! 루트 저장소에 커밋하지 않은 변경이 있습니다(terraform/, sns-chart/ 등). 로컬 파일은 지워지지 않지만 push해 두는 것이 안전합니다"
fi
for c in $CLUSTERS; do
  if cluster_exists "$c"; then note "EKS 클러스터 $c 존재 (삭제 대상)"; else note "EKS 클러스터 $c 없음"; fi
done

if [ "$EXECUTE" = 1 ]; then
  if [ "$DUMP_OK" = 0 ] && [ "${ALLOW_NO_DUMP:-0}" != 1 ]; then
    echo; echo "덤프가 없어서 중단합니다. 그래도 지우려면 ALLOW_NO_DUMP=1 로 다시 실행하세요."; exit 1
  fi
  echo
  echo "다음을 모두 삭제합니다: Helm 릴리스(ALB 포함), EKS 클러스터와 노드 그룹($CLUSTERS), RDS($DB_IDS), EFS($EFS_NAMES),"
  echo "ECR 저장소 6개(이미지 포함), IAM Role, EKS OIDC 공급자, 전용 보안 그룹($DATA_SG_NAME)과 기본 보안 그룹의 옛 규칙"
  printf "계속하려면 delete-all 을 정확히 입력하세요: "
  read -r ANSWER
  if [ "$ANSWER" != "delete-all" ]; then echo "입력이 달라 중단합니다."; exit 1; fi
fi

# ------------------------------------------------------------
# 1) 클러스터 안: Helm 릴리스, Ingress, PVC 삭제 (ALB를 먼저 지워야 VPC 삭제가 막히지 않는다)
#    클러스터마다 임시 kubeconfig를 만들어 쓰므로 ~/.kube/config(현재 컨텍스트)는 바꾸지 않는다
# ------------------------------------------------------------
if step_enabled 1; then
  title "1) 클러스터 안 정리 (Helm 릴리스, Ingress, PVC)"
  for c in $CLUSTERS; do
    if ! cluster_exists "$c"; then note "클러스터 $c 없음, 건너뜀"; continue; fi
    KC="$(mktemp)"
    if ! aws_ eks update-kubeconfig --name "$c" --kubeconfig "$KC" >/dev/null 2>&1; then
      echo "  ! 클러스터 $c 의 접속 정보를 만들지 못했습니다. 건너뜁니다"; rm -f "$KC"; continue
    fi
    export KUBECONFIG="$KC"
    note "클러스터 $c"
    RELS="$(helm list -A 2>/dev/null | awk 'NR>1{print $1" "$2}')"
    if [ -z "$RELS" ]; then
      note "Helm 릴리스 없음"
    else
      echo "$RELS" | while read -r rel ns; do
        run helm uninstall "$rel" -n "$ns" --wait --timeout 5m
      done
    fi
    # 릴리스로 지워지지 않고 남은 Ingress(ALB)와 PVC(EBS/EFS 액세스 포인트)
    if kubectl get ingress -A --no-headers 2>/dev/null | grep -q .; then
      run kubectl delete ingress -A --all --wait=true --timeout=5m
    fi
    if kubectl get pvc -A --no-headers 2>/dev/null | grep -q .; then
      run kubectl delete pvc -A --all --wait=true --timeout=5m
    fi
    unset KUBECONFIG; rm -f "$KC"
  done

  title "1-b) ALB가 사라질 때까지 대기"
  ALB_QUERY='LoadBalancers[?starts_with(LoadBalancerName, `k8s-`)].LoadBalancerName'
  echo "  \$ aws elbv2 describe-load-balancers --query '$ALB_QUERY'"
  if [ "$EXECUTE" = 1 ]; then
    for i in $(seq 1 20); do
      LBS="$(aws_ elbv2 describe-load-balancers --query "$ALB_QUERY" --output text 2>/dev/null)"
      if [ -z "$LBS" ]; then note "ALB 없음"; break; fi
      note "ALB 남아 있음($LBS), 30초 후 다시 확인 ($i/20)"; sleep 30
    done
    LBS="$(aws_ elbv2 describe-load-balancers --query "$ALB_QUERY" --output text 2>/dev/null)"
    if [ -n "$LBS" ]; then echo "  ! ALB가 남아 있어 중단합니다. 콘솔(EC2 > 로드밸런서)에서 확인 후 다시 실행하세요: $LBS"; exit 1; fi
  fi
fi

# ------------------------------------------------------------
# 2) 노드 그룹 -> 클러스터 (애드온은 클러스터와 함께 지워진다)
# ------------------------------------------------------------
if step_enabled 2; then
  title "2) 노드 그룹과 클러스터 삭제 (각 10~20분)"
  FOUND=0
  for c in $CLUSTERS; do
    if cluster_exists "$c"; then
      FOUND=1
      for ng in $(aws_ eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]' --output text 2>/dev/null); do
        run aws_ eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng"
        run aws_ eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng"
      done
      run aws_ eks delete-cluster --name "$c"
      run aws_ eks wait cluster-deleted --name "$c"
    fi
  done
  [ "$FOUND" = 0 ] && note "남은 클러스터 없음"
fi

# ------------------------------------------------------------
# 3) RDS (덤프를 받아 뒀으므로 최종 스냅샷 없이 삭제)
# ------------------------------------------------------------
if step_enabled 3; then
  title "3) RDS 삭제 (최종 스냅샷 없음, 데이터는 덤프로 복원)"
  FOUND=0
  for db in $DB_IDS; do
    if aws_ rds describe-db-instances --db-instance-identifier "$db" >/dev/null 2>&1; then
      FOUND=1
      run aws_ rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups
      run aws_ rds wait db-instance-deleted --db-instance-identifier "$db"
    fi
  done
  [ "$FOUND" = 0 ] && note "남은 RDS 없음"
fi

# ------------------------------------------------------------
# 4) EFS: 마운트 대상을 먼저 지운 뒤 파일 시스템 삭제 (이름이 겹치는 것은 모두 지운다)
# ------------------------------------------------------------
if step_enabled 4; then
  title "4) EFS 삭제"
  FOUND=0
  for name in $EFS_NAMES; do
    for FSID in $(aws_ efs describe-file-systems --query "FileSystems[?Name=='$name'].FileSystemId" --output text 2>/dev/null); do
      [ -z "$FSID" ] || [ "$FSID" = "None" ] && continue
      FOUND=1
      note "파일 시스템 $FSID ($name)"
      for mt in $(aws_ efs describe-mount-targets --file-system-id "$FSID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null); do
        run aws_ efs delete-mount-target --mount-target-id "$mt"
      done
      if [ "$EXECUTE" = 1 ]; then
        for i in $(seq 1 30); do
          LEFT="$(aws_ efs describe-mount-targets --file-system-id "$FSID" --query 'length(MountTargets)' --output text 2>/dev/null)"
          [ "$LEFT" = "0" ] && break
          note "마운트 대상 삭제 대기 (남은 ${LEFT}개, $i/30)"; sleep 10
        done
      fi
      run aws_ efs delete-file-system --file-system-id "$FSID"
    done
  done
  [ "$FOUND" = 0 ] && note "남은 EFS 없음"
fi

# ------------------------------------------------------------
# 5) ECR 저장소 (이미지 포함. 이미지는 ./gradlew jib로 다시 만들 수 있다)
# ------------------------------------------------------------
if step_enabled 5; then
  title "5) ECR 저장소 삭제 (--force, 이미지 포함)"
  FOUND=0
  for repo in $ECR_REPOS; do
    if aws_ ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1; then
      FOUND=1
      run aws_ ecr delete-repository --repository-name "$repo" --force
    fi
  done
  [ "$FOUND" = 0 ] && note "남은 ECR 저장소 없음"
fi

# ------------------------------------------------------------
# 6) IAM: Role(정책 분리 후 삭제)과 OIDC 공급자. 사용자와 Access Key는 지우지 않는다
# ------------------------------------------------------------
if step_enabled 6; then
  title "6) IAM Role과 OIDC 공급자 삭제"
  FOUND=0
  for role in $IAM_ROLES; do
    if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      FOUND=1
      for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
        run aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
      done
      for pol in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
        run aws iam delete-role-policy --role-name "$role" --policy-name "$pol"
      done
      run aws iam delete-role --role-name "$role"
    fi
  done
  [ "$FOUND" = 0 ] && note "남은 대상 Role 없음"

  # EKS OIDC 공급자: 클러스터가 하나도 남지 않았을 때만 모두 지운다 (클러스터가 쓰는 공급자를 지우지 않도록)
  LEFT_CLUSTERS="$(aws_ eks list-clusters --query 'clusters' --output text 2>/dev/null)"
  OIDC_LIST="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null | tr '\t' '\n' | grep 'oidc-provider/oidc.eks.' || true)"
  if [ -z "$OIDC_LIST" ]; then
    note "남은 EKS OIDC 공급자 없음"
  elif [ -n "$LEFT_CLUSTERS" ] && [ "$LEFT_CLUSTERS" != "None" ]; then
    note "EKS 클러스터가 남아 있어($LEFT_CLUSTERS) OIDC 공급자는 지우지 않습니다. 클러스터 삭제 후 다시 실행하세요"
  else
    echo "$OIDC_LIST" | while read -r arn; do
      run aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn"
    done
  fi
  note "IAM 사용자와 Access Key는 Terraform 실행에 필요해서 지우지 않습니다"
fi

# ------------------------------------------------------------
# 7) 보안 그룹: Terraform이 만든 전용 그룹(sns-data)과, 기본 보안 그룹에 추가했던 옛 인바운드 규칙(3306, 2049)
#    전용 그룹은 RDS·EFS 마운트 대상이 먼저 지워진 뒤에만 지워진다 (3, 4단계 뒤)
# ------------------------------------------------------------
if step_enabled 7; then
  title "7) 보안 그룹 정리"
  VPC="$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"

  DATA_SG="$(aws_ ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$DATA_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$DATA_SG" ] || [ "$DATA_SG" = "None" ]; then
    note "전용 보안 그룹 $DATA_SG_NAME 없음"
  else
    run aws_ ec2 delete-security-group --group-id "$DATA_SG"
  fi

  SG="$(aws_ ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$SG" ] || [ "$SG" = "None" ]; then
    note "기본 보안 그룹을 찾지 못해 건너뜀"
  else
    RULES="$(aws_ ec2 describe-security-group-rules --filters Name=group-id,Values="$SG" \
      --query 'SecurityGroupRules[?IsEgress==`false` && (FromPort==`3306` || FromPort==`2049`)].SecurityGroupRuleId' --output text 2>/dev/null)"
    if [ -z "$RULES" ]; then
      note "기본 그룹에 정리할 옛 규칙 없음"
    else
      # shellcheck disable=SC2086
      run aws_ ec2 revoke-security-group-ingress --group-id "$SG" --security-group-rule-ids $RULES
    fi
  fi
  note "서브넷의 kubernetes.io/role/elb 태그는 비용이 없고 다시 올릴 때 Terraform이 같은 값을 쓰므로 그대로 둡니다"
fi

# ------------------------------------------------------------
# 8) 남은 리소스 점검 (조회만 한다)
# ------------------------------------------------------------
if step_enabled 8; then
  title "8) 남은 리소스 점검 (모두 비어 있어야 과금이 없다)"
  echo "  EKS 클러스터:        $(aws_ eks list-clusters --query 'clusters' --output text 2>/dev/null)"
  echo "  RDS 인스턴스:        $(aws_ rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null)"
  echo "  RDS 수동 스냅샷:     $(aws_ rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text 2>/dev/null)"
  echo "  EFS:                 $(aws_ efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text 2>/dev/null)"
  echo "  ECR 저장소:          $(aws_ ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null)"
  echo "  로드밸런서(ALB/NLB): $(aws_ elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
  echo "  사용 안 하는 EBS:    $(aws_ ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text 2>/dev/null)"
  echo "  사용 안 하는 ENI:    $(aws_ ec2 describe-network-interfaces --filters Name=status,Values=available --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)"
  echo "  EC2 실행 중:         $(aws_ ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
  echo "  NAT 게이트웨이:      $(aws_ ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)"
  echo "  탄력적 IP(미연결):   $(aws_ ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' --output text 2>/dev/null)"
  echo "  EKS OIDC 공급자:     $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null | tr '\t' '\n' | grep -c 'oidc.eks.')개"
  echo "  전용 보안 그룹:      $(aws_ ec2 describe-security-groups --filters Name=group-name,Values="$DATA_SG_NAME" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)"
  echo "  IAM Role(대상):      $(for r in $IAM_ROLES; do aws iam get-role --role-name "$r" --query Role.RoleName --output text 2>/dev/null; done | tr '\n' ' ')"
  note "남은 항목이 있으면 콘솔에서 확인하고, 마지막에 Billing 대시보드에서 과금 항목을 보세요"
fi

echo
if [ "$EXECUTE" = 1 ]; then echo "완료. 마지막으로 ./teardown.sh --only 8 로 남은 것을 확인하세요."; else echo "미리보기 끝. 실제로 지우려면 ./teardown.sh --execute"; fi
