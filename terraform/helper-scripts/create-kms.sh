#!/bin/bash

ALIAS="alias/terraform-s3-tfstate/${INFRA}"
DESCRIPTION="$(echo ${ALIAS} | awk -F'/' '{print $3}')"

function usage() {
    echo "Examples:"
    echo "  Using custom profile and custom region"
    echo "      AWS_PROFILE=leuseast2 AWS_REGION=us-east-2 INFRA=iceland ./$(basename ${0})"
}

function _echo() {
    if [ ! -z "${FLAG_DEBUG}" ] && [ ${FLAG_DEBUG} -eq 1 ]; then
        echo "${@}"
    fi
}

function get_alias() {
    _echo "+) Retrieving KMS aliases"
    for i in $(aws --output=json --profile=${AWS_PROFILE} kms list-aliases --region=${AWS_REGION} 2>/dev/null | jq -cr '.Aliases[]'); do
        KMS_ALIAS="$(echo ${i} | jq -cr ". | select(.AliasName==\"${ALIAS}\") | .AliasArn")"
        if [ ! -z "${KMS_ALIAS}" ]; then
            _echo "+) Retrieved KMS alias"

            # This is the main object we need the script to output
            echo "${KMS_ALIAS}"

            break
        fi
    done
}

function get_key() {
    echo "+) Retrieving KMS keys"
    for i in in $(aws --output=json --profile=${AWS_PROFILE} kms list-keys --region=${AWS_REGION} 2>/dev/null | jq -cr '.Keys[].KeyId'); do
    KMS_ARN="$(aws --output=json --profile=${AWS_PROFILE} kms describe-key --key-id=${i} --region=${AWS_REGION} 2>/dev/null | jq -cr ". | select(.KeyMetadata.Description==\"${DESCRIPTION}\") | .KeyMetadata.Arn")"
        if [ ! -z "${KMS_ARN}" ]; then
            _echo "+) Retrieved KMS key"
            _echo "${KMS_ARN}"
            break
        fi
    done
}

while getopts "hd" OPT; do
    case ${OPT} in
        h)  usage
            exit 0;;
        d) FLAG_DEBUG=1;;
    esac
done

get_alias

if [ -z "${KMS_ALIAS}" ]; then
    get_key

    if [ -z "${KMS_ARN}" ]; then
        _echo "+) Generating KMS key"
        KMS_ARN="$(aws --output=json --profile=${AWS_PROFILE} kms create-key --description="${DESCRIPTION}" --key-usage=ENCRYPT_DECRYPT --origin=AWS_KMS --region="${AWS_REGION}" | jq -cr '.KeyMetadata.Arn')"
    fi

    if [ -z "${KMS_ALIAS}" ]; then
        _echo "+) Generating KMS alias"
        aws --profile=${AWS_PROFILE} kms create-alias --alias-name="${ALIAS}" --target-key-id="${KMS_ARN}" --region="${AWS_REGION}"
        get_alias
    fi
fi
