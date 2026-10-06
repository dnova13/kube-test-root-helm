#!/usr/bin/env bash
# ============================================================
# terraform apply 이후 수작업을 한 번에 하는 스크립트.
# Terraform이 만든 AWS 위에 클러스터 안의 공용 자원, Secret, Redis·Kafka, DB 데이터, 서비스를 올린다.
#
#   ./bootstrap.sh                 # 미리보기(기본). 실행할 명령만 출력하고 아무것도 만들지 않는다
#   ./bootstrap.sh --execute       # 실제 실행 (DB 복원 때 마스터 비밀번호를 물어본다)
#   ./bootstrap.sh --only 4        # 한 단계만 (미리보기든 실행이든 함께 쓴다)
#   ./bootstrap.sh --execute --no-build   # ECR 에 이미지가 없을 때 자동 빌드·push 를 하지 않고 중단
#
# 단계: 0 서비스 이미지 확인 (ECR 에 없으면 jib/docker 로 빌드해서 push)
#       1 kubeconfig, 노드 확인   2 네임스페이스·ExternalName(RDS)·StorageClass(EFS)
#       3 Secret 3개·IngressClass·Redis·Kafka   4 RDS에 sns-server 계정 생성 + 덤프 복원
#       5 서비스 배포(helm sns-chart)   6 확인(헬스체크, ALB)
#
# 전제: terraform apply 완료, terraform/data/sns-dump.sql 있음, Docker Desktop 실행 중(이미지가 없을 때 빌드에 필요)
# 자세한 순서와 수동 명령: terraform/docs/재생성_후_세팅_순서.md
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_AWS_DIR="$TF_DIR/aws"
REPO_ROOT="$(cd "$TF_DIR/.." && pwd)"
DUMP="$TF_DIR/data/sns-dump.sql"
SES_FILE="$REPO_ROOT/part3-notification-batch/ses-smtp.secret.env"
CHART="$REPO_ROOT/sns-chart"
REGION="ap-northeast-2"

# 서비스 폴더의 Secret/매니페스트 원본
MYSQL_SECRET_YAML="$REPO_ROOT/part3-feed-server/mysql-secret.yaml"
KAFKA_SECRET_YAML="$REPO_ROOT/part3-feed-server/kafka-secert.yaml"   # 파일명 오타(secert)는 저장소 그대로
EFS_SC_YAML="$REPO_ROOT/part3-infra/efs-sc.yaml"
INGRESS_CLASS_YAML="$REPO_ROOT/part3-infra/manifests/ingress-class.yaml"

EXECUTE=0
ONLY=""
NO_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --no-build) NO_BUILD=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $1 (-h 로 도움말)"; exit 2 ;;
  esac
  shift
done

step_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
title() { echo; echo "=== $*"; }
note()  { echo "  - $*"; }
warn()  { echo "  ! $*"; }
die()   { echo "  ✗ $*"; exit 1; }

# 명령을 보여 주고, --execute일 때만 실행한다. 실패하면 중단한다 (순서가 있는 작업이라 다음으로 넘어가지 않는다)
run() {
  echo "  \$ $*"
  if [ "$EXECUTE" = 1 ]; then "$@" || die "실패(종료 코드 $?): 위 명령을 확인하고 해결한 뒤 --only 로 이 단계부터 다시 실행하세요"; fi
}
# 비밀값이 인자에 들어가는 명령: 화면에는 표시용 문장만 보여 준다. 사용: run_masked "표시" 명령 인자...
run_masked() {
  local shown="$1"; shift
  echo "  \$ $shown"
  if [ "$EXECUTE" = 1 ]; then "$@" || die "실패(종료 코드 $?): 위 명령을 확인하고 해결한 뒤 --only 로 이 단계부터 다시 실행하세요"; fi
}
# 파이프가 있는 명령 한 줄. 사용: run_sh "명령 문자열"
run_sh() {
  echo "  \$ $1"
  if [ "$EXECUTE" = 1 ]; then bash -c "$1" || die "실패(종료 코드 $?): 위 명령을 확인하고 해결한 뒤 --only 로 이 단계부터 다시 실행하세요"; fi
}

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

