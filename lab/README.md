# kubeadm 실습 환경 재현

이 디렉터리는 kubeadm 실습 클러스터의 워커 조인, Helm 배포, 내부 API 부하 검증을 다룬다. EC2·네트워크·IAM·FIS는 [workspace-v2/terraform의 k8s-pilot 구성](https://github.com/workspace-v2/terraform/tree/main/k8s-pilot)에서 관리한다.

| 역할 | 구성 |
| --- | --- |
| Control plane | EC2 1대, kubeadm, Flannel, MySQL·Redis, 업로드 NFS, k6 |
| 워커 | EC2 2대, 워커별 앱 파드 한 개, 로컬 containerd 이미지 |
| 장애 실습 | 워커 두 대 중 한 대만 재부팅하는 AWS FIS 템플릿 |
| 부하 실습 | 클러스터 내부 브랜드 읽기 API에 5 RPS로 30초 실행 |

## 1. 워커 조인

AWS 인프라를 준비한 뒤 Terraform 출력에서 `instance_ids`와 `private_ips`를 확인한다. AWS CLI와 Session Manager 플러그인이 있는 터미널에서 각 인스턴스에 접속한다.

```bash
aws --profile personal-project --region ap-northeast-2 ssm start-session --target INSTANCE_ID
```

Control plane에서 `sudo cloud-init status --wait`가 끝난 뒤 `sudo kubeadm token create --ttl 10m --print-join-command`를 실행한다. 각 워커에서도 cloud-init 완료를 확인하고, 받은 명령을 `sudo`로 실행하면서 `--node-name k8s-pilot-worker-a` 또는 `--node-name k8s-pilot-worker-b`를 붙인다.

Control plane의 관리자 셸에서 두 노드가 준비되면 역할을 지정하고 조인에 사용한 토큰을 폐기한다.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl wait --for=condition=Ready node/k8s-pilot-worker-a node/k8s-pilot-worker-b --timeout=180s
kubectl label node k8s-pilot-worker-a k8s-pilot-worker-b node-role.kubernetes.io/worker= k8s-pilot/worker=true
kubeadm token delete TOKEN_ID
```

## 2. 플랫폼과 이미지 준비

Control plane에서 이 저장소를 체크아웃한 뒤, 각 워커의 프라이빗 IP를 사용해 공유 저장소를 준비한다. Control plane에 Java 21과 Buildah, Helm 3가 필요하다.

```bash
apt-get update
apt-get install -y git openjdk-21-jdk-headless buildah
bash lab/scripts/configure-storage.sh WORKER_A_PRIVATE_IP WORKER_B_PRIVATE_IP
bash lab/scripts/build-image.sh
```

각 워커의 관리자 셸에서 이미지를 가져온다. `CONTROL_PLANE_IP`에는 Terraform 출력의 control plane 프라이빗 IP를 넣는다.

```bash
share=$(mktemp -d)
mount -t nfs4 -o ro,nfsvers=4.1 CONTROL_PLANE_IP:/ "$share"
ctr -n k8s.io images import --platform linux/amd64 "$share/community-service-25aebbc.tar"
umount "$share"
rmdir "$share"
```

Control plane에서 Argo CD와 모니터링용 Secret을 준비한다. Traefik, 관측 도구, 앱은 `root-app`이 하위 Application으로 배포한다.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd --version 10.2.1 -n argocd --create-namespace \
  -f argocd/values/argocd-values.yaml --wait --timeout 8m
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n monitoring get secret grafana-admin-secret >/dev/null 2>&1; then
  secret_file=$(mktemp)
  openssl rand -hex 24 | tr -d '\n' > "$secret_file"
  kubectl -n monitoring create secret generic grafana-admin-secret \
    --from-literal=admin-user=admin --from-file=admin-password="$secret_file"
  rm -f "$secret_file"
fi
```

## 3. 기존 Argo CD 경로로 배포

Git의 `argocd/applications/amumal-server.yaml`에서 `storage.nfsServer`가 이 환경의 control plane 프라이빗 IP인지 확인한다. `chart/values.yaml`의 `image.tag`는 두 워커에 가져온 이미지 태그와 일치해야 한다. 새 환경에서 값이 다르면 Git에 먼저 반영한다.

Control plane에서 네임스페이스와 Secret을 준비한다. 기존 Secret을 재사용하면 MySQL·Redis 자격 증명을 유지할 수 있다.

```bash
kubectl create namespace community-service --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n community-service get secret community-service-credentials >/dev/null 2>&1; then
  secret_file=$(mktemp)
  for key in DB_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD JWT_SECRET; do
    printf '%s=%s\n' "$key" "$(openssl rand -hex 32)"
  done > "$secret_file"
  kubectl -n community-service create secret generic community-service-credentials --from-env-file="$secret_file"
  rm -f "$secret_file"
fi
```

이전에 수동 구축한 클러스터에 적용할 때는 기존 `community-service` 리소스의 이름과 NFS PVC를 확인한다. 이전에 중지한 `amumal-server`용 deny sync window가 있다면, Git의 변경이 보이는지 확인한 뒤 Argo CD의 `default` 프로젝트에서 해당 window만 제거한다. 이전 배포의 리소스가 prune 대상으로 남아 있다면 대상이 `backend` 네임스페이스의 이전 리소스인지 확인한다.

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
kubectl -n argocd get application root-app amumal-server
kubectl -n community-service rollout status deployment/community-service --timeout=8m
kubectl -n community-service get pods -o wide
curl -fsS -H 'Host: api.pattie.cloud' http://CONTROL_PLANE_IP:32080/v1/brands
```

외부 MySQL을 사용하는 환경에서는 Git의 `chart/values.yaml`에 `mysql.enabled: false`와 접속 정보를 설정하고, Kubernetes Secret의 `DB_PASSWORD`를 외부 DB 계정에 맞춘다. 기존 데이터를 옮기는 경우 먼저 백업과 복원을 진행한다.

GHCR 이미지를 사용하는 경우 `chart/values.yaml`의 `image.repository`, `image.tag`, `image.pullPolicy`를 발행된 이미지에 맞춘다. 비공개 패키지면 배포 네임스페이스에 기존 이미지 풀 Secret을 준비하고 `image.pullSecret`에 이름을 적는다. 현재 `workspace-v2/community-service`의 기존 GHCR 발행 및 GitOps 태그 갱신 워크플로는 비활성화 상태다.

## 4. 실습 실행

```bash
kubectl -n community-service create configmap community-service-k6 \
  --from-file=smoke.js=lab/loadtest/k6-smoke.js --dry-run=client -o yaml | kubectl apply -f -
job=$(kubectl -n community-service create -f lab/loadtest/job.yaml -o name)
kubectl -n community-service logs "$job" -f --pod-running-timeout=2m
```

워커 재부팅은 [FIS 실행 절차](https://github.com/workspace-v2/terraform/blob/main/k8s-pilot/README.md#fis-워커-재부팅)를 따른다.
