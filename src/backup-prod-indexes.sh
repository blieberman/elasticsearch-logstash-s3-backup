#!/bin/bash
# blieberman adpted from https://github.com/aptible/elasticsearch-logstash-s3-backup

# Set some defaults
S3_ACCESS_KEY_ID=$(grep aws_access_key_id ~/.aws/credentials | awk '{ print $3 }')
S3_SECRET_ACCESS_KEY=$(grep aws_secret_access_key ~/.aws/credentials | awk '{ print $3 }')
S3_BUCKET=$YOUR_S3_BUCKET
S3_BUCKET_BASE_PATH=$YOUR_S3_BUCKET_BASE_PATH
S3_REGION=us-east-1
ELASTICSEARCH_HOST=http://$YOUR_ELASTICSEARCH_HOST:9200
REPOSITORY_NAME=logstash_snapshots
WAIT_SECONDS=${WAIT_SECONDS:-1800}
MAX_DAYS_TO_KEEP=10
REPOSITORY_URL="${ELASTICSEARCH_HOST}/_snapshot/${REPOSITORY_NAME}"
REPOSITORY_PLUGIN=repository-s3

function backup_index ()
{
  : ${1:?"Error: expected index name passed as parameter"}
  local INDEX_NAME=$1
  local SNAPSHOT_URL=${REPOSITORY_URL}/${INDEX_NAME}
  local INDEX_URL=${ELASTICSEARCH_HOST}/${INDEX_NAME}

  grep -q SUCCESS <(curl -sS ${SNAPSHOT_URL})
  if [ $? -ne 0 ]; then
    echo "$(now): Scheduling snapshot."
    # If the snapshot exists but isn't in a success state, delete it so that we can try again.
    grep -qE "FAILED|PARTIAL|IN_PROGRESS" <(curl -sS ${SNAPSHOT_URL}) && curl -sS -XDELETE ${SNAPSHOT_URL}
    # Indexes have to be open for snapshots to work.
    curl -sS -XPOST "${INDEX_URL}/_open"

    curl --fail -w "\n" -sS -XPUT ${SNAPSHOT_URL} -d "{
      \"indices\": \"${INDEX_NAME}\",
      \"include_global_state\": false
    }" || return 1

    echo "$(now): Waiting for snapshot to finish..."
    timeout "${WAIT_SECONDS}" bash -c "until grep -q SUCCESS <(curl -sS ${SNAPSHOT_URL}); do sleep 1; done" || return 1
  fi

  echo "Deleting ${INDEX_NAME} from Elasticsearch."
  curl -w "\n" -sS -XDELETE ${INDEX_URL}
}


function now() {
  date +"%m-%d-%Y %H-%M"
}

#####

echo "$(now): es-index_snapshot_s3.sh -- Preparing for run..."

# Ensure that we don't delete indices that are being logged. Using 1 should
# actually be fine here as long as everyone's on the same timezone, but let's
# be safe and require at least 2 days.
if [[ "$MAX_DAYS_TO_KEEP" -lt 2 ]]; then
  echo "$(now): MAX_DAYS_TO_KEEP must be an integer >= 2."
  echo "$(now): Using lower values may break archiving."
  exit 1
fi

# Ensure that Elasticsearch has the cloud-aws plugin.
echo "$(now): Ensuring ${REPOSITORY_PLUGIN} exists @ ${ELASTICSEARCH_HOST}/_cat/plugins ..."
grep -q $REPOSITORY_PLUGIN <(curl -sS ${ELASTICSEARCH_HOST}/_cat/plugins)
if [ $? -ne 0 ]; then
  echo "$(now): Elasticsearch server does not have the ${REPOSITORY_PLUGIN} plugin installed. Exiting."
  exit 1
fi
echo "$(now): ...ensured plugins exist"

echo "$(now): Ensuring Elasticsearch snapshot repository ${REPOSITORY_NAME} exists..."
echo curl -w "\n" -sS -XPUT ${REPOSITORY_URL} -d "{
  \"type\": \"s3\",
  \"settings\": {
    \"bucket\" : \"${S3_BUCKET}\",
    \"base_path\": \"${S3_BUCKET_BASE_PATH}\",
    \"access_key\": \"${S3_ACCESS_KEY_ID}\",
    \"secret_key\": \"${S3_SECRET_ACCESS_KEY}\",
    \"region\": \"${S3_REGION}\",
    \"protocol\": \"https\",
    \"server_side_encryption\": true
  }
}"
curl -w "\n" -sS -XPUT ${REPOSITORY_URL} -d "{
  \"type\": \"s3\",
  \"settings\": {
    \"bucket\" : \"${S3_BUCKET}\",
    \"base_path\": \"${S3_BUCKET_BASE_PATH}\",
    \"access_key\": \"${S3_ACCESS_KEY_ID}\",
    \"secret_key\": \"${S3_SECRET_ACCESS_KEY}\",
    \"region\": \"${S3_REGION}\",
    \"protocol\": \"https\",
    \"server_side_encryption\": true
  }
}"
echo "$(now): ...ensured repository exists"

CUTOFF_DATE=$(date --date="${MAX_DAYS_TO_KEEP} days ago" +"%Y.%m.%d")
SUBSTITUTION='s/.*\(log-prod-.*-[0-9\.]\{10\}\).*/\1/'
echo "$(now): Archiving all indexes with logs before ${CUTOFF_DATE}..."

for index_name in $(curl -sS ${ELASTICSEARCH_HOST}/_cat/indices | grep log-prod- | sed $SUBSTITUTION | sort); do
  if [[ "${index_name: -10}" < "${CUTOFF_DATE}" ]]; then
    echo "$(now): Ensuring ${index_name} is archived..."
      backup_index ${index_name}
      if [ $? -eq 0 ]; then
        echo "$(now): ${index_name} archived."
      else
        echo "$(now): ${index_name} archival failed."
      fi
  fi
done
echo "$(now): Finished archiving."
