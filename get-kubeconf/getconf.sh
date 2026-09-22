#!/usr/bin/env bash
set -u
out="${1:-./kubeconfigs}"
mkdir -p "$out"

org_id=$(yc resource-manager cloud get --id "$(yc config get cloud-id)" --format json | jq -r .organization_id)
echo "organization: $org_id"

yc resource-manager cloud list --organization-id "$org_id" --format json \
| jq -c '.[] | {id, name}' | while read -r cloud; do
  cloud_id=$(jq -r .id <<<"$cloud")
  cloud_name=$(jq -r .name <<<"$cloud")
  cloud_name="${cloud_name#\'}"
  case "$cloud_name" in
    cloude-kamacom|sandbox)
      echo "skip cloud $cloud_name"
      continue
      ;;
  esac

  yc resource-manager folder list --cloud-id "$cloud_id" --format json \
  | jq -c '.[] | {id, name}' | while read -r folder; do
    folder_id=$(jq -r .id <<<"$folder")
    folder_name=$(jq -r .name <<<"$folder")

    yc managed-kubernetes cluster list --folder-id "$folder_id" --format json \
    | jq -c '.[] | {id, name}' | while read -r cluster; do
      cluster_id=$(jq -r .id <<<"$cluster")
      cluster_name=$(jq -r .name <<<"$cluster")
      readable="${cloud_name}/${folder_name}/${cluster_name}"

      file="$out/${cloud_name}__${folder_name}__${cluster_name}.yaml"
      echo "-> $file ($readable)"
      yc managed-kubernetes cluster get-credentials \
        --id "$cluster_id" \
        --internal \
        --kubeconfig "$file" \
        --context-name "$readable" \
        --force || { echo "skip $cluster_id"; continue; }

      old="yc-managed-k8s-${cluster_id}"
      tmp=$(mktemp)
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "${line//"$old"/"$readable"}"
      done < "$file" > "$tmp"
      mv "$tmp" "$file"
    done
  done
done
