.ONESHELL:
.SHELL := /usr/bin/bash
BOLD=$(shell tput bold)
RED=$(shell tput setaf 1)
GREEN=$(shell tput setaf 2)
YELLOW=$(shell tput setaf 3)
RESET=$(shell tput sgr0)

AWS_PROFILE ?= default

ifeq ($(INFRA),)
$(info $(BOLD)Example usage: \`INFRA=demo make plan\`$(RESET))
$(info $(BOLD)If using a non-default AWS_PROFILE: \`AWS_PROFILE=leuswest2 INFRA=demo make plan\`$(RESET))
$(error $(BOLD)$(RED)INFRA was not set$(RESET))
endif

VARS="variables/$(INFRA).tfvars"
REGION="$(shell grep '^aws_region' $(VARS) | awk -F'=' '{print $$2}' | sed 's/[[:space:]]//g')"
ifeq ($(REGION),)
$(error $(BOLD)$(RED)REGION was not detected$(RESET))
endif

S3_BUCKET="$(INFRA)-$(REGION)-prio-facilitator-terraform"
DYNAMODB_TABLE="$(INFRA)-$(REGION)-prio-facilitator-terraform"
WORKSPACE="$(INFRA)-$(REGION)"

S3_KMS_KEY_ID="$(shell AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(REGION) INFRA=$(INFRA) ./helper-scripts/create-kms.sh)"
ifeq ($(S3_KMS_KEY_ID),)
$(error $(BOLD)$(RED)S3_KMS_KEY_ID was not detected$(RESET))
endif

.PHONY: help
help:
    @grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: prep
prep: ## Prepare a new workspace (environment) if needed, configure the tfstate backend, update any modules, and switch to the workspace
    @rm -rf .terraform/
    @if [ ! -f "$(VARS)" ]; then \
        echo "$(BOLD)$(RED)Could not find variables file: $(VARS)$(RESET)"; \
        exit 1; \
     fi
    @echo "$(BOLD)Verifying that the S3 bucket $(S3_BUCKET) for remote state exists$(RESET)"
    @if ! aws --profile $(AWS_PROFILE) s3api head-bucket --region $(REGION) --bucket $(S3_BUCKET) > /dev/null 2>&1 ; then \
        echo "$(BOLD)S3 bucket $(S3_BUCKET) was not found, creating new bucket with versioning enabled to store tfstate$(RESET)"; \
        if [ "$(REGION)" == "us-east-1" ]; then
            # https://github.com/heptio/velero/pull/285
            aws --profile $(AWS_PROFILE) s3api create-bucket \
                --bucket $(S3_BUCKET) \
                --acl private \
                --region $(REGION); \
        else
            aws --profile $(AWS_PROFILE) s3api create-bucket \
                --bucket $(S3_BUCKET) \
                --acl private \
                --region $(REGION) \
                --create-bucket-configuration LocationConstraint=$(REGION) > /dev/null 2>&1 ; \
        fi
        aws --profile $(AWS_PROFILE) s3api put-bucket-versioning \
            --bucket $(S3_BUCKET) \
            --versioning-configuration Status=Enabled > /dev/null 2>&1 ; \
        echo "$(BOLD)$(GREEN)S3 bucket $(S3_BUCKET) created$(RESET)"; \
     else
        echo "$(BOLD)$(GREEN)S3 bucket $(S3_BUCKET) exists$(RESET)"; \
     fi
    @echo "$(BOLD)Verifying that the DynamoDB table exists for remote state locking$(RESET)"
    @if ! aws --profile $(AWS_PROFILE) dynamodb describe-table --table-name $(DYNAMODB_TABLE) > /dev/null 2>&1 ; then \
        echo "$(BOLD)DynamoDB table $(DYNAMODB_TABLE) was not found, creating new DynamoDB table to maintain locks$(RESET)"; \
        aws --profile $(AWS_PROFILE) dynamodb create-table \
            --region $(REGION) \
            --table-name $(DYNAMODB_TABLE) \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 > /dev/null 2>&1 ; \
        echo "$(BOLD)$(GREEN)DynamoDB table $(DYNAMODB_TABLE) created$(RESET)"; \
        echo "Sleeping for 10 seconds to allow DynamoDB state to propagate through AWS"; \
        sleep 10; \
     else
        echo "$(BOLD)$(GREEN)DynamoDB Table $(DYNAMODB_TABLE) exists$(RESET)"; \
     fi
    @aws --output=json ec2 --profile=$(AWS_PROFILE) describe-key-pairs | jq -r '.KeyPairs[].KeyName' | grep "$(INFRA)_infra_key" > /dev/null 2>&1; \
    if [ $$? -ne 0 ]; then \
        echo "$(BOLD)$(RED)EC2 Key Pair $(INFRA)_infra_key was not found$(RESET)"; \
        read -p '$(BOLD)Do you want to generate a new keypair? [Y/N]: $(RESET)' ANSWER && \
        if [ "$${ANSWER}" == "y" ] || [ "$${ANSWER}" == "Y" ]; then \
            mkdir -p ~/.ssh; \
            ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/$(INFRA)_infra_key; \
            aws ec2 --profile=$(AWS_PROFILE) import-key-pair --key-name "$(INFRA)_infra_key" --public-key-material "fileb://~/.ssh/$(INFRA)_infra_key.pub"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
            echo "$(BOLD)$(GREEN)Place the contents of ~/.ssh/$(INFRA)_infra_key into LastPass!$(RESET)"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
            echo "$(BOLD)$(GREEN)!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!=!$(RESET)"; \
        fi; \
      else \
          echo "$(BOLD)$(GREEN)EC2 Key Pair $(INFRA)_infra_key exists$(RESET)";\
      fi
    @echo "$(BOLD)Configuring the terraform backend$(RESET)"
    @terraform init \
        -input=false \
        -force-copy \
        -lock=true \
        -upgrade \
        -verify-plugins=true \
        -backend=true \
        -backend-config="encrypt=true" \
        -backend-config="profile=$(AWS_PROFILE)" \
        -backend-config="region=$(REGION)" \
        -backend-config="bucket=$(S3_BUCKET)" \
        -backend-config="kms_key_id=$(S3_KMS_KEY_ID)" \
        -backend-config="key=$(INFRA)/vpc/terraform.tfstate" \
        -backend-config="dynamodb_table=$(DYNAMODB_TABLE)"\
        -backend-config="acl=private" \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)'
    @echo "$(BOLD)Switching to workspace $(WORKSPACE)$(RESET)"
    @terraform workspace select $(WORKSPACE) || terraform workspace new $(WORKSPACE)

.PHONY: plan
plan: prep ## Show what terraform thinks it will do
    @terraform plan \
        -lock=true \
        -input=false \
        -refresh=true \
        -var-file="$(VARS)" \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)'

.PHONY: plan-target
plan-target: prep ## Shows what a plan looks like for applying a specific resource
    @echo "$(YELLOW)$(BOLD)[INFO]   $(RESET)"; echo "Example to type for the following question: module.rds.aws_route53_record.rds-master"
    @read -p "PLAN target: " DATA && \
        terraform plan \
            -lock=true \
            -input=true \
            -refresh=true \
            -var-file="$(VARS)" \
            -var 'aws_profile=$(AWS_PROFILE)' \
            -var 's3_kms_key_id=$(S3_KMS_KEY_ID)' \
            -target=$$DATA

.PHONY: plan-destroy
plan-destroy: prep ## Creates a destruction plan.
    @terraform plan \
        -input=false \
        -refresh=true \
        -destroy \
        -var-file="$(VARS)" \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)'

.PHONY: output
output: prep ## Make Terraform print output variable(s).
    @terraform output

.PHONY: apply
apply: prep ## Have terraform do the things. This will cost money.
    @terraform apply \
        -lock=true \
        -input=false \
        -refresh=true \
        -var-file="$(VARS)" \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)'

.PHONY: apply-target
apply-target: prep ## Have terraform do the things for a specific resource. This will cost money.
    @echo "$(YELLOW)$(BOLD)[INFO]   $(RESET)"; echo "Example to type for the following question: module.rds.aws_route53_record.rds-master"
    @read -p "APPLY target: " DATA && \
        terraform apply \
            -lock=true \
            -input=true \
            -refresh=true \
            -var-file="$(VARS)" \
            -var 'aws_profile=$(AWS_PROFILE)' \
            -var 's3_kms_key_id=$(S3_KMS_KEY_ID)' \
            -target=$$DATA

.PHONY: destroy
destroy: prep ## Destroy the things
    @terraform destroy \
        -lock=true \
        -input=false \
        -refresh=true \
        -var-file="$(VARS)" \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)'

.PHONY: destroy-target
destroy-target: prep ## Destroy a specific resource. Caution though, this destroys chained resources.
    @echo "$(YELLOW)$(BOLD)[INFO] Specifically destroy a piece of Terraform data.$(RESET)"; echo "Example to type for the following question: module.rds.aws_route53_record.rds-master"
    @read -p "Destroy target: " DATA && \
        terraform destroy \
        -lock=true \
        -input=false \
        -refresh=true \
        -var-file=$(VARS) \
        -var 'aws_profile=$(AWS_PROFILE)' \
        -var 's3_kms_key_id=$(S3_KMS_KEY_ID)' \
        -target=$$DATA

.PHONY: destroy-backend
destroy-backend: ## Destroy S3 bucket and DynamoDB table
    @if ! aws --profile $(AWS_PROFILE) dynamodb delete-table \
        --region $(REGION) \
        --table-name $(DYNAMODB_TABLE) > /dev/null 2>&1 ; then \
            echo "$(BOLD)$(RED)Unable to delete DynamoDB table $(DYNAMODB_TABLE)$(RESET)"; \
     else
        echo "$(BOLD)$(RED)DynamoDB table $(DYNAMODB_TABLE) does not exist.$(RESET)"; \
     fi
    @if ! aws --profile $(AWS_PROFILE) s3api delete-objects \
        --region $(REGION) \
        --bucket $(S3_BUCKET) \
        --delete "$$(aws --profile $(AWS_PROFILE) s3api list-object-versions \
                        --region $(REGION) \
                        --bucket $(S3_BUCKET) \
                        --output=json \
                        --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" > /dev/null 2>&1 ; then \
            echo "$(BOLD)$(RED)Unable to delete objects in S3 bucket $(S3_BUCKET)$(RESET)"; \
     fi
    @if ! aws --profile $(AWS_PROFILE) s3api delete-objects \
        --region $(REGION) \
        --bucket $(S3_BUCKET) \
        --delete "$$(aws --profile $(AWS_PROFILE) s3api list-object-versions \
                        --region $(REGION) \
                        --bucket $(S3_BUCKET) \
                        --output=json \
                        --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" > /dev/null 2>&1 ; then \
            echo "$(BOLD)$(RED)Unable to delete markers in S3 bucket $(S3_BUCKET)$(RESET)"; \
     fi
    @if ! aws --profile $(AWS_PROFILE) s3api delete-bucket \
        --region $(REGION) \
        --bucket $(S3_BUCKET) > /dev/null 2>&1 ; then \
            echo "$(BOLD)$(RED)Unable to delete S3 bucket $(S3_BUCKET) itself$(RESET)"; \
     fi