tfout() { terraform -chdir="$TF_AWS_DIR" output -raw "$1" 2>/dev/null; }

if [ "$EXECUTE" = 1 ]; then echo "[실행 모드] 실제로 클러스터와 DB를 변경합니다."; else echo "[미리보기 모드] 아무것도 만들지 않습니다. 실제 실행은 --execute"; fi

# ------------------------------------------------------------
# 사전 점검
# ------------------------------------------------------------
title "사전 점검"
for cmd in aws terraform kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd 가 설치되어 있지 않습니다"
done
aws --region "$REGION" sts get-caller-identity >/dev/null 2>&1 || die "AWS 자격 증명을 확인할 수 없습니다(aws configure)"
note "AWS 자격 증명 OK"

CLUSTER="$(tfout cluster_name)"
EFS_ID="$(tfout efs_file_system_id)"
RDS_ADDR="$(tfout rds_address)"
ECR_REGISTRY="$(tfout ecr_registry)"
if [ -z "$CLUSTER" ] || [ -z "$EFS_ID" ] || [ -z "$RDS_ADDR" ]; then
  die "terraform output 을 읽지 못했습니다. 먼저 terraform/aws 에서 terraform apply 를 끝내세요"
fi
note "클러스터 $CLUSTER, EFS $EFS_ID, RDS $RDS_ADDR"

for f in "$MYSQL_SECRET_YAML" "$KAFKA_SECRET_YAML" "$EFS_SC_YAML" "$INGRESS_CLASS_YAML" "$CHART/Chart.yaml"; do
  [ -f "$f" ] || die "필요한 파일이 없습니다: $f"
done
if step_enabled 4; then
  [ -s "$DUMP" ] && tail -1 "$DUMP" | grep -q "Dump completed" || die "RDS 덤프가 없거나 끝까지 받지 못했습니다: $DUMP"
  note "RDS 덤프 정상 ($(wc -c < "$DUMP") bytes)"
  # 서비스 계정 비밀번호는 SQL 문자열 안에 큰따옴표로 감싸 들어가므로 " 와 \ 가 있으면 SQL 이 깨진다
  SVC_PW="$(grep MYSQL_PASSWORD "$MYSQL_SECRET_YAML" | awk '{print $2}' | base64 -d 2>/dev/null)"
  [ -n "$SVC_PW" ] || die "mysql-secret YAML에서 MYSQL_PASSWORD 를 읽지 못했습니다"
  case "$SVC_PW" in
    *\"*|*\\*) die "mysql-secret 의 MYSQL_PASSWORD 에 \" 또는 \\ 가 들어 있어 계정 생성 SQL 이 깨집니다. 해당 문자를 뺀 비밀번호로 바꾸세요" ;;
  esac
  note "서비스 계정(sns-server) 비밀번호 형식 OK (${#SVC_PW}자)"
fi
if step_enabled 3; then
  [ -f "$SES_FILE" ] || die "SMTP 계정 보관 파일이 없습니다: $SES_FILE"
  note "SMTP 계정 보관 파일 있음"
fi

# ------------------------------------------------------------
# 이미지 점검과 자동 빌드·push 에 쓰는 함수
# ------------------------------------------------------------
# 차트가 쓰는 이미지 중 ECR 에 없는 것을 MISSING_IMAGES 에 "저장소:태그" 형태로 담는다 (공백·줄바꿈 구분)
check_images() {
  MISSING_IMAGES=""
  local img repo tag
  while read -r img; do
    [ -z "$img" ] && continue
    repo="$(echo "$img" | sed -E 's#.*/([^:]+):.*#\1#')"; tag="${img##*:}"
    if ! aws --region "$REGION" ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" >/dev/null 2>&1; then
      MISSING_IMAGES="$MISSING_IMAGES $repo:$tag"
    fi
  done <<EOF
$(helm template x "$CHART" -n sns 2>/dev/null | grep -E '^\s+image:' | sed -E 's/^\s+image: //; s/"//g' | sort -u)
EOF
}

