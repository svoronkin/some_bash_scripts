#!/bin/bash
# Clear space occupied by no longer needed docker components
docker system prune -a; docker volume prune; docker builder prune --all; docker buildx prune --all, docker image prune --all