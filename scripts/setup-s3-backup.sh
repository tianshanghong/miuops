#!/bin/bash

# Setup S3 backup bucket with Object Lock, lifecycle rules, and IAM user
# Creates a single bucket for both WAL-G database and offen volume backups
# Idempotent — safe to re-run if a previous run failed partway through

set -e

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

read -rp "Enter project name (used as bucket prefix, e.g. myproject): " PROJECT_NAME

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Error: Project name cannot be empty."
    exit 1
fi

BUCKET_NAME="${PROJECT_NAME}-backup"
IAM_USER="${PROJECT_NAME}-backup"

read -rp "Enter AWS region [us-west-2]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-west-2}

echo ""
echo "This will create:"
echo "  - S3 bucket:  $BUCKET_NAME (region: $AWS_REGION)"
echo "  - IAM user:   $IAM_USER (Put/Get/List only — no Delete)"
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

POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF
)

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
echo "IAM User:        $IAM_USER"
echo "Access Key ID:   $ACCESS_KEY_ID"
echo "Secret Key:      $SECRET_ACCESS_KEY"
echo ""
echo "Save these credentials now — the secret key cannot be retrieved again."
echo ""
echo "--- .env configuration ---"
echo ""
echo "# AWS credentials (shared by offen + WAL-G)"
echo "AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY"
echo "AWS_REGION=$AWS_REGION"
echo ""
echo "# Offen volume backup (stacks/backup)"
echo "BACKUP_S3_BUCKET=$BUCKET_NAME"
echo "BACKUP_S3_PATH=vol"
echo ""
echo "# WAL-G database backup (postgres-walg image)"
echo "WALG_S3_PREFIX=s3://${BUCKET_NAME}/db/\${APP_NAME}"
echo ""
echo "=============================================="
echo "        Next Steps                            "
echo "=============================================="
echo ""
echo "1. SSH into the server and add the .env values above to /opt/stacks/.env"
echo "2. Use the pre-built postgres-walg image in your compose file:"
echo "   image: ghcr.io/tianshanghong/postgres-walg:17"
echo "3. Add a host cron job for daily base backups:"
echo "   0 3 * * * cd /opt/stacks/myapp && docker compose exec -T -u postgres db walg-backup.sh"
echo "4. Set up backup encryption — see docs/BACKUP_ENCRYPTION.md"
echo "   Strongly recommended: backups include .env (secrets)"
echo "=============================================="