# ECR 저장소 이름 -> 소스 폴더 (jib 로 빌드하는 서비스). 프런트(sns-frontend)는 따로 처리한다
image_dir() {
  case "$1" in
    feed-server)         echo "part3-feed-server" ;;
    user-server)         echo "part3-user-server" ;;
    image-server)        echo "part3-image-server" ;;
    timeline-server)     echo "part3-timeline-sersver" ;;   # 폴더명 오타(sersver)는 저장소 그대로
    notification-batch)  echo "part3-notification-batch" ;;
    *)                   echo "" ;;
  esac
}

# 없는 이미지를 빌드해서 ECR 에 push 한다. 배포(step 5)에서 클러스터가 이 이미지를 ECR 에서 받아 간다
build_missing_images() {
  command -v docker >/dev/null 2>&1 || die "docker 가 필요합니다 (이미지 빌드·push)"
  [ "$EXECUTE" = 1 ] && { docker info >/dev/null 2>&1 || die "Docker 데몬이 꺼져 있습니다. Docker Desktop 을 실행한 뒤 다시 하세요"; }

  # ECR 로그인 (인자에 비밀값이 없다: 토큰은 파이프로 전달)
  run_sh "aws --region $REGION ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY"

  local m repo tag dir
  for m in $MISSING_IMAGES; do
    repo="${m%%:*}"; tag="${m##*:}"
    if [ "$repo" = "sns-frontend" ]; then
      case "$tag" in
        react-*) run "$REPO_ROOT/part3-frontend/scripts/push-react.sh" "$tag" ;;
        *) die "프런트 태그 $tag 는 자동으로 만들 수 없습니다(직접 만든 React 이미지는 react-* 태그). sns-chart/values.yaml 의 태그를 확인하거나 part3-frontend/scripts/push-image.sh 로 직접 push 하세요" ;;
      esac
      continue
    fi
    dir="$(image_dir "$repo")"
    [ -n "$dir" ] || die "저장소 $repo 의 소스 폴더를 모릅니다. 직접 push 하세요"
    echo "  \$ (cd $dir && ./gradlew jib)   # $repo:$tag. 실패하면 ./gradlew --stop 후 한 번 더 시도"
    if [ "$EXECUTE" = 1 ]; then
      if ! ( cd "$REPO_ROOT/$dir" && ./gradlew jib ); then
        echo "  ! jib 실패. gradle 데몬을 멈추고 한 번 더 시도합니다"
        ( cd "$REPO_ROOT/$dir" && ./gradlew --stop >/dev/null 2>&1; ./gradlew jib ) || die "$dir 의 jib 가 실패했습니다. 위 오류를 확인하고 해결한 뒤 ./bootstrap.sh --execute --only 0 으로 다시 하세요"
      fi
    fi
  done
}

