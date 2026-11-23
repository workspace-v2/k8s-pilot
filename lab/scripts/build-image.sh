#!/usr/bin/env bash
set -Eeuo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --no-checkout https://github.com/workspace-v2/community-service.git "$work/source"
git -C "$work/source" checkout --detach 25aebbc85aad9dfb0260cb439b1cc48d170edfe4
(
  cd "$work/source"
  ./gradlew --no-daemon --max-workers=1 -Dorg.gradle.jvmargs=-Xmx768m bootJar
)
install -d "$work/image/build/libs"
cp "$work"/source/build/libs/*-SNAPSHOT.jar "$work/image/build/libs/"
sed 's|^FROM eclipse-temurin:|FROM docker.io/library/eclipse-temurin:|' \
  "$work/source/Dockerfile.ecs" > "$work/image/Dockerfile"
image=localhost/community-service:25aebbc
buildah bud --isolation=chroot -t "$image" "$work/image"
buildah push "$image" "docker-archive:$work/community-service-25aebbc.tar:$image"
install -m 0644 "$work/community-service-25aebbc.tar" /srv/k8s-pilot-share/community-service-25aebbc.tar
