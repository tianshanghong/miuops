#!/bin/bash

# Setup S3 backup bucket with Object Lock, lifecycle rules, and IAM user.
#
# ONE bucket is shared by the whole fleet; each server gets its own top-level
# prefix "<server>/" and its own per-server IAM user "<bucket>-<server>" whose
# inline policy is scoped to that prefix only (Put/Get on <server>/*, List on
# the bucket conditioned to s3:prefix=<server>/*, and NO Delete). A compromised
# server can read/write only its own backups.
#
# Usage:
#   setup-s3-backup.sh                 interactive (prompts for project + server)
#   setup-s3-backup.sh --server <name> non-interactive server (re-runnable per server)
#   MIUOPS_PROJECT=<p> MIUOPS_SERVER=<s> setup-s3-backup.sh   fully non-interactive
#
# Idempotent — safe to re-run if a previous run failed partway through.

# -- Pure policy generator (sourceable for tests) ----------------------------
#
# Emit the per-server inline IAM policy as JSON on stdout.
#   $1 = bucket name   $2 = server name
#
# Shape (AWS-canonical prefix scoping, verified against the S3 user-policy
# walkthrough):
#   * s3:ListBucket  is a BUCKET-level action -> Resource is the bare bucket ARN
#     (no /*), restricted to the server's keyspace via a Condition
#     StringLike s3:prefix ["<server>/*"]  (StringLike because the value has *).
#   * s3:PutObject + s3:GetObject are OBJECT-level -> scoped purely by the
#     Resource ARN suffix /<server>/*  (s3:prefix governs ListBucket ONLY; it is
#     a no-op on object ops, so the ARN is the real object scope -- do not add it
#     to the object statement).
#   * NO s3:DeleteObject and NO s3:* -> immutability by omission (the bucket
#     Object-Lock backs this up). NO explicit Deny is needed: IAM default-deny
#     already blocks any cross-prefix (other-server) access.
gen_iam_policy() {
    local bucket="$1" server="$2"
    cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListOwnPrefixOnly",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::${bucket}",
            "Condition": {
                "StringLike": {
                    "s3:prefix": ["${server}/*"]
                }
            }
        },
        {
            "Sid": "ReadWriteOwnObjectsOnly",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${bucket}/${server}/*"
        }
    ]
}
EOF
}

# When sourced as a library (by the iam-policy check), define the functions above and
# stop here -- do NOT run the interactive provisioning flow or touch AWS.
if [ -n "${MIUOPS_S3_SETUP_LIB:-}" ]; then
    # `return` when sourced; the `exit` is the fallback if run directly with the
    # flag set (shellcheck can't see the sourced path, hence the directive).
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

set -e

# -- Argument parsing --------------------------------------------------------

SERVER="${MIUOPS_SERVER:-}"
PROJECT_NAME="${MIUOPS_PROJECT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            SERVER="$2"
            shift 2
            ;;
        --server=*)
            SERVER="${1#*=}"
            shift
            ;;
        --project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --project=*)
            PROJECT_NAME="${1#*=}"
            shift
            ;;
        -h | --help)
            echo "Usage: $0 [--project <name>] [--server <name>]"
            echo "  --project <name>  fleet/bucket prefix (bucket = <name>-backup)"
            echo "  --server <name>   per-server identity (IAM user + S3 prefix)"
            echo "Env: MIUOPS_PROJECT, MIUOPS_SERVER mirror the flags."
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (try --help)."
            exit 1
            ;;
    esac
done

# -- Prerequisite checks -----------------------------------------------------

if ! command -v aws &> /dev/null; then
    echo "Error: aws CLI is not installed."
    echo "Install it from https://aws.amazon.com/cli/"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

echo "Verifying AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials are not configured or are invalid."
    echo "Run 'aws configure' to set up your credentials."
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity)
echo "Authenticated as: $(echo "$CALLER_IDENTITY" | jq -r '.Arn')"
echo ""

# -- Prompts ------------------------------------------------------------------

echo "=============================================="
echo "        S3 Backup Bucket Setup                "
echo "=============================================="
echo ""

if [[ -z "$PROJECT_NAME" ]]; then
    read -rp "Enter project name (used as bucket prefix, e.g. myproject): " PROJECT_NAME
fi

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Error: Project name cannot be empty."
    exit 1
fi

if [[ -z "$SERVER" ]]; then
    read -rp "Enter server name (per-server IAM user + S3 prefix, e.g. web1): " SERVER
fi

if [[ -z "$SERVER" ]]; then
    echo "Error: Server name cannot be empty."
    echo "One bucket is shared by the fleet; each server has its own prefix + IAM user."
    exit 1
fi

# Fail-closed: validate both identifiers BEFORE they are interpolated into the IAM
# policy JSON, AWS CLI arguments, the S3 prefix, and the IAM user name. A crafted
# value (quotes, spaces, '..', shell/JSON metachars) must be rejected here, never
# relied on being blocked incidentally by AWS's own naming rules.
if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Error: invalid project name '${PROJECT_NAME}' — use lowercase letters, digits, hyphens (the S3 bucket charset)."
    exit 1
fi
if [[ ! "$SERVER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: invalid server name '${SERVER}' — use letters, digits, dot, dash, underscore (the inventory_hostname charset)."
    exit 1
fi

BUCKET_NAME="${PROJECT_NAME}-backup"
# Per-server IAM user: "<bucket>-<server>". Each server gets its own user + key
# pair scoped to its own "<server>/" prefix only.
IAM_USER="${BUCKET_NAME}-${SERVER}"

read -rp "Enter AWS region [us-west-2]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-west-2}

echo ""
echo "This will create / reuse:"
echo "  - S3 bucket:  $BUCKET_NAME (region: $AWS_REGION) — shared by the fleet"
echo "  - IAM user:   $IAM_USER (Put/Get/List on '${SERVER}/*' only — no Delete)"
echo "  - S3 prefix:  ${SERVER}/  (this server's keyspace)"
echo "  - Object Lock: Governance mode, 30-day retention"
echo "  - Lifecycle:   Glacier after 30 days, expire after 90 days"
echo ""
read -rp "Continue? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# -- Create bucket ------------------------------------------------------------

echo ""
echo "--- Creating S3 bucket ---"

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists, skipping creation."
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION" \
            --object-lock-enabled-for-bucket
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" \
            --object-lock-enabled-for-bucket
    fi
    echo "Bucket created: $BUCKET_NAME"
fi

# -- Default encryption -------------------------------------------------------

echo ""
echo "--- Configuring default encryption (SSE-S3) ---"

aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'

echo "Encryption configured."

# -- Block public access ------------------------------------------------------

echo ""
echo "--- Blocking all public access ---"

aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration '{
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }'

echo "Public access blocked."

# -- Object Lock default retention --------------------------------------------

echo ""
echo "--- Configuring Object Lock (Governance, 30 days) ---"

aws s3api put-object-lock-configuration \
    --bucket "$BUCKET_NAME" \
    --object-lock-configuration '{
        "ObjectLockEnabled": "Enabled",
        "Rule": {
            "DefaultRetention": {
                "Mode": "GOVERNANCE",
                "Days": 30
            }
        }
    }'

echo "Object Lock configured."

# -- Lifecycle rules ----------------------------------------------------------

echo ""
echo "--- Configuring lifecycle rules ---"

aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET_NAME" \
    --lifecycle-configuration '{
        "Rules": [
            {
                "ID": "archive-and-expire",
                "Status": "Enabled",
                "Filter": {},
                "Transitions": [
                    {
                        "Days": 30,
                        "StorageClass": "GLACIER"
                    }
                ],
                "Expiration": {
                    "Days": 90
                },
                "NoncurrentVersionTransitions": [
                    {
                        "NoncurrentDays": 30,
                        "StorageClass": "GLACIER"
                    }
                ],
                "NoncurrentVersionExpiration": {
                    "NoncurrentDays": 90
                }
            },
            {
                "ID": "abort-incomplete-multipart-uploads",
                "Status": "Enabled",
                "Filter": {},
                "AbortIncompleteMultipartUpload": {
                    "DaysAfterInitiation": 7
                }
            }
        ]
    }'

echo "Lifecycle rules configured."

# -- Create IAM user ----------------------------------------------------------

echo ""
echo "--- Creating IAM user ---"

if aws iam get-user --user-name "$IAM_USER" &>/dev/null; then
    echo "IAM user $IAM_USER already exists, skipping creation."
else
    aws iam create-user --user-name "$IAM_USER"
    echo "IAM user created: $IAM_USER"
fi

# -- Attach inline policy -----------------------------------------------------

echo ""
echo "--- Attaching backup policy ---"

POLICY_DOCUMENT="$(gen_iam_policy "$BUCKET_NAME" "$SERVER")"

aws iam put-user-policy \
    --user-name "$IAM_USER" \
    --policy-name "${IAM_USER}-policy" \
    --policy-document "$POLICY_DOCUMENT"

echo "Policy attached."

# -- Create access key --------------------------------------------------------

echo ""
echo "--- Creating access key ---"

EXISTING_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text)

if [[ -n "$EXISTING_KEYS" ]]; then
    echo "IAM user already has access key(s): $EXISTING_KEYS"
    echo "Skipping key creation. Use existing keys or delete them in the AWS console first."
    ACCESS_KEY_ID="<existing — see above>"
    SECRET_ACCESS_KEY="<not retrievable — check your records or rotate the key>"
else
    ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name "$IAM_USER")
    ACCESS_KEY_ID=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
    SECRET_ACCESS_KEY=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')
fi

# -- Output -------------------------------------------------------------------

echo ""
echo "=============================================="
echo "        Setup Complete                        "
echo "=============================================="
echo ""
echo "Bucket:          $BUCKET_NAME"
echo "Region:          $AWS_REGION"
echo "Server:          $SERVER"
echo "S3 prefix:       ${SERVER}/  (this server's keyspace)"
echo "IAM User:        $IAM_USER  (scoped to '${SERVER}/*' — no Delete)"
echo "Access Key ID:   $ACCESS_KEY_ID"
echo "Secret Key:      $SECRET_ACCESS_KEY"
echo ""
echo "Save these credentials now — the secret key cannot be retrieved again."
echo ""
echo "--- AWS credentials ---"
echo ""
echo "# Host-side volume backup (Ansible 'backup' role): export these in the"
echo "# shell you run miuOps from -- they stay env-only and are never committed."
echo "export AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID"
echo "export AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY"
echo "export AWS_REGION=$AWS_REGION"
echo ""
echo "# Then in host_vars/${SERVER}.yml:"
echo "#   backup_enabled: true"
echo "#   backup_s3_bucket: \"$BUCKET_NAME\""
echo "#   backup_s3_prefix: \"${SERVER}/vol\"   # default already derives this from inventory_hostname"
echo "#   backup_volumes: [ { name: <volume>, stop: [<container>] }, ... ]"
echo ""
echo "# WAL-G database backup still reads these from the server's .env"
echo "# (/opt/stacks/.env), per stack. Keep the '${SERVER}/' root so this"
echo "# server's scoped IAM user is authorized to write it:"
echo "#   AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID"
echo "#   AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY"
echo "#   AWS_REGION=$AWS_REGION"
echo "#   WALG_S3_PREFIX=s3://${BUCKET_NAME}/${SERVER}/db/<app-name>"
echo ""
echo "=============================================="
echo "        Next Steps                            "
echo "=============================================="
echo ""
echo "1. Configure + apply the volume backup role (see roles/backup/README.md):"
echo "   set backup_* in host_vars/${SERVER}.yml, export the AWS creds above, then"
echo "   ./miuops apply ${SERVER}"
echo "2. For PostgreSQL, add the .env values above to /opt/stacks/.env and use"
echo "   the pre-built postgres-walg image in your compose file:"
echo "   image: ghcr.io/tianshanghong/postgres-walg:17"
echo "3. Add a host cron job for daily base backups:"
echo "   0 3 * * * cd /opt/stacks/<app-name> && docker compose exec -T -u postgres db walg-backup.sh"
echo "4. Set up volume backup encryption -- see docs/BACKUP_ENCRYPTION.md"
echo "   Strongly recommended: volumes may contain secrets/personal data"
echo "=============================================="