# ------------------------------------------------------------
# 0) 서비스 이미지 확인: ECR 에 없으면 빌드해서 push (terraform 으로 저장소를 새로 만들면 이미지는 비어 있다)
#    --no-build 를 주면 자동 빌드를 하지 않고, 이미지가 없을 때 중단한다
# ------------------------------------------------------------
if step_enabled 0; then
  title "0) 서비스 이미지 확인 (ECR 에 없으면 빌드해서 push)"
  check_images
  if [ -z "$(echo $MISSING_IMAGES)" ]; then
    note "차트가 쓰는 이미지가 모두 ECR 에 있음"
  else
    for m in $MISSING_IMAGES; do warn "ECR 에 이미지가 없습니다: $m"; done
    if [ "${ALLOW_MISSING_IMAGES:-0}" = 1 ]; then
      warn "ALLOW_MISSING_IMAGES=1 이라 이미지 없이 진행합니다 (Pod 가 ImagePullBackOff 가 됩니다)"
    elif [ "$NO_BUILD" = 1 ]; then
      [ "$EXECUTE" = 1 ] && die "--no-build 라 자동으로 만들지 않습니다. 이미지를 push 한 뒤 다시 실행하세요 (terraform/docs/재생성_후_세팅_순서.md 2절)"
      note "(--no-build) 실행 모드에서는 여기서 중단합니다"
    else
      note "없는 이미지를 빌드해서 ECR 에 push 합니다 (서비스당 1~3분, 프런트는 몇 분). 이후 배포 단계에서 클러스터가 ECR 에서 받아 갑니다"
      build_missing_images
      if [ "$EXECUTE" = 1 ]; then
        check_images
        if [ -n "$(echo $MISSING_IMAGES)" ]; then
          die "push 후에도 ECR 에 없는 이미지가 있습니다:$MISSING_IMAGES  (build.gradle 의 jib tags 와 sns-chart/values.yaml 의 태그가 같은지 확인하세요)"
        fi
        note "필요한 이미지가 모두 ECR 에 push 되었습니다"
      fi
    fi
  fi
fi

# ------------------------------------------------------------
# 1) kubeconfig, 노드 확인
# ------------------------------------------------------------
if step_enabled 1; then
  title "1) kubeconfig 를 $CLUSTER 로 전환하고 노드 확인"
  run aws --region "$REGION" eks update-kubeconfig --name "$CLUSTER"
  run kubectl wait --for=condition=Ready nodes --all --timeout=10m
  run kubectl get nodes
fi

# ------------------------------------------------------------
# 2) 네임스페이스, ExternalName(RDS), StorageClass(EFS)
#    저장소의 efs-sc.yaml 은 fileSystemId 가 자리표시자라서, 새 EFS ID 로 바꾼 사본을 만들어 적용한다 (저장소 파일은 건드리지 않는다)
# ------------------------------------------------------------
if step_enabled 2; then
  title "2) 네임스페이스, ExternalName mariadb(RDS), StorageClass efs-sc(EFS)"
  run_sh "kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -"
  run_sh "kubectl create namespace sns --dry-run=client -o yaml | kubectl apply -f -"

  cat > "$WORKDIR/mariadb-external.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  namespace: infra
spec:
  type: ExternalName
  externalName: $RDS_ADDR
EOF
  sed -E "s/fileSystemId: .*/fileSystemId: $EFS_ID/" "$EFS_SC_YAML" > "$WORKDIR/efs-sc.yaml"
  note "ExternalName 매니페스트(externalName: $RDS_ADDR), StorageClass 사본(fileSystemId: $EFS_ID) 생성"
  run kubectl apply -f "$WORKDIR/mariadb-external.yaml"
  run kubectl apply -f "$WORKDIR/efs-sc.yaml"
fi

# ------------------------------------------------------------
# 3) Secret 3개, IngressClass, Redis, Kafka
# ------------------------------------------------------------
if step_enabled 3; then
  title "3) Secret 3개, IngressClass alb, Redis, Kafka"
  run kubectl apply -f "$MYSQL_SECRET_YAML"
  run kubectl apply -f "$KAFKA_SECRET_YAML"
  run_sh "kubectl -n sns create secret generic email-secret --from-env-file='$SES_FILE' --dry-run=client -o yaml | kubectl apply -f -"
  run kubectl apply -f "$INGRESS_CLASS_YAML"

  # Kafka 비밀번호는 kafka-secret 의 값과 같아야 서비스가 접속한다 (저장소 YAML에서 읽는다)
  KAFKA_PW="$(grep KAFKA_PASSWORD "$KAFKA_SECRET_YAML" | awk '{print $2}' | base64 -d 2>/dev/null)"
  [ -n "$KAFKA_PW" ] || die "kafka-secret YAML에서 KAFKA_PASSWORD 를 읽지 못했습니다"

  if [ "$EXECUTE" = 0 ] || ! helm status redis -n infra >/dev/null 2>&1; then
    run helm -n infra install redis oci://registry-1.docker.io/bitnamicharts/redis \
      --set architecture=standalone --set auth.enabled=false --set master.persistence.enabled=false
  else
    note "Redis 릴리스가 이미 있어 건너뜀"
  fi
  if [ "$EXECUTE" = 0 ] || ! helm status kafka -n infra >/dev/null 2>&1; then
    run_masked "helm -n infra install kafka oci://registry-1.docker.io/bitnamicharts/kafka --set controller.replicaCount=3 --set sasl.client.passwords=<kafka-secret의 KAFKA_PASSWORD> --set controller.persistence.enabled=false --set broker.persistence.enabled=false --set global.security.allowInsecureImages=true --set image.repository=bitnamilegacy/kafka" \
      helm -n infra install kafka oci://registry-1.docker.io/bitnamicharts/kafka \
      --set controller.replicaCount=3 --set sasl.client.passwords="$KAFKA_PW" \
      --set controller.persistence.enabled=false --set broker.persistence.enabled=false \
      --set global.security.allowInsecureImages=true --set image.repository=bitnamilegacy/kafka
  else
    note "Kafka 릴리스가 이미 있어 건너뜀"
  fi
  run kubectl -n infra wait --for=condition=Ready pod/redis-master-0 --timeout=5m
  run kubectl -n infra wait --for=condition=Ready pod -l app.kubernetes.io/name=kafka --timeout=8m
fi

# ------------------------------------------------------------
# 4) RDS: 마스터(admin)로 서비스 계정(sns-server) 생성 + 덤프 복원 + 서비스 계정으로 검증
#    덤프에는 DROP TABLE 이 들어 있어서, 대상 RDS에 이미 sns DB가 있으면 중단한다(덮어쓰기 방지)
#    임시 Pod 에는 RDS 접속용 MYSQL_HOST 가 들어가므로 이 Pod 의 mariadb 명령은 항상 RDS 로 간다
# ------------------------------------------------------------
if step_enabled 4; then
  title "4) RDS 에 sns-server 계정 생성과 덤프 복원"
  DBADMIN_PW="${TF_VAR_db_password:-}"
  if [ "$EXECUTE" = 1 ]; then
    if [ -z "$DBADMIN_PW" ]; then
      printf "RDS 마스터(admin) 비밀번호 (terraform apply 때 넣은 값, 입력은 보이지 않음): "
      read -rs DBADMIN_PW; echo
    else
      note "마스터 비밀번호를 환경변수 TF_VAR_db_password 에서 읽음"
    fi
    [ -n "$DBADMIN_PW" ] || die "마스터 비밀번호가 비어 있습니다"
    # 임시 Secret(마스터 비밀번호)과 임시 Pod. 끝나면(실패해도) 지운다
    trap 'kubectl -n sns delete pod dbrestore --ignore-not-found --wait=false >/dev/null 2>&1; kubectl -n sns delete secret dbadmin --ignore-not-found >/dev/null 2>&1; cleanup' EXIT
    # 비밀번호를 명령 인자로 넘기지 않으려고 권한 600 임시 파일에서 읽는다 (끝나면 WORKDIR 째로 지워진다)
    ( umask 077; printf '%s' "$DBADMIN_PW" > "$WORKDIR/dbadmin-pw" )
    kubectl -n sns create secret generic dbadmin --from-file=DBADMIN_PW="$WORKDIR/dbadmin-pw" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || die "임시 Secret 생성 실패"
    rm -f "$WORKDIR/dbadmin-pw"
  fi
  echo "  \$ (마스터 비밀번호를 임시 Secret dbadmin 으로 만든다. 값은 화면에 표시하지 않는다)"

  run kubectl -n sns delete pod dbrestore --ignore-not-found --wait=true
  run kubectl -n sns run dbrestore --restart=Never --image=mariadb:11.8 \
    --overrides='{"spec":{"containers":[{"name":"dbrestore","image":"mariadb:11.8","command":["sleep","1800"],"env":[{"name":"MYSQL_HOST","value":"mariadb.infra.svc.cluster.local"},{"name":"MYSQL_PORT","value":"3306"}],"envFrom":[{"secretRef":{"name":"mysql-secret"}},{"secretRef":{"name":"dbadmin"}}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
  run kubectl -n sns wait --for=condition=Ready pod/dbrestore --timeout=3m

  MA='mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u admin -p"$DBADMIN_PW" --skip-ssl-verify-server-cert'
  MS='mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl-verify-server-cert'

  # 대상 확인: sns DB 가 없으면 복원한다. 이미 있고 데이터(user 행)가 있으면 "이미 복원됨"으로 보고 복원만 건너뛴다(다시 실행해도 끝까지 간다).
  # sns DB 는 있는데 비어 있거나 읽을 수 없으면, 덤프의 DROP TABLE 이 일부만 만들어진 상태를 덮어쓰지 않도록 중단한다.
  SKIP_RESTORE=0
  echo "  \$ (대상 확인) kubectl -n sns exec dbrestore -- sh -c '$MA -N -e \"SHOW DATABASES\"'  → sns DB 가 없으면 복원, 이미 데이터가 있으면 복원을 건너뜀"
  if [ "$EXECUTE" = 1 ]; then
    DBS="$(kubectl -n sns exec dbrestore -- sh -c "$MA -N -e 'SHOW DATABASES'" 2>&1)" || die "마스터(admin)로 RDS에 접속하지 못했습니다. 마스터 비밀번호를 확인하세요 (한글 입력 상태가 아닌지, 또는 TF_VAR_db_password='...' ./bootstrap.sh --execute 로 환경변수로 넘기세요, \$ 가 있으면 작은따옴표): $DBS"
    if echo "$DBS" | grep -qx 'sns'; then
      UROWS="$(kubectl -n sns exec dbrestore -- sh -c "$MA -N -e 'SELECT COUNT(*) FROM sns.user'" 2>&1 | tr -d '[:space:]')"
      case "$UROWS" in
        ''|*[!0-9]*) die "대상 RDS 에 sns DB 가 있지만 user 테이블을 읽지 못했습니다($UROWS). 일부만 만들어진 상태일 수 있어 덤프의 DROP TABLE 로 덮어쓰지 않고 중단합니다. 비어 있는 DB 가 맞다면 직접 정리한 뒤 다시 실행하세요" ;;
      esac
      if [ "$UROWS" -gt 0 ]; then
        SKIP_RESTORE=1
        note "이미 복원되어 있음 (sns.user ${UROWS}행). 덤프 복원은 건너뛰고 계속 진행합니다"
      else
        die "대상 RDS 에 sns DB 는 있지만 user 테이블이 비어 있습니다. 덤프의 DROP TABLE 로 덮어쓰지 않고 중단합니다. 비어 있는 DB 가 맞다면 직접 정리한 뒤 다시 실행하세요"
      fi
    else
      note "대상 RDS 에 sns DB 없음, 복원을 진행"
    fi
  fi

  # 서비스 계정 생성/권한은 여러 번 실행해도 안전하다 (이미 있으면 그대로). 복원을 건너뛰어도 서비스가 접속할 수 있게 항상 확인한다
  run kubectl -n sns exec dbrestore -- sh -c "$MA -e 'CREATE USER IF NOT EXISTS \"sns-server\"@\"%\" IDENTIFIED BY \"'\"\$MYSQL_PASSWORD\"'\"; GRANT ALL PRIVILEGES ON sns.* TO \"sns-server\"@\"%\"; FLUSH PRIVILEGES;'"
  if [ "$SKIP_RESTORE" = 1 ]; then
    echo "  (덤프 복원 건너뜀: 이미 복원되어 있음)"
  else
    echo "  \$ kubectl -n sns exec -i dbrestore -- sh -c '$MA' < $DUMP   # sns DB 가 이미 있으면 건너뜀"
    if [ "$EXECUTE" = 1 ]; then
      kubectl -n sns exec -i dbrestore -- sh -c "$MA" < "$DUMP" || die "덤프 복원 실패"
    fi
  fi

  echo "  \$ (검증) 서비스 계정 sns-server 로 접속해 행 수 확인"
  if [ "$EXECUTE" = 1 ]; then
    COUNTS="$(kubectl -n sns exec dbrestore -- sh -c "$MS sns -N -e 'SELECT \"user\", COUNT(*) FROM user UNION ALL SELECT \"social_feed\", COUNT(*) FROM social_feed UNION ALL SELECT \"follow\", COUNT(*) FROM follow'" 2>&1)" || die "서비스 계정으로 접속하지 못했습니다: $COUNTS"
    echo "$COUNTS" | sed 's/^/      /'
    echo "$COUNTS" | awk '$2+0>0{ok++} END{exit ok>=2?0:1}' || die "복원된 행 수가 비정상입니다. 위 결과를 확인하세요"
  fi
  run kubectl -n sns delete pod dbrestore --wait=false
  run kubectl -n sns delete secret dbadmin --ignore-not-found
fi

# ------------------------------------------------------------
# 5) 서비스 배포 (차트 하나로 Deployment, Service, ConfigMap, PVC, CronJob, Ingress 전부)
# ------------------------------------------------------------
if step_enabled 5; then
  title "5) 서비스 배포: helm upgrade --install sns"
  # 이미지가 ECR 에 없으면 Pod 가 뜨지 않으므로 배포 직전에 한 번 더 확인한다 (0단계를 건너뛰고 --only 5 만 실행한 경우 등)
  if [ "$EXECUTE" = 1 ] && [ "${ALLOW_MISSING_IMAGES:-0}" != 1 ]; then
    check_images
    [ -z "$(echo $MISSING_IMAGES)" ] || die "ECR 에 없는 이미지가 있어 배포하지 않습니다:$MISSING_IMAGES  (먼저 ./bootstrap.sh --execute --only 0 으로 push)"
  fi
  run helm upgrade --install sns "$CHART" -n sns --wait --timeout 8m
  run kubectl -n sns get pods
fi

# ------------------------------------------------------------
# 6) 확인
# ------------------------------------------------------------
if step_enabled 6; then
  title "6) 확인 (헬스체크, ALB)"
  for s in feed-service user-service image-service timeline-service; do
    echo "  \$ kubectl get --raw /api/v1/namespaces/sns/services/$s:8080/proxy/healthcheck/ready"
    if [ "$EXECUTE" = 1 ]; then echo "      $s: $(kubectl get --raw /api/v1/namespaces/sns/services/$s:8080/proxy/healthcheck/ready 2>&1 | head -c 80)"; fi
  done
  echo "  \$ kubectl -n sns get ingress sns-ingress   # ADDRESS(ALB 주소) 가 생길 때까지 1~4분"
  if [ "$EXECUTE" = 1 ]; then
    ADDR=""
    for i in $(seq 1 20); do
      ADDR="$(kubectl -n sns get ingress sns-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
      if [ -n "$ADDR" ] && [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ADDR/api/feeds")" = "200" ]; then break; fi
      note "ALB 준비 대기 ($i/20)"; sleep 15
    done
    if [ -n "$ADDR" ]; then
      for p in / /api/feeds /api/timeline; do echo "      http://$ADDR$p -> $(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ADDR$p")"; done
      echo; echo "  접속 주소: http://$ADDR"
    else
      warn "ALB 주소가 아직 없습니다. 몇 분 뒤 kubectl -n sns get ingress sns-ingress 로 확인하세요"
    fi
  fi
fi

echo
if [ "$EXECUTE" = 1 ]; then
  echo "완료. 참고: DB 의 피드는 복원되지만 Timeline 화면(Redis)과 이미지 파일(EFS)은 비어 있습니다. terraform/docs/재생성_후_세팅_순서.md 의 「이후」를 보세요."
else
  echo "미리보기 끝. 실제로 실행하려면 ./bootstrap.sh --execute"
fi
